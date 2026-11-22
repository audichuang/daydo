// Project tools (spec/mcp.md 8): list_projects, get_project, get_project_data, create_project,
// update_project, delete_project. Reads come from a fresh snapshot, writes go through the op writer.
import { uniqueProjectKey } from '../../domain/sortKey';
import { uuidv7 } from '../../domain/uuid';
import type { Snapshot, SnapshotRow } from '../../serverops/snapshot';
import { trashTaskIntent } from '../../serverops/taskWrites';
import { formatProject, openTasksOf, summarizeTask } from '../format';
import { bySortKey, compareKeys } from '../../serverops/values';
import { openSession, openWriteSession, requireStr, ToolValidationError, type ToolDef } from '../toolkit';

const COLOR = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

export function parseColor(v: unknown): string | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string' || !COLOR.test(v.trim())) {
    throw new ToolValidationError('color', "Argument 'color' must be #RRGGBB or #RGB");
  }
  return v.trim();
}

function liveProject(snapshot: Snapshot, id: string): SnapshotRow {
  const p = snapshot.liveProjects().find((x) => String(x.row.id) === id);
  if (!p) throw new Error(`Unknown project_id '${id}'; call list_projects first`);
  return p;
}

/** Inbox first, then by sortKey. */
function orderedProjects(snapshot: Snapshot): SnapshotRow[] {
  return snapshot.liveProjects().sort((a, b) => {
    const ai = a.row.isInbox === true ? 0 : 1;
    const bi = b.row.isInbox === true ? 0 : 1;
    return ai - bi || bySortKey(a, b);
  });
}

const PROJECT_ID = { type: 'string', description: 'Project id from list_projects.' };

