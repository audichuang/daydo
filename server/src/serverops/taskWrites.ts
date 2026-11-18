// Task writes shared by the MCP task tools and the ICS engine, following the App's LocalDayDoAPI:
// which lists take task writes, where a new task sorts, the intents for create, edit, complete,
// trash and move, and the completion of a repeating task's occurrence. Callers own argument
// parsing, error wording and result formatting.
import { nextOccurrence, type Recurrence } from '../domain/recurrence';
import { movedSchedule, wallClockAt, type Schedule } from '../domain/schedule';
import { after, before } from '../domain/sortKey';
import type { NormalizedTag } from '../domain/tags';
import { uuidv5, uuidv7 } from '../domain/uuid';
import { ENTITY_FIELDS } from '../sync/entities';
import { userScope } from '../sync/scopeName';
import type { Snapshot, SnapshotRow } from './snapshot';
import { bySortKey, compareKeys, isNil, rowSchedule, sameSchedule, scheduleColumns } from './values';
import { pushIntents, WriteError, writeOrThrow, type WriteIntent, type WriteOutcome, type WriterDeps } from './writer';

// MARK: - Lists

/** Why tasks of a list may not be written: unknown, trashed or purged; archived; or read-only. */
export type TaskListDenial = 'missing' | 'archived' | 'read-only';

/**
 * Why the caller may not add or change tasks in `projectId`, or null when it may. Each caller
 * decides about archived lists: MCP treats them as unknown (as list_projects hides them), an ICS
 * subscription keeps syncing into them (`allowArchived`). Existence is checked before the role.
 */
export function taskListDenial(
  snapshot: Snapshot,
  projectId: string,
  options: { allowArchived?: boolean } = {},
): TaskListDenial | null {
  const project = snapshot.findRow('project', projectId)?.row;
  if (!project || !isNil(project.deletedAt) || !isNil(project.purgedAt)) return 'missing';
  if (!options.allowArchived && !isNil(project.archivedAt)) return 'archived';
  return snapshot.canWrite(projectId) ? null : 'read-only';
}

/** The smallest sortKey among the list's task rows, trashed and completed included (the App's MIN(sortKey)). */
export function firstTaskSortKey(snapshot: Snapshot, projectId: string): string | null {
  return snapshot
    .rows('task')
    .filter((t) => t.row.projectId === projectId && typeof t.row.sortKey === 'string' && t.row.sortKey !== '')
    .map((t) => String(t.row.sortKey))
    .reduce<string | null>((a, b) => (a === null || compareKeys(b, a) < 0 ? b : a), null);
}

// MARK: - Intents

/** Columns every new task carries. */
export interface NewTaskColumns {
  projectId: string;
  title: string;
  content: string;
  priority: number;
  reminders: readonly string[];
  tags: readonly string[];
  sortKey: string;
}

/**
 * A new open task. `extra` columns (schedule, repeatRule, importNote) follow the base ones; a column
 * left out stays unset, as in the App's op.
 */
export function createTaskIntent(id: string, columns: NewTaskColumns, extra: Record<string, unknown> = {}): WriteIntent {
  const { projectId, title, content, priority, reminders, tags, sortKey } = columns;
  return {
    entity: 'task',
    entityId: id,
    set: { id, projectId, title, content, priority, status: 0, reminders, tags, sortKey, ...extra },
  };
}

/** Changed columns of an existing task. */
export function patchTaskIntent(id: string, set: Record<string, unknown>): WriteIntent {
  return { entity: 'task', entityId: id, set };
}

export function completeTaskIntent(id: string, nowMs: number): WriteIntent {
  return patchTaskIntent(id, { status: 2, completedAt: nowMs });
}

export function uncompleteTaskIntent(id: string): WriteIntent {
  return patchTaskIntent(id, { status: 0, completedAt: null });
}

/** Restores a trashed task, optionally moving it (e.g. to the inbox when its original list is gone). */
export function restoreTaskIntent(id: string, projectId?: string): WriteIntent {
  return patchTaskIntent(id, {
    deletedAt: null,
    ...(projectId !== undefined && { projectId }),
  });
}

/** A soft delete: the task goes to the trash, where the App can restore it. */
export function trashTaskIntent(id: string, nowMs: number): WriteIntent {
  return patchTaskIntent(id, { deletedAt: nowMs });
}

export function moveTaskIntent(id: string, projectId: string): WriteIntent {
  return patchTaskIntent(id, { projectId });
}

