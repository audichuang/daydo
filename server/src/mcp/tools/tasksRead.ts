// Read-only task tools (spec/mcp.md 8): list_recent_tasks, list_tasks, search_tasks, get_task, get_completed_tasks.
// Visibility comes from snapshot.liveTasks(): no trashed tasks, nothing in trashed or archived lists.
import { normalizeTags } from '../../domain/tags';
import type { Snapshot, SnapshotRow } from '../../serverops/snapshot';
import { bySortKey, compareKeys } from '../../serverops/values';
import { formatTask, summarizeTask } from '../format';
import { openSession, requireStr, ToolValidationError, type ToolDef } from '../toolkit';

export const SEARCH_LIMIT = 200;
const DEFAULT_RECENT_LIMIT = 10;

export const num = (t: SnapshotRow, field: string) => Number(t.row[field] ?? 0);
export const isOpen = (t: SnapshotRow) => num(t, 'status') === 0;
export const idOf = (t: SnapshotRow) => String(t.row.id);
const byUpdatedDesc = (a: SnapshotRow, b: SnapshotRow) =>
  num(b, 'updatedAt') - num(a, 'updatedAt') || compareKeys(idOf(a), idOf(b));

export function requireLiveProject(snapshot: Snapshot, id: string): SnapshotRow {
  const p = snapshot.liveProjects().find((x) => String(x.row.id) === id);
  if (!p) throw new Error(`Unknown project_id '${id}'; call list_projects first`);
  return p;
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
export function taskIn(snapshot: Snapshot, taskId: string, projectId: string): SnapshotRow {
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

function searchableTasksWithDeleted(snapshot: Snapshot): SnapshotRow[] {
  const liveIds = new Set(snapshot.liveProjects().map((p) => String(p.row.id)));
  const projectsById = new Map(snapshot.rows('project').map((p) => [String(p.row.id), p]));
  return snapshot.rows('task').filter((t) => {
    if (t.row.purgedAt != null) return false;
    const pid = String(t.row.projectId ?? '');
    if (t.row.deletedAt == null) return liveIds.has(pid);
    if (!snapshot.memberships.has(pid)) return false;
    const p = projectsById.get(pid);
    return !p || p.row.purgedAt == null;
  });
}

export const PROJECT_ID = { type: 'string', description: 'Project id from list_projects.' };
export const TASK_ID = { type: 'string', description: 'The task `id` field returned by the list, search and get tools.' };
const OPTIONAL_PROJECT = { type: 'string', description: 'Optional. Restrict to this project; omit for all projects.' };

export function taskReadTools(): ToolDef[] {
  return [
    {
      name: 'list_recent_tasks',
      description:
        'List recent tasks in a project (newest update first), including completed ones by default, so it also finds a finished task with the same title or intent. Each task carries status: 0 active or 2 completed. Returns task summaries (content cut to 100 characters, items and attachments as counts; see get_task).',
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
      description: `Case-insensitive substring search across task titles, content, tags and checklist item titles. The query is matched as one string (not split into words), so search one keyword at a time. By default includes completed tasks; set active_only to restrict to pending. Set include_deleted to also search trashed tasks (marked with deleted: true, e.g. to find a task_id before calling restore_task). Active tasks come first, newest update first; at most ${SEARCH_LIMIT} results. Returns task summaries (see get_task).`,
      inputSchema: {
        type: 'object',
        required: ['query'],
        properties: {
          query: { type: 'string', description: 'Text to look for (one substring, case-insensitive).' },
          active_only: { type: 'boolean', description: 'Exclude completed tasks.' },
          include_deleted: {
            type: 'boolean',
            description: 'Include trashed (soft-deleted) tasks in results (marked with deleted: true). Default false.',
          },
        },
      },
      run: async (args, ctx) => {
        const query = requireStr(args, 'query').trim().toLowerCase();
        const activeOnly = optionalBool(args, 'active_only');
        const includeDeleted = optionalBool(args, 'include_deleted');
        const { snapshot } = await openSession(ctx);
        const candidates = includeDeleted ? searchableTasksWithDeleted(snapshot) : snapshot.liveTasks();
        return candidates
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
          .map((t) => ({
            ...summarizeTask(snapshot, t),
            ...(t.row.deletedAt != null && { deleted: true }),
          }));
      },
    },
    {
      name: 'get_task',
      description:
        'Fetch the full record for a single task (including full content, checklist items and attachments). List/search tools return summaries only (content cut to 100 characters, checklist and attachments as counts); call this for the rest. Set include_deleted to true to also read trashed tasks or tasks in archived lists (marked with deleted: true and/or archived: true); purged tasks/lists and non-member lists remain inaccessible. Errors when the task is not in the given project.',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id'],
        properties: {
          project_id: PROJECT_ID,
          task_id: TASK_ID,
          include_deleted: {
            type: 'boolean',
            description:
              'Allow fetching trashed tasks or tasks in archived lists (marked deleted: true / archived: true); still excludes purged tasks/lists and non-member lists. Default false.',
          },
        },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const includeDeleted = optionalBool(args, 'include_deleted');
        const { snapshot } = await openSession(ctx);
        if (!includeDeleted) {
          return formatTask(snapshot, taskIn(snapshot, taskId, projectId));
        }
        const task = snapshot.findRow('task', taskId);
        if (!task || task.row.purgedAt != null) {
          throw new Error(`Unknown task_id '${taskId}'`);
        }
        const pid = String(task.row.projectId ?? '');
        const project = snapshot.findRow('project', pid);
        if (!project || project.row.purgedAt != null || !snapshot.memberships.has(pid)) {
          throw new Error(`Unknown task_id '${taskId}'`);
        }
        if (pid !== projectId) {
          throw new Error(`Task '${taskId}' is not in project '${projectId}' (it is in '${pid}')`);
        }
        return {
          ...formatTask(snapshot, task),
          ...(task.row.deletedAt != null && { deleted: true }),
          ...(project.row.archivedAt != null && { archived: true }),
        };
      },
    },
    {
      name: 'get_completed_tasks',
      description:
        'List completed tasks, most recently completed first, optionally filtered to one project. Returns every completed task with no limit, so pass project_id when you only need one list. Returns task summaries (see get_task).',
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