export function projectTools(): ToolDef[] {
  return [
    {
      name: 'list_projects',
      description:
        'List the projects (lists) you can see, inbox first. Use this first to discover project IDs. Each project has `role` (owner, editor or viewer) and `can_write`; do not try to write to a project where can_write is false.',
      inputSchema: { type: 'object', properties: {} },
      run: async (_args, ctx) => {
        const { snapshot } = await openSession(ctx);
        return orderedProjects(snapshot).map((p) => formatProject(snapshot, p));
      },
    },
    {
      name: 'get_project',
      description:
        "Fetch a single project by id (name, color, view mode, role, can_write) without its tasks. Use get_project_data when you also need the project's tasks.",
      inputSchema: { type: 'object', required: ['project_id'], properties: { project_id: PROJECT_ID } },
      run: async (args, ctx) => {
        const { snapshot } = await openSession(ctx);
        return formatProject(snapshot, liveProject(snapshot, requireStr(args, 'project_id')));
      },
    },
    {
      name: 'get_project_data',
      description:
        'Fetch a project together with its open (not completed) tasks in one call. Returns { project, tasks } with task summaries (content cut to 100 characters, items and attachments as counts).',
      inputSchema: { type: 'object', required: ['project_id'], properties: { project_id: PROJECT_ID } },
      run: async (args, ctx) => {
        const { snapshot } = await openSession(ctx);
        const project = liveProject(snapshot, requireStr(args, 'project_id'));
        return {
          project: formatProject(snapshot, project),
          tasks: openTasksOf(snapshot, String(project.row.id)).map((t) => summarizeTask(snapshot, t)),
        };
      },
    },
    {
      name: 'create_project',
      description:
        'Create a new project (list). Only `name` is required. `color` is #RRGGBB or #RGB. `view_mode` is the default view; `kind` is TASK (a task list) or NOTE (a note list).',
      inputSchema: {
        type: 'object',
        required: ['name'],
        properties: {
          name: { type: 'string', description: 'Project (list) name. Required.' },
          color: { type: 'string', description: 'Hex color, #RRGGBB or #RGB.' },
          view_mode: { type: 'string', enum: ['list', 'kanban', 'timeline'], description: 'Default view mode.' },
          kind: { type: 'string', enum: ['TASK', 'NOTE'], description: 'Project type. Defaults to TASK.' },
        },
      },
      run: async (args, ctx) => {
        const name = requireStr(args, 'name').trim();
        const color = parseColor(args.color);
        const session = await openWriteSession(ctx);
        const { snapshot, now } = session;
        const sortKeys = snapshot.liveProjects().map((p) => String(p.row.sortKey ?? ''));
        const max = sortKeys.length === 0 ? null : sortKeys.reduce((a, b) => (compareKeys(a, b) >= 0 ? a : b));
        const id = uuidv7(now);
        const set: Record<string, unknown> = {
          id,
          name,
          viewMode: typeof args.view_mode === 'string' && args.view_mode !== '' ? args.view_mode : 'list',
          kind: typeof args.kind === 'string' && args.kind !== '' ? args.kind : 'TASK',
          isInbox: false,
          ownerId: snapshot.meMemberId,
          sortKey: uniqueProjectKey(max),
          showInSmart: 'all',
          notifyMode: 'all',
          ...(color !== undefined && { color }),
        };
        await session.write([{ entity: 'project', entityId: id, set }]);
        const { view, row } = session.readBack('project', id);
        return { ...formatProject(view, row), role: 'owner', can_write: true };
      },
    },
    {
      name: 'update_project',
      description: 'Update a project: supply project_id plus the fields to change; omitted fields are kept. `color` is #RRGGBB or #RGB. You need write access.',
      inputSchema: {
        type: 'object',
        required: ['project_id'],
        properties: {
          project_id: PROJECT_ID,
          name: { type: 'string', description: 'New name.' },
          color: { type: 'string', description: 'New hex color, #RRGGBB or #RGB.' },
        },
      },
      run: async (args, ctx) => {
        const id = requireStr(args, 'project_id');
        const color = parseColor(args.color);
        const name = typeof args.name === 'string' ? args.name.trim() : undefined;
        if (name === '') throw new ToolValidationError('name', "Argument 'name' must not be empty");
        if (name === undefined && color === undefined) throw new Error('Nothing to update: give name or color');
        const session = await openWriteSession(ctx);
        const { snapshot } = session;
        liveProject(snapshot, id);
        if (!snapshot.canWrite(id)) {
          throw new Error(`Project '${id}' is read-only for you (role: ${snapshot.memberships.get(id) ?? 'none'})`);
        }
        const set: Record<string, unknown> = {
          ...(name !== undefined && { name }),
          ...(color !== undefined && { color }),
        };
        await session.write([{ entity: 'project', entityId: id, set }]);
        const { view, row } = session.readBack('project', id);
        return formatProject(view, row);
      },
    },
    {
      name: 'delete_project',
      description:
        'Delete a project (list) and move all its tasks to the trash. Only the project owner can delete; the inbox cannot be deleted. DESTRUCTIVE: always confirm with the user before calling.',
      inputSchema: {
        type: 'object',
        required: ['project_id'],
        properties: { project_id: { type: 'string', description: 'The id of the project to delete.' } },
      },
      run: async (args, ctx) => {
        const id = requireStr(args, 'project_id');
        const session = await openWriteSession(ctx);
        const { snapshot, now } = session;
        const project = liveProject(snapshot, id);
        if (project.row.isInbox === true) throw new Error('The inbox cannot be deleted');
        if (snapshot.memberships.get(id) !== 'owner') {
          throw new Error(`Only the owner can delete project '${id}' (your role: ${snapshot.memberships.get(id) ?? 'none'})`);
        }
        const tasks = snapshot
          .rows('task')
          .filter((t) => t.row.projectId === id && t.row.deletedAt == null && t.row.purgedAt == null);
        // Tasks in their own push first: they may live in other members' scopes, which one push
        // does not apply atomically. The list goes only once every task is trashed, so a failed
        // run leaves the list live and a retry can finish it.
        if (tasks.length > 0) {
          await session.write(tasks.map((t) => trashTaskIntent(String(t.row.id), now)));
        }
        await session.write([{ entity: 'project', entityId: id, set: { deletedAt: now } }]);
        return { deleted: true, project_id: id, name: String(project.row.name ?? ''), trashed_tasks: tasks.length };
      },
    },
  ];
}