/** Tag rows for a task's tags (LocalDayDoAPI.normalizeTags): create missing ones, revive trashed ones. */
export function tagIntents(snapshot: Snapshot, userId: string, tags: readonly NormalizedTag[]): WriteIntent[] {
  const own = snapshot.rows('tag').filter((t) => t.scope === userScope(userId));
  let last: string | null = own
    .map((t) => String(t.row.sortKey ?? ''))
    .reduce<string | null>((a, b) => (a === null || compareKeys(b, a) > 0 ? b : a), null);
  const intents: WriteIntent[] = [];
  for (const tag of tags) {
    const existing = own.find((t) => t.row.name === tag.name);
    if (existing) {
      if (!isNil(existing.row.deletedAt)) {
        intents.push({ entity: 'tag', entityId: tag.name, set: { deletedAt: null } });
      }
      continue;
    }
    last = after(last);
    intents.push({
      entity: 'tag',
      entityId: tag.name,
      set: { name: tag.name, label: tag.label, sortKey: last },
    });
  }
  return intents;
}

/** New checklist rows in order; blank titles are skipped (as in the App). */
export function checklistIntents(taskId: string, titles: readonly string[], nowMs: number): WriteIntent[] {
  let key: string | null = null;
  return titles
    .filter((t) => t.trim() !== '')
    .map((title): WriteIntent => {
      key = after(key);
      const id = uuidv7(nowMs);
      return {
        entity: 'checklistItem',
        entityId: id,
        set: { id, taskId, title, status: 0, sortKey: key },
      };
    });
}

function liveChecklist(snapshot: Snapshot, taskId: string): SnapshotRow[] {
  return snapshot
    .rows('checklistItem')
    .filter((c) => c.row.taskId === taskId && isNil(c.row.deletedAt) && isNil(c.row.purgedAt));
}

/** A task to create (LocalDayDoAPI.createTask). A null schedule or repeatRule leaves those columns out. */
export interface NewTask {
  projectId: string;
  title: string;
  content: string;
  priority: number;
  reminders: readonly string[];
  tags: readonly NormalizedTag[];
  subtasks: readonly string[];
  schedule: Schedule | null;
  repeatRule: string | null;
  countdown?: boolean;
}

/** The new task first in its list, then its tag rows and its checklist. */
export function newTaskIntents(snapshot: Snapshot, userId: string, id: string, task: NewTask, nowMs: number): WriteIntent[] {
  const columns: NewTaskColumns = {
    projectId: task.projectId,
    title: task.title,
    content: task.content,
    priority: task.priority,
    reminders: task.reminders,
    tags: task.tags.map((t) => t.name),
    sortKey: before(firstTaskSortKey(snapshot, task.projectId)),
  };
  return [
    createTaskIntent(id, columns, {
      ...(task.countdown !== undefined && { countdown: task.countdown }),
      ...(task.repeatRule !== null && { repeatRule: task.repeatRule }),
      ...(task.schedule !== null && scheduleColumns(task.schedule)),
    }),
    ...tagIntents(snapshot, userId, task.tags),
    ...checklistIntents(id, task.subtasks, nowMs),
  ];
}

/**
 * An edit of an existing task (LocalDayDoAPI.updateTask). undefined leaves a field alone; a null
 * schedule clears the date. `tags` and `subtasks` replace the whole set.
 */
export interface TaskPatch {
  title?: string;
  content?: string;
  priority?: number;
  schedule?: Schedule | null;
  reminders?: readonly string[];
  repeatRule?: string | null;
  tags?: readonly NormalizedTag[];
  subtasks?: readonly string[];
  countdown?: boolean;
}

/**
 * The task's changed columns, then its tag rows and the replaced checklist (old items trashed, new
 * ones in order). The schedule goes out only when it differs, so the zone is not rewritten; a
 * cleared date takes its reminders and repeat with it. The task is touched, so a tags- or
 * subtasks-only edit still bumps its updatedAt. Null when there is nothing to write.
 */
export function patchTaskIntents(
  snapshot: Snapshot,
  userId: string,
  task: SnapshotRow,
  patch: TaskPatch,
  nowMs: number,
): WriteIntent[] | null {
  const taskId = String(task.row.id);
  const cur = rowSchedule(task.row);
  const next = patch.schedule;
  const set: Record<string, unknown> = {
    ...(patch.title !== undefined && { title: patch.title }),
    ...(patch.content !== undefined && { content: patch.content }),
    ...(patch.priority !== undefined && { priority: patch.priority }),
    ...(next !== undefined && !sameSchedule(next, cur) && scheduleColumns(next)),
    ...(patch.reminders !== undefined && { reminders: patch.reminders }),
    ...(patch.repeatRule !== undefined && { repeatRule: patch.repeatRule }),
    ...(patch.countdown !== undefined && { countdown: patch.countdown }),
    ...(next === null && cur !== null && { reminders: [], repeatRule: null }),
  };
  const extra: WriteIntent[] = [];
  if (patch.tags !== undefined) {
    set.tags = patch.tags.map((t) => t.name);
    extra.push(...tagIntents(snapshot, userId, patch.tags));
  }
  if (patch.subtasks !== undefined) {
    for (const c of liveChecklist(snapshot, taskId)) {
      extra.push({ entity: 'checklistItem', entityId: String(c.row.id), set: { deletedAt: nowMs } });
    }
    extra.push(...checklistIntents(taskId, patch.subtasks, nowMs));
  }
  if (Object.keys(set).length === 0 && extra.length === 0) return null;
  return [{ ...patchTaskIntent(taskId, set), touch: true }, ...extra];
}

