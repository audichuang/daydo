// Task tools (spec/mcp.md 8).
// Read: list_recent_tasks, list_tasks, search_tasks, get_task, get_completed_tasks.
// Write: create_task, update_task, complete_task, delete_task, move_task, move_all.
// Visibility comes from snapshot.liveTasks(): no trashed tasks, nothing in trashed or archived lists.
import { nextOccurrence, parseRecurrence, validateRepeat, type Recurrence } from '../../domain/recurrence';
import { parseReminderCsv } from '../../domain/reminders';
import {
  isValidTimeZone,
  movedSchedule,
  scheduleFromAPI,
  scheduleWithDue,
  wallClockAt,
  type Schedule,
  type ScheduleContext,
} from '../../domain/schedule';
import { after, before } from '../../domain/sortKey';
import { normalizeTagLabels, normalizeTags, type NormalizedTag } from '../../domain/tags';
import { uuidv5, uuidv7 } from '../../domain/uuid';
import type { Snapshot, SnapshotRow } from '../../serverops/snapshot';
import {
  assertHasData,
  pushIntents,
  WriteError,
  writeOrThrow,
  type WriteIntent,
  type WriteOutcome,
  type WriterDeps,
} from '../../serverops/writer';
import { ENTITY_FIELDS } from '../../sync/entities';
import { userScope } from '../../sync/scopeName';
import { bySortKey, compareKeys, formatTask, openTasksOf, summarizeTask } from '../format';
import { requireStr, ToolValidationError, type ToolContext, type ToolDef } from '../registry';
import { openSession } from './projects';

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
const SCHEDULE_KEYS = ['startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone'] as const;

const isNil = (v: unknown) => v === undefined || v === null;
const bump = (row: Record<string, unknown>, now: number) => Math.max(now, Number(row.updatedAt ?? 0) + 1);

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

function requireWritable(snapshot: Snapshot, projectId: string): void {
  if (!snapshot.canWrite(projectId)) {
    throw new Error(`Project '${projectId}' is read-only for you (role: ${snapshot.memberships.get(projectId) ?? 'none'})`);
  }
}

function scheduleContext(ctx: ToolContext, originalTimeZone: string | null = null): ScheduleContext {
  return { originalTimeZone, defaultTimeZone: ctx.services?.defaultTimeZone ?? DEFAULT_TIME_ZONE };
}

function currentSchedule(row: Record<string, unknown>): Schedule | null {
  if (typeof row.startDay !== 'string') return null;
  const opt = <T>(v: unknown) => (isNil(v) ? null : (v as T));
  return {
    startDay: row.startDay,
    startMinute: opt<number>(row.startMinute),
    endDay: opt<string>(row.endDay),
    endMinute: opt<number>(row.endMinute),
    timeZone: opt<string>(row.timeZone),
  };
}

function sameSchedule(a: Schedule | null, b: Schedule | null): boolean {
  if (a === null || b === null) return a === b;
  return SCHEDULE_KEYS.every((k) => a[k] === b[k]);
}

/** All five schedule columns (null when cleared); the writer sends them as one group. */
function scheduleSet(s: Schedule | null): Record<string, unknown> {
  return Object.fromEntries(SCHEDULE_KEYS.map((k) => [k, s ? s[k] : null]));
}

/** Tag rows for a task's tags (LocalDayDoAPI.normalizeTags): create missing ones, revive trashed ones. */
function tagIntents(snapshot: Snapshot, userId: string, tags: readonly NormalizedTag[], now: number): WriteIntent[] {
  const own = snapshot.rows('tag').filter((t) => t.scope === userScope(userId));
  let last: string | null = own
    .map((t) => String(t.row.sortKey ?? ''))
    .reduce<string | null>((a, b) => (a === null || compareKeys(b, a) > 0 ? b : a), null);
  const intents: WriteIntent[] = [];
  for (const tag of tags) {
    const existing = own.find((t) => t.row.name === tag.name);
    if (existing) {
      if (!isNil(existing.row.deletedAt)) {
        intents.push({ entity: 'tag', entityId: tag.name, set: { deletedAt: null, updatedAt: bump(existing.row, now) } });
      }
      continue;
    }
    last = after(last);
    intents.push({
      entity: 'tag',
      entityId: tag.name,
      set: { name: tag.name, label: tag.label, sortKey: last, createdAt: now, updatedAt: now },
    });
  }
  return intents;
}

