// Task tools (spec/mcp.md 8).
// Read: list_recent_tasks, list_tasks, search_tasks, get_task, get_completed_tasks.
// Write: create_task, update_task, complete_task, delete_task, move_task, move_all.
// Visibility comes from snapshot.liveTasks(): no trashed tasks, nothing in trashed or archived lists.
import { parseRecurrence, validateRepeat } from '../../domain/recurrence';
import { parseReminderCsv } from '../../domain/reminders';
import {
  isValidTimeZone,
  scheduleFromAPI,
  scheduleWithDue,
  type Schedule,
  type ScheduleContext,
} from '../../domain/schedule';
import { normalizeTagLabels, normalizeTags } from '../../domain/tags';
import { uuidv7 } from '../../domain/uuid';
import { withCreated, type Snapshot, type SnapshotRow } from '../../serverops/snapshot';
import {
  completeOccurrence,
  completeTaskIntent,
  moveTaskIntent,
  newTaskIntents,
  patchTaskIntents,
  trashTaskIntent,
} from '../../serverops/taskWrites';
import { bySortKey, compareKeys, isNil, rowSchedule } from '../../serverops/values';
import { assertHasData, writeOrThrow } from '../../serverops/writer';
import { formatTask, openTasksOf, summarizeTask } from '../format';
import { nowOf, requireStr, ToolValidationError, type ToolContext, type ToolDef } from '../toolkit';
import { openSession, requireWritableList } from './projects';

export const SEARCH_LIMIT = 200;
const DEFAULT_RECENT_LIMIT = 10;

const num = (t: SnapshotRow, field: string) => Number(t.row[field] ?? 0);
const isOpen = (t: SnapshotRow) => num(t, 'status') === 0;
const idOf = (t: SnapshotRow) => String(t.row.id);
const byUpdatedDesc = (a: SnapshotRow, b: SnapshotRow) => num(b, 'updatedAt') - num(a, 'updatedAt') || compareKeys(idOf(a), idOf(b));

function requireLiveProject(snapshot: Snapshot, id: string): void {
  if (!snapshot.liveProjects().some((p) => String(p.row.id) === id)) {
    throw new Error(`Unknown project_id '${id}'; call list_projects first`);
  }
}

function optionalProject(snapshot: Snapshot, args: Record<string, unknown>): string | undefined {
  const raw = args.project_id;
  if (raw === undefined || raw === null || raw === '') return undefined;
  const id = String(raw);
  requireLiveProject(snapshot, id);
  return id;
}

function optionalBool(args: Record<string, unknown>, field: string): boolean {
  const v = args[field];
  if (v === undefined || v === null) return false;
  if (typeof v !== 'boolean') throw new ToolValidationError(field, `Argument '${field}' must be a boolean`);
  return v;
}

function parseLimit(v: unknown): number {
  if (v === undefined || v === null || v === '') return DEFAULT_RECENT_LIMIT;
  const n = typeof v === 'string' && /^\d+$/.test(v.trim()) ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n) || n < 1) {
    throw new ToolValidationError('limit', "Argument 'limit' must be a positive integer");
  }
  return n;
}

/** A live task that must sit in `projectId`. */
function taskIn(snapshot: Snapshot, taskId: string, projectId: string): SnapshotRow {
  const task = snapshot.liveTasks().find((t) => idOf(t) === taskId);
  if (!task) throw new Error(`Unknown task_id '${taskId}'`);
  if (task.row.projectId !== projectId) {
    throw new Error(`Task '${taskId}' is not in project '${projectId}' (it is in '${String(task.row.projectId)}')`);
  }
  return task;
}

function checklistTitles(snapshot: Snapshot, taskId: string): string[] {
  return snapshot
    .rows('checklistItem')
    .filter((c) => c.row.taskId === taskId && c.row.deletedAt == null && c.row.purgedAt == null)
    .map((c) => String(c.row.title ?? '').toLowerCase());
}

const PROJECT_ID = { type: 'string', description: 'Project id from list_projects.' };
const OPTIONAL_PROJECT = { type: 'string', description: 'Optional. Restrict to this project; omit for all projects.' };

