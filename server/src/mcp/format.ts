// Output shapes for MCP tools (spec/mcp.md 8): snake_case project, task and tag objects.
import { scheduleToAPI, type Schedule } from '../domain/schedule';
import type { Snapshot, SnapshotRow } from '../serverops/snapshot';

export const CONTENT_SUMMARY_LIMIT = 100;

function nil<T>(v: T | undefined | null): T | null {
  return v === undefined ? null : v;
}

function absent(row: Record<string, unknown>, ...fields: string[]): boolean {
  return fields.every((f) => row[f] === undefined || row[f] === null);
}

/** Plain code-unit order, the same order the App uses for sort keys. */
export function compareKeys(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function bySortKey(a: SnapshotRow, b: SnapshotRow): number {
  return compareKeys(String(a.row.sortKey ?? ''), String(b.row.sortKey ?? '')) || compareKeys(String(a.row.id), String(b.row.id));
}

/** Project with the caller's role; `can_write` tells the model not to try writing a read-only list. */
export function formatProject(snapshot: Snapshot, p: SnapshotRow) {
  const r = p.row;
  const id = String(r.id);
  return {
    id,
    name: String(r.name ?? ''),
    color: nil(r.color as string | null | undefined),
    icon: nil(r.icon as string | null | undefined),
    folder_id: nil(r.folderId as string | null | undefined),
    view_mode: String(r.viewMode ?? 'list'),
    kind: String(r.kind ?? 'TASK'),
    is_inbox: r.isInbox === true,
    owner_id: String(r.ownerId ?? ''),
    sort_key: String(r.sortKey ?? ''),
    show_in_smart: String(r.showInSmart ?? 'all'),
    notify_mode: String(r.notifyMode ?? 'all'),
    archived: !absent(r, 'archivedAt'),
    role: snapshot.memberships.get(id) ?? null,
    can_write: snapshot.canWrite(id),
    created_at: nil(r.createdAt as number | null | undefined),
    updated_at: nil(r.updatedAt as number | null | undefined),
  };
}

function scheduleOf(r: Record<string, unknown>): Schedule | null {
  if (typeof r.startDay !== 'string') return null;
  return {
    startDay: r.startDay,
    startMinute: nil(r.startMinute as number | null | undefined),
    endDay: nil(r.endDay as string | null | undefined),
    endMinute: nil(r.endMinute as number | null | undefined),
    timeZone: nil(r.timeZone as string | null | undefined),
  };
}

function checklistOf(snapshot: Snapshot, taskId: string) {
  return snapshot
    .rows('checklistItem')
    .filter((c) => c.row.taskId === taskId && absent(c.row, 'deletedAt', 'purgedAt'))
    .sort(bySortKey)
    .map((c) => ({
      id: String(c.row.id),
      title: String(c.row.title ?? ''),
      status: Number(c.row.status ?? 0),
      sort_key: String(c.row.sortKey ?? ''),
    }));
}

/** Full task (get_task shape). */
export function formatTask(snapshot: Snapshot, t: SnapshotRow) {
  const r = t.row;
  const sched = scheduleOf(r);
  const api = sched ? scheduleToAPI(sched) : { start: null, due: null, all_day: false, timezone: nil(r.timeZone as string | null | undefined) };
  return {
    id: String(r.id),
    project_id: String(r.projectId ?? ''),
    title: String(r.title ?? ''),
    content: String(r.content ?? ''),
    priority: Number(r.priority ?? 0),
    status: Number(r.status ?? 0),
    start: api.start,
    due: api.due,
    all_day: api.all_day,
    timezone: api.timezone,
    reminders: Array.isArray(r.reminders) ? (r.reminders as string[]) : [],
    repeat: nil(r.repeatRule as string | null | undefined),
    tags: Array.isArray(r.tags) ? (r.tags as string[]) : [],
    items: checklistOf(snapshot, String(r.id)),
    completed_at: nil(r.completedAt as number | null | undefined),
    created_at: nil(r.createdAt as number | null | undefined),
    updated_at: nil(r.updatedAt as number | null | undefined),
    import_note: nil(r.importNote as string | null | undefined),
  };
}

/** List-tool shape: `content` cut to 100 characters, `items` reduced to a count. */
export function summarizeTask(snapshot: Snapshot, t: SnapshotRow) {
  const { content, items, ...rest } = formatTask(snapshot, t);
  return {
    ...rest,
    content: [...content].length > CONTENT_SUMMARY_LIMIT ? `${[...content].slice(0, CONTENT_SUMMARY_LIMIT).join('')}...` : content,
    items: items.length,
  };
}

/** Open task rows of one project (status 0, not trashed). */
export function openTasksOf(snapshot: Snapshot, projectId: string): SnapshotRow[] {
  return snapshot
    .liveTasks()
    .filter((t) => t.row.projectId === projectId && Number(t.row.status ?? 0) === 0)
    .sort(bySortKey);
}