/** New checklist rows in order; blank titles are skipped (as in the App). */
function checklistIntents(taskId: string, titles: readonly string[], now: number): WriteIntent[] {
  let key: string | null = null;
  return titles
    .filter((t) => t.trim() !== '')
    .map((title): WriteIntent => {
      key = after(key);
      const id = uuidv7(now);
      return {
        entity: 'checklistItem',
        entityId: id,
        set: { id, taskId, title, status: 0, sortKey: key, createdAt: now, updatedAt: now },
      };
    });
}

/** The snapshot plus rows created by this write, so the result can show new tasks and checklist items. */
function withCreated(snapshot: Snapshot, outcomes: readonly WriteOutcome[]): Snapshot {
  const created: SnapshotRow[] = outcomes
    .filter((o) => o.row && !snapshot.findRow(o.entity, o.entityId))
    .map((o) => ({ entity: o.entity, scope: '', row: o.row!, clocks: o.clocks, serverSeq: 0 }));
  const keyOf = (r: SnapshotRow) => String(r.entity === 'tag' ? r.row.name : r.row.id);
  return {
    ...snapshot,
    rows: (entity) => [...snapshot.rows(entity), ...created.filter((r) => r.entity === entity)],
    findRow: (entity, id) => snapshot.findRow(entity, id) ?? created.find((r) => r.entity === entity && keyOf(r) === id),
  };
}

// MARK: - complete_task (LocalDayDoAPI.completeTask)

/** Columns a completed copy takes from the original as they are (Swift `copy = t`). */
const COPIED_TASK_COLUMNS = Object.keys(ENTITY_FIELDS.task).filter(
  (k) => !['id', 'status', 'completedAt', 'repeatRule', 'createdAt', 'updatedAt', 'deletedAt'].includes(k),
);
/** Catch-up bound for a long-overdue repeating task, as in the App. */
const MAX_CATCH_UP = 1000;

/**
 * The write that records the completed copy `copyId`, or null when it already exists completed.
 * A live open copy only gets its status; a new or trashed one is rebuilt from the original.
 */
function copyIntent(snapshot: Snapshot, original: Record<string, unknown>, copyId: string, now: number): WriteIntent | null {
  const existing = snapshot.findRow('task', copyId);
  if (existing && isNil(existing.row.deletedAt)) {
    if (Number(existing.row.status ?? 0) === 2) return null;
    return { entity: 'task', entityId: copyId, set: { status: 2, completedAt: now, updatedAt: bump(existing.row, now) } };
  }
  // A new row omits empty columns (as the App's op); a trashed one is overwritten column by column.
  const copied = Object.fromEntries(
    COPIED_TASK_COLUMNS.filter((k) => existing || !isNil(original[k])).map((k) => [k, original[k] ?? null]),
  );
  return {
    entity: 'task',
    entityId: copyId,
    set: {
      id: copyId,
      ...copied,
      status: 2,
      completedAt: now,
      createdAt: existing?.row.createdAt ?? now,
      updatedAt: existing ? bump(existing.row, now) : now,
      ...(existing && { repeatRule: null, deletedAt: null }),
    },
    verbatim: Object.keys(copied),
  };
}

/**
 * Copies of the live checklist (v5 ids under the copy) and the reopened originals, kept apart:
 * copies live in the completer's scope and originals in the task's, so one push is not atomic and
 * the originals may only be reopened once every copy is stored.
 */