export function taskReadTools(): ToolDef[] {
  return [
    {
      name: 'list_recent_tasks',
      description:
        'List recent tasks in a project (newest update first), INCLUDING completed ones by default. ALWAYS call this before creating a new task to avoid duplicating a task that already exists (check for same title / same intent). Each task carries status: 0 active or 2 completed; prefer updating an existing (even completed) task over creating a new one. Returns task summaries (content cut to 100 characters, items as a count; see get_task).',
      inputSchema: {
        type: 'object',
        required: ['project_id'],
        properties: {
          project_id: PROJECT_ID,
          limit: { type: 'integer', description: 'Maximum number of tasks. Default 10.' },
          active_only: { type: 'boolean', description: 'Exclude completed tasks.' },
          tag: { type: 'string', description: 'Filter by tag name.' },
        },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const limit = parseLimit(args.limit);
        const activeOnly = optionalBool(args, 'active_only');
        const tag = typeof args.tag === 'string' ? normalizeTags([args.tag])[0] : undefined;
        const { snapshot } = await openSession(ctx);
        requireLiveProject(snapshot, projectId);
        return snapshot
          .liveTasks()
          .filter((t) => t.row.projectId === projectId)
          .filter((t) => !activeOnly || isOpen(t))
          .filter((t) => tag === undefined || (Array.isArray(t.row.tags) && (t.row.tags as unknown[]).includes(tag)))
          .sort(byUpdatedDesc)
          .slice(0, limit)
          .map((t) => summarizeTask(snapshot, t));
      },
    },
    {
      name: 'list_tasks',
      description:
        'List active (incomplete) tasks across all your projects, optionally filtered to a single project, in list order. Unlike list_recent_tasks, this never includes completed tasks and is not limited to recent ones. Returns task summaries (see get_task).',
      inputSchema: { type: 'object', properties: { project_id: OPTIONAL_PROJECT } },
      run: async (args, ctx) => {
        const { snapshot } = await openSession(ctx);
        const projectId = optionalProject(snapshot, args);
        return snapshot
          .liveTasks()
          .filter((t) => isOpen(t) && (projectId === undefined || t.row.projectId === projectId))
          .sort(bySortKey)
          .map((t) => summarizeTask(snapshot, t));
      },
    },
    {
      name: 'search_tasks',
      description: `Full-text search across task titles, content, tags and checklist item titles. By default includes completed tasks; set active_only to restrict to pending. Active tasks come first, newest update first; at most ${SEARCH_LIMIT} results. Returns task summaries (see get_task).`,
      inputSchema: {
        type: 'object',
        required: ['query'],
        properties: { query: { type: 'string' }, active_only: { type: 'boolean', description: 'Exclude completed tasks.' } },
      },
      run: async (args, ctx) => {
        const query = requireStr(args, 'query').trim().toLowerCase();
        const activeOnly = optionalBool(args, 'active_only');
        const { snapshot } = await openSession(ctx);
        return snapshot
          .liveTasks()
          .filter((t) => !activeOnly || isOpen(t))
          .filter((t) => {
            const tags = Array.isArray(t.row.tags) ? (t.row.tags as unknown[]).map((x) => String(x).toLowerCase()) : [];
            return (
              [String(t.row.title ?? ''), String(t.row.content ?? '')].some((s) => s.toLowerCase().includes(query)) ||
              tags.some((s) => s.includes(query)) ||
              checklistTitles(snapshot, idOf(t)).some((s) => s.includes(query))
            );
          })
          .sort((a, b) => num(a, 'status') - num(b, 'status') || byUpdatedDesc(a, b))
          .slice(0, SEARCH_LIMIT)
          .map((t) => summarizeTask(snapshot, t));
      },
    },
    {
      name: 'get_task',
      description:
        'Fetch the full record for a single task. List/search tools return summaries only (content cut to 100 characters, checklist as a count); call this for the rest. Errors when the task is not in the given project.',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id'],
        properties: { project_id: PROJECT_ID, task_id: { type: 'string' } },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const { snapshot } = await openSession(ctx);
        return formatTask(snapshot, taskIn(snapshot, taskId, projectId));
      },
    },
    {
      name: 'get_completed_tasks',
      description:
        'List completed tasks, most recently completed first, optionally filtered to one project. Returns task summaries (see get_task).',
      inputSchema: { type: 'object', properties: { project_id: OPTIONAL_PROJECT } },
      run: async (args, ctx) => {
        const { snapshot } = await openSession(ctx);
        const projectId = optionalProject(snapshot, args);
        return snapshot
          .liveTasks()
          .filter((t) => num(t, 'status') === 2 && (projectId === undefined || t.row.projectId === projectId))
          .sort((a, b) => num(b, 'completedAt') - num(a, 'completedAt') || compareKeys(idOf(a), idOf(b)))
          .map((t) => summarizeTask(snapshot, t));
      },
    },
  ];
}