// MARK: - Completing a repeating task (LocalDayDoAPI.completeTask)

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
function copyIntent(snapshot: Snapshot, original: Record<string, unknown>, copyId: string, nowMs: number): WriteIntent | null {
  const existing = snapshot.findRow('task', copyId);
  if (existing && isNil(existing.row.deletedAt)) {
    if (Number(existing.row.status ?? 0) === 2) return null;
    return completeTaskIntent(copyId, nowMs);
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
      completedAt: nowMs,
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
  nowMs: number,
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
          createdAt: existing?.row.createdAt ?? nowMs,
          updatedAt: nowMs,
          ...(existing && { deletedAt: null }),
        },
        verbatim: ['sortKey'],
      });
    }
    if (Number(item.status ?? 0) !== 0) {
      reopens.push({ entity: 'checklistItem', entityId: String(item.id), set: { status: 0 } });
    }
  }
  return { copies, reopens };
}

export interface CompleteOccurrenceOptions {
  /** Zone for "today" when the task floats (`DEFAULT_TIMEZONE`). */
  defaultTimeZone: string;
  nowMs: number;
}

/**
 * Records a completed copy of the current occurrence and moves the task to its next one on or after
 * today. The next occurrence is computed before anything is written, so a rule it cannot handle
 * writes nothing. Then pushes in the App's order (copy, checklist copies, reopened checklist,
 * original), each only after the previous one succeeded: the original moves last, so a failure
 * leaves it on the same occurrence with its checklist intact, and a retry reuses the same v5 ids.
 * Returns the copy's id and the outcomes of the copy and checklist writes (for withCreated).
 */
export async function completeOccurrence(
  deps: WriterDeps,
  snapshot: Snapshot,
  task: SnapshotRow,
  rule: Recurrence,
  schedule: Schedule,
  { defaultTimeZone, nowMs }: CompleteOccurrenceOptions,
): Promise<{ copyId: string; outcomes: WriteOutcome[] }> {
  const taskId = String(task.row.id);
  // Taken before any push: pushIntents refreshes cached rows from the response.
  const original = { ...task.row };
  const items = liveChecklist(snapshot, taskId)
    .sort(bySortKey)
    .map((c) => ({ ...c.row }));

  const today = wallClockAt(nowMs, schedule.timeZone ?? defaultTimeZone).day;
  let next = nextOccurrence(rule, schedule.startDay);
  for (let n = 0; next < today && n < MAX_CATCH_UP; n++) next = nextOccurrence(rule, next);

  const v5 = await uuidv5(`${taskId}|${schedule.startDay}|${schedule.startMinute ?? ''}`);
  let copyId = isNil(snapshot.findRow('task', v5)?.row.purgedAt) ? v5 : uuidv7(nowMs);
  const outcomes: WriteOutcome[] = [];
  const intent = copyIntent(snapshot, original, copyId, nowMs);
  if (intent) {
    let [out] = await pushIntents(deps, snapshot, [intent], { nowMs });
    if (out?.status === 'purged') {
      // A tombstone the snapshot could not see (its list is not visible to us).
      copyId = uuidv7(nowMs);
      [out] = await pushIntents(deps, snapshot, [copyIntent(snapshot, original, copyId, nowMs)!], { nowMs });
    }
    if (out?.status !== 'applied') throw new WriteError(out!);
    outcomes.push(out);
  }

  const { copies, reopens } = await checklistCopyIntents(snapshot, items, copyId, nowMs);
  if (copies.length > 0) outcomes.push(...(await writeOrThrow(deps, snapshot, copies, { nowMs })));
  if (reopens.length > 0) outcomes.push(...(await writeOrThrow(deps, snapshot, reopens, { nowMs })));

  await writeOrThrow(deps, snapshot, [patchTaskIntent(taskId, scheduleColumns(movedSchedule(schedule, next)))], { nowMs });
  return { copyId, outcomes };
}