async function checklistCopyIntents(
  snapshot: Snapshot,
  items: readonly Record<string, unknown>[],
  copyId: string,
  now: number,
): Promise<{ copies: WriteIntent[]; reopens: WriteIntent[] }> {
  const copies: WriteIntent[] = [];
  const reopens: WriteIntent[] = [];
  for (const item of items) {
    const id = await uuidv5(`${copyId}|${String(item.id)}`);
    const existing = snapshot.findRow('checklistItem', id);
    if (!existing || (!isNil(existing.row.deletedAt) && isNil(existing.row.purgedAt))) {
      copies.push({
        entity: 'checklistItem',
        entityId: id,
        set: {
          id,
          taskId: copyId,
          title: item.title,
          status: item.status,
          sortKey: item.sortKey,
          createdAt: existing?.row.createdAt ?? now,
          updatedAt: now,
          ...(existing && { deletedAt: null }),
        },
        verbatim: ['sortKey'],
      });
    }
    if (Number(item.status ?? 0) !== 0) {
      reopens.push({ entity: 'checklistItem', entityId: String(item.id), set: { status: 0, updatedAt: bump(item, now) } });
    }
  }
  return { copies, reopens };
}

/**
 * Records a completed copy of the current occurrence and moves the task to its next one.
 * The next occurrence is computed before anything is written, so a rule it cannot handle writes
 * nothing. Then pushes in the App's order (copy, checklist copies, reopened checklist, original),
 * each only after the previous one succeeded: the original moves last, so a failure leaves it on
 * the same occurrence with its checklist intact, and a retry reuses the same v5 ids.
 */