// MARK: - Write tools

const DEFAULT_TIME_ZONE = 'Asia/Taipei';
const PRIORITY: Record<string, number> = { none: 0, low: 1, medium: 3, high: 5 };

function optString(args: Record<string, unknown>, field: string): string | undefined {
  const v = args[field];
  if (isNil(v)) return undefined;
  if (typeof v !== 'string') throw new ToolValidationError(field, `Argument '${field}' must be a string`);
  return v;
}

/** The string, or undefined when absent or blank. */
function nonBlank(v: string | undefined): string | undefined {
  return v === undefined || v.trim() === '' ? undefined : v;
}

function optBoolean(args: Record<string, unknown>, field: string): boolean | undefined {
  const v = args[field];
  if (isNil(v)) return undefined;
  if (typeof v !== 'boolean') throw new ToolValidationError(field, `Argument '${field}' must be a boolean`);
  return v;
}

function optStringList(args: Record<string, unknown>, field: string): string[] | undefined {
  const v = args[field];
  if (isNil(v)) return undefined;
  if (!Array.isArray(v) || !v.every((x) => typeof x === 'string')) {
    throw new ToolValidationError(field, `Argument '${field}' must be an array of strings`);
  }
  return v as string[];
}

function parseTitle(raw: string): string {
  const title = raw.trim();
  if (title === '') throw new ToolValidationError('title', "Argument 'title' must not be empty");
  return title;
}

/** Some clients deliver the two characters `\n` instead of a real line break. */
function parseContent(args: Record<string, unknown>): string | undefined {
  return optString(args, 'content')?.replace(/\\r\\n/g, '\n').replace(/\\n/g, '\n');
}

function parsePriority(args: Record<string, unknown>): number | undefined {
  const v = nonBlank(optString(args, 'priority'));
  if (v === undefined) return undefined;
  const n = PRIORITY[v];
  if (n === undefined) throw new ToolValidationError('priority', "Argument 'priority' must be none, low, medium or high");
  return n;
}

function scheduleContext(ctx: ToolContext, originalTimeZone: string | null = null): ScheduleContext {
  return { originalTimeZone, defaultTimeZone: ctx.services?.defaultTimeZone ?? DEFAULT_TIME_ZONE };
}

const NEEDS_DATE = (field: string) =>
  `\`${field}\` needs a date: set \`start\` or \`due\` in this same call, or omit \`${field}\`.`;

const TASK_FIELDS = {
  title: { type: 'string' },
  content: {
    type: 'string',
    description: 'Notes / description. Use real newline characters for line breaks (a literal \\n is converted to one).',
  },
  priority: { type: 'string', enum: ['none', 'low', 'medium', 'high'] },
  start: {
    type: 'string',
    description: 'ISO 8601 start, e.g. 2026-04-20T13:00:00+08:00 (timed) or 2026-04-20 (all-day). Without an offset or timezone the time floats with the device.',
  },
  due: { type: 'string', description: 'ISO 8601 end. For all-day tasks, the last day (inclusive).' },
  all_day: { type: 'boolean', description: 'Force all-day (dates only). Defaults to all-day when start has no time.' },
  timezone: { type: 'string', description: 'IANA zone, e.g. Asia/Taipei. Inferred from the offset when omitted.' },
  reminder: {
    type: 'string',
    description: 'One or more triggers, comma-separated, e.g. TRIGGER:-P1D,TRIGGER:-PT30M. Relative to the start (00:00 of the start day for all-day tasks). Each at most a year (366 days) from the start. Needs a date.',
  },
  repeat: {
    type: 'string',
    description: 'Calendar recurrence (RRULE), e.g. RRULE:FREQ=DAILY. Supported: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL (1-999), BYDAY, BYMONTHDAY. Needs a date. For genuinely repeating commitments only: completing one occurrence does NOT cancel the later ones.',
  },
  subtasks: { type: 'array', items: { type: 'string' }, description: 'Checklist item titles, in order.' },
  tags: { type: 'array', items: { type: 'string' }, description: 'Tag names; new tags are created.' },
} as const;

export function taskWriteTools(): ToolDef[] {
  return [
    {
      name: 'create_task',
      description:
        'Create a task. MUST follow these rules:\n' +
        '1. Before calling, use list_recent_tasks to check the project for a same-title or same-intent task. If one exists (even completed), use update_task instead.\n' +
        '2. Timed items (meetings, classes, workouts, a to-do you want pinged at a set time): set BOTH `start` and `due` in ISO 8601 with an offset, e.g. 2026-04-20T13:00:00+08:00. Do not only set `due` for a timed task.\n' +
        '3. All-day items: set `start` to the date (2026-04-20) and, for several days, `due` to the last day. Never combine a time with `all_day`.\n' +
        "4. One piece of work you want reminding about on SEVERAL days but finish once (chasing a colleague, a follow-up before a deadline): ONE task with `start` on the LAST day and relative reminders for the earlier ones, e.g. start Thu 09:00 with reminder 'TRIGGER:-P2D,TRIGGER:-P1D,TRIGGER:PT0S'. Ticking it off then stops the rest. Do NOT use `repeat` and do NOT create one task per day; both keep firing after the work is done. Split into separate tasks only when the clock times themselves differ.\n" +
        "5. NEVER put times inside the title (bad: 'Badminton 13:00-14:00'). Use start/due instead.\n" +
        '6. Priorities: none | low | medium | high.\n' +
        '7. Match existing task formatting conventions within the same project (title style, content structure, reminder, tags).\n' +
        '`reminder` and `repeat` need a date in the same call; the call is rejected without one. The project must be writable (can_write in list_projects).',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'title'],
        properties: { project_id: PROJECT_ID, ...TASK_FIELDS },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const title = parseTitle(requireStr(args, 'title'));
        const content = parseContent(args) ?? '';
        const priority = parsePriority(args) ?? 0;
        const reminder = nonBlank(optString(args, 'reminder'));
        const repeat = nonBlank(optString(args, 'repeat'));
        const subtasks = optStringList(args, 'subtasks') ?? [];
        const tags = normalizeTagLabels(optStringList(args, 'tags') ?? []);
        const schedule = scheduleFromAPI(
          {
            start: nonBlank(optString(args, 'start')) ?? null,
            due: nonBlank(optString(args, 'due')) ?? null,
            allDay: optBoolean(args, 'all_day') ?? null,
            timeZone: nonBlank(optString(args, 'timezone')) ?? null,
          },
          scheduleContext(ctx),
        );
        if (reminder !== undefined && schedule === null) throw new ToolValidationError('reminder', NEEDS_DATE('reminder'));
        if (repeat !== undefined && schedule === null) throw new ToolValidationError('repeat', NEEDS_DATE('repeat'));
        const reminders = reminder === undefined ? [] : parseReminderCsv(reminder);
        const repeatRule = repeat === undefined ? null : validateRepeat(repeat);

        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        requireWritableList(snapshot, projectId);
        const now = nowOf(ctx);
        const id = uuidv7(now);
        const task = { projectId, title, content, priority, reminders, tags, subtasks, schedule, repeatRule };
        const outcomes = await writeOrThrow(deps, snapshot, newTaskIntents(snapshot, ctx.userId, id, task, now), { nowMs: now });
        const view = withCreated(snapshot, outcomes);
        return formatTask(view, view.findRow('task', id)!);
      },
    },
    {
      name: 'update_task',
      description:
        'Update fields of an existing task. Pass only the fields you want to change; omitted fields are kept.\n' +
        '- The schedule is rebuilt only when `start` or `due` is given. `start` alone removes the end; send both to keep a duration. `due` alone keeps the current start. `timezone` alone moves the task to that zone at the same wall-clock time. `all_day` needs `start` or `due`.\n' +
        '- `start: ""` removes the date, together with its reminders and repeat. `due: ""` removes only the end.\n' +
        '- `repeat: ""` stops repeating. `reminder` replaces all reminders (`""` removes them) and needs the task to have a date.\n' +
        '- `subtasks` replaces the WHOLE checklist with this list (omit to leave items untouched). `tags` replaces all tags.\n' +
        '- `project_id` must be the task\'s current project; use move_task to move it.',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id'],
        properties: {
          project_id: PROJECT_ID,
          task_id: { type: 'string' },
          ...TASK_FIELDS,
          subtasks: { ...TASK_FIELDS.subtasks, description: 'Replaces the whole checklist.' },
        },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const rawTitle = optString(args, 'title');
        const title = rawTitle === undefined ? undefined : parseTitle(rawTitle);
        const content = parseContent(args);
        const priority = parsePriority(args);
        const start = optString(args, 'start');
        const due = optString(args, 'due');
        const allDay = optBoolean(args, 'all_day');
        const timezone = nonBlank(optString(args, 'timezone'));
        const reminder = optString(args, 'reminder');
        const repeat = optString(args, 'repeat');
        const subtasks = optStringList(args, 'subtasks');
        const rawTags = optStringList(args, 'tags');
        if (allDay !== undefined && start === undefined && nonBlank(due) === undefined) {
          throw new ToolValidationError('all_day', "'all_day' only applies together with start or due");
        }
        const reminders = reminder === undefined ? undefined : parseReminderCsv(reminder);
        const repeatRule = repeat === undefined ? undefined : repeat.trim() === '' ? null : validateRepeat(repeat);

        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        const task = taskIn(snapshot, taskId, projectId);
        requireWritableList(snapshot, projectId);
        const cur = rowSchedule(task.row);
        const sctx = scheduleContext(ctx, cur?.timeZone ?? null);

        // undefined = schedule untouched (its columns stay out of the op so the zone is not rewritten).
        let next: Schedule | null | undefined;
        if (start !== undefined) {
          next =
            start.trim() === ''
              ? null
              : scheduleFromAPI({ start, due: nonBlank(due) ?? null, allDay: allDay ?? null, timeZone: timezone ?? null }, sctx);
        } else if (nonBlank(due) !== undefined) {
          next = cur
            ? scheduleWithDue(cur, { due: due!, allDay: allDay ?? null, timeZone: timezone ?? null }, sctx)
            : scheduleFromAPI({ due: due!, allDay: allDay ?? null, timeZone: timezone ?? null }, sctx);
        } else if (due !== undefined && cur) {
          next = { ...cur, endDay: null, endMinute: null };
        } else if (timezone !== undefined) {
          if (!cur) throw new ToolValidationError('timezone', "'timezone' needs a task with a date; give start or due too");
          if (!isValidTimeZone(timezone)) throw new ToolValidationError('timezone', `Unknown IANA time zone: ${timezone}`);
          next = { ...cur, timeZone: timezone };
        }
        const schedule = next === undefined ? cur : next;
        if (schedule === null) {
          if (reminders !== undefined && reminders.length > 0) throw new ToolValidationError('reminder', NEEDS_DATE('reminder'));
          if (repeatRule) throw new ToolValidationError('repeat', NEEDS_DATE('repeat'));
        }

        const now = nowOf(ctx);
        const tags = rawTags === undefined ? undefined : normalizeTagLabels(rawTags);
        const patch = { title, content, priority, schedule: next, reminders, repeatRule, tags, subtasks };
        const intents = patchTaskIntents(snapshot, ctx.userId, task, patch, now);
        if (intents === null) throw new Error('Nothing to update: give at least one field to change');
        const outcomes = await writeOrThrow(deps, snapshot, intents, { nowMs: now });
        const view = withCreated(snapshot, outcomes);
        return formatTask(view, view.findRow('task', taskId)!);
      },
    },
    {
      name: 'complete_task',
      description:
        'Mark a task completed. For a repeating task, the current occurrence is recorded as a separate completed task (returned, with a copy of the checklist) and the task itself moves to its next occurrence on or after today, with its checklist reopened; later occurrences are not cancelled. Completing an already completed task returns it unchanged. Errors when the task is not in that project; the project must be writable.',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id'],
        properties: { project_id: PROJECT_ID, task_id: { type: 'string' } },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        const task = taskIn(snapshot, taskId, projectId);
        requireWritableList(snapshot, projectId);
        if (num(task, 'status') === 2) return formatTask(snapshot, task);
        const rule = typeof task.row.repeatRule === 'string' ? parseRecurrence(task.row.repeatRule) : null;
        const schedule = rowSchedule(task.row);
        if (rule !== null && schedule !== null) {
          const options = { defaultTimeZone: scheduleContext(ctx).defaultTimeZone, nowMs: nowOf(ctx) };
          const { copyId, outcomes } = await completeOccurrence(deps, snapshot, task, rule, schedule, options);
          const view = withCreated(snapshot, outcomes);
          return formatTask(view, view.findRow('task', copyId)!);
        }
        const now = nowOf(ctx);
        await writeOrThrow(deps, snapshot, [completeTaskIntent(taskId, now)], { nowMs: now });
        return formatTask(snapshot, snapshot.findRow('task', taskId)!);
      },
    },
    {
      name: 'delete_task',
      description:
        'Move a task to the trash; it can be restored from the DayDo app\'s trash. Confirm with the user before calling unless they explicitly asked to delete; prefer complete_task for finished work. Errors when the task is not in that project; on success returns {deleted:true, task_id, title}.',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id'],
        properties: { project_id: PROJECT_ID, task_id: { type: 'string' } },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        const task = taskIn(snapshot, taskId, projectId);
        requireWritableList(snapshot, projectId);
        const now = nowOf(ctx);
        await writeOrThrow(deps, snapshot, [trashTaskIntent(taskId, now)], { nowMs: now });
        return { deleted: true, task_id: taskId, title: String(task.row.title ?? '') };
      },
    },
    {
      name: 'move_task',
      description:
        "Move a single task to a different project (list). Requires the task's current project (from_project_id) and the destination (to_project_id); you need write access to both.",
      inputSchema: {
        type: 'object',
        required: ['task_id', 'from_project_id', 'to_project_id'],
        properties: {
          task_id: { type: 'string' },
          from_project_id: { type: 'string', description: "The task's current project id." },
          to_project_id: { type: 'string', description: 'Destination project id.' },
        },
      },
      run: async (args, ctx) => {
        const taskId = requireStr(args, 'task_id');
        const from = requireStr(args, 'from_project_id');
        const to = requireStr(args, 'to_project_id');
        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        taskIn(snapshot, taskId, from);
        requireLiveProject(snapshot, to);
        requireWritableList(snapshot, from);
        requireWritableList(snapshot, to);
        if (from !== to) {
          await writeOrThrow(deps, snapshot, [moveTaskIntent(taskId, to)]);
        }
        return formatTask(snapshot, snapshot.findRow('task', taskId)!);
      },
    },
    {
      name: 'move_all',
      description:
        'Move ALL active (incomplete) tasks from one project (list) to another in one call; completed tasks stay. It moves every active task in the source project, so confirm with the user before calling. You need write access to both.',
      inputSchema: {
        type: 'object',
        required: ['from_project_id', 'to_project_id'],
        properties: {
          from_project_id: { type: 'string', description: 'Source project id.' },
          to_project_id: { type: 'string', description: 'Destination project id.' },
        },
      },
      run: async (args, ctx) => {
        const from = requireStr(args, 'from_project_id');
        const to = requireStr(args, 'to_project_id');
        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        requireLiveProject(snapshot, from);
        requireLiveProject(snapshot, to);
        requireWritableList(snapshot, from);
        requireWritableList(snapshot, to);
        const tasks = from === to ? [] : openTasksOf(snapshot, from);
        if (tasks.length > 0) {
          await writeOrThrow(deps, snapshot, tasks.map((t) => moveTaskIntent(idOf(t), to)));
        }
        return { moved: tasks.length, from_project_id: from, to_project_id: to, task_ids: tasks.map(idOf) };
      },
    },
  ];
}