async function completeOccurrence(
  deps: WriterDeps,
  snapshot: Snapshot,
  task: SnapshotRow,
  rule: Recurrence,
  schedule: Schedule,
  ctx: ToolContext,
): Promise<ReturnType<typeof formatTask>> {
  const now = Date.now();
  const taskId = idOf(task);
  // Taken before any push: pushIntents refreshes cached rows from the response.
  const original = { ...task.row };
  const items = snapshot
    .rows('checklistItem')
    .filter((c) => c.row.taskId === taskId && isNil(c.row.deletedAt) && isNil(c.row.purgedAt))
    .sort(bySortKey)
    .map((c) => ({ ...c.row }));

  const today = wallClockAt(now, schedule.timeZone ?? scheduleContext(ctx).defaultTimeZone).day;
  let next = nextOccurrence(rule, schedule.startDay);
  for (let n = 0; next < today && n < MAX_CATCH_UP; n++) next = nextOccurrence(rule, next);

  const v5 = await uuidv5(`${taskId}|${schedule.startDay}|${schedule.startMinute ?? ''}`);
  let copyId = isNil(snapshot.findRow('task', v5)?.row.purgedAt) ? v5 : uuidv7(now);
  const outcomes: WriteOutcome[] = [];
  const intent = copyIntent(snapshot, original, copyId, now);
  if (intent) {
    let [out] = await pushIntents(deps, snapshot, [intent]);
    if (out?.status === 'purged') {
      // A tombstone the snapshot could not see (its list is not visible to us).
      copyId = uuidv7(now);
      [out] = await pushIntents(deps, snapshot, [copyIntent(snapshot, original, copyId, now)!]);
    }
    if (out?.status !== 'applied') throw new WriteError(out!);
    outcomes.push(out);
  }

  const { copies, reopens } = await checklistCopyIntents(snapshot, items, copyId, now);
  if (copies.length > 0) outcomes.push(...(await writeOrThrow(deps, snapshot, copies)));
  if (reopens.length > 0) outcomes.push(...(await writeOrThrow(deps, snapshot, reopens)));

  await writeOrThrow(deps, snapshot, [
    { entity: 'task', entityId: taskId, set: { ...scheduleSet(movedSchedule(schedule, next)), updatedAt: bump(original, now) } },
  ]);

  const view = withCreated(snapshot, outcomes);
  return formatTask(view, view.findRow('task', copyId)!);
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
        requireLiveProject(snapshot, projectId);
        requireWritable(snapshot, projectId);
        // Before every task row of the list, trashed and completed included (as the App's MIN(sortKey)).
        const first = snapshot
          .rows('task')
          .filter((t) => t.row.projectId === projectId && typeof t.row.sortKey === 'string' && t.row.sortKey !== '')
          .map((t) => String(t.row.sortKey))
          .reduce<string | null>((a, b) => (a === null || compareKeys(b, a) < 0 ? b : a), null);
        const now = Date.now();
        const id = uuidv7(now);
        const set: Record<string, unknown> = {
          id,
          projectId,
          title,
          content,
          priority,
          status: 0,
          reminders,
          tags: tags.map((t) => t.name),
          sortKey: before(first),
          createdAt: now,
          updatedAt: now,
          ...(repeatRule !== null && { repeatRule }),
          ...(schedule !== null && scheduleSet(schedule)),
        };
        const outcomes = await writeOrThrow(deps, snapshot, [
          { entity: 'task', entityId: id, set },
          ...tagIntents(snapshot, ctx.userId, tags, now),
          ...checklistIntents(id, subtasks, now),
        ]);
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
        requireWritable(snapshot, projectId);
        const cur = currentSchedule(task.row);
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

        const now = Date.now();
        const set: Record<string, unknown> = {
          ...(title !== undefined && { title }),
          ...(content !== undefined && { content }),
          ...(priority !== undefined && { priority }),
          ...(next !== undefined && !sameSchedule(next, cur) && scheduleSet(next)),
          ...(reminders !== undefined && { reminders }),
          ...(repeatRule !== undefined && { repeatRule }),
          // A cleared date takes its reminders and repeat with it.
          ...(next === null && cur !== null && { reminders: [], repeatRule: null }),
        };
        const extra: WriteIntent[] = [];
        if (rawTags !== undefined) {
          const tags = normalizeTagLabels(rawTags);
          set.tags = tags.map((t) => t.name);
          extra.push(...tagIntents(snapshot, ctx.userId, tags, now));
        }
        if (subtasks !== undefined) {
          const old = snapshot
            .rows('checklistItem')
            .filter((c) => c.row.taskId === taskId && isNil(c.row.deletedAt) && isNil(c.row.purgedAt));
          for (const c of old) {
            extra.push({ entity: 'checklistItem', entityId: String(c.row.id), set: { deletedAt: now, updatedAt: bump(c.row, now) } });
          }
          extra.push(...checklistIntents(taskId, subtasks, now));
        }
        if (Object.keys(set).length === 0 && extra.length === 0) {
          throw new Error('Nothing to update: give at least one field to change');
        }
        set.updatedAt = bump(task.row, now);
        const outcomes = await writeOrThrow(deps, snapshot, [{ entity: 'task', entityId: taskId, set }, ...extra]);
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
        requireWritable(snapshot, projectId);
        if (num(task, 'status') === 2) return formatTask(snapshot, task);
        const rule = typeof task.row.repeatRule === 'string' ? parseRecurrence(task.row.repeatRule) : null;
        const schedule = currentSchedule(task.row);
        if (rule !== null && schedule !== null) return completeOccurrence(deps, snapshot, task, rule, schedule, ctx);
        const now = Date.now();
        await writeOrThrow(deps, snapshot, [
          { entity: 'task', entityId: taskId, set: { status: 2, completedAt: now, updatedAt: bump(task.row, now) } },
        ]);
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
        requireWritable(snapshot, projectId);
        const now = Date.now();
        await writeOrThrow(deps, snapshot, [
          { entity: 'task', entityId: taskId, set: { deletedAt: now, updatedAt: bump(task.row, now) } },
        ]);
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
        const task = taskIn(snapshot, taskId, from);
        requireLiveProject(snapshot, to);
        requireWritable(snapshot, from);
        requireWritable(snapshot, to);
        if (from !== to) {
          const now = Date.now();
          await writeOrThrow(deps, snapshot, [
            { entity: 'task', entityId: taskId, set: { projectId: to, updatedAt: bump(task.row, now) } },
          ]);
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
        requireWritable(snapshot, from);
        requireWritable(snapshot, to);
        const tasks = from === to ? [] : openTasksOf(snapshot, from);
        if (tasks.length > 0) {
          const now = Date.now();
          await writeOrThrow(
            deps,
            snapshot,
            tasks.map((t): WriteIntent => ({ entity: 'task', entityId: idOf(t), set: { projectId: to, updatedAt: bump(t.row, now) } })),
          );
        }
        return { moved: tasks.length, from_project_id: from, to_project_id: to, task_ids: tasks.map(idOf) };
      },
    },
  ];
}
