// Tag tools (spec/mcp.md 8): list_tags, create_tag. Tags have no nesting in DayDo.
import { normalizeTagLabels } from '../../domain/tags';
import { after } from '../../domain/sortKey';
import type { Snapshot, SnapshotRow } from '../../serverops/snapshot';
import { writeOrThrow } from '../../serverops/writer';
import { userScope } from '../../sync/scopeName';
import { bySortKey, compareKeys } from '../../serverops/values';
import { requireStr, ToolValidationError, type ToolContext, type ToolDef } from '../registry';
import { openSession, parseColor } from './projects';

function ownTags(snapshot: Snapshot, userId: string): SnapshotRow[] {
  return snapshot.rows('tag').filter((t) => t.scope === userScope(userId));
}

function formatTag(snapshot: Snapshot, row: Record<string, unknown>) {
  const name = String(row.name);
  const active = snapshot.liveTasks().filter((t) => Number(t.row.status ?? 0) === 0 && Array.isArray(t.row.tags) && (t.row.tags as unknown[]).includes(name));
  return {
    name,
    label: String(row.label ?? name),
    color: row.color === undefined ? null : (row.color as string | null),
    active_count: active.length,
  };
}

const isLive = (t: SnapshotRow) => t.row.deletedAt == null && t.row.purgedAt == null;

export function tagTools(): ToolDef[] {
  return [
    {
      name: 'list_tags',
      description: 'List your tags (name is the lowercased key, label keeps the original casing).',
      inputSchema: { type: 'object', properties: {} },
      run: async (_args, ctx: ToolContext) => {
        const { snapshot } = await openSession(ctx);
        return ownTags(snapshot, ctx.userId).filter(isLive).sort(bySortKey).map((t) => formatTag(snapshot, t.row));
      },
    },
    {
      name: 'create_tag',
      description:
        'Create a tag. Provide a display name (stored lowercased as the tag key; leading and trailing # are dropped). Optionally set a hex color (#RRGGBB or #RGB). Returns the existing tag when it already exists.',
      inputSchema: {
        type: 'object',
        required: ['name'],
        properties: {
          name: { type: 'string', description: 'Tag display name; stored lowercased as the tag key.' },
          color: { type: 'string', description: 'Optional hex color, #RRGGBB or #RGB.' },
        },
      },
      run: async (args, ctx: ToolContext) => {
        const raw = requireStr(args, 'name');
        const color = parseColor(args.color);
        const [tag] = normalizeTagLabels([raw]);
        if (!tag) throw new ToolValidationError('name', "Argument 'name' must contain more than '#'");
        const { snapshot, deps } = await openSession(ctx);
        const own = ownTags(snapshot, ctx.userId);
        const existing = own.find((t) => t.row.name === tag.name);
        if (existing && isLive(existing)) return formatTag(snapshot, existing.row);
        const now = Date.now();
        // A trashed tag is revived; its key (the name) cannot be reused for a new row.
        const set: Record<string, unknown> = existing
          ? { label: tag.label, deletedAt: null, ...(color !== undefined && { color }) }
          : {
              name: tag.name,
              label: tag.label,
              sortKey: after(own.length === 0 ? null : own.map((t) => String(t.row.sortKey ?? '')).reduce((a, b) => (compareKeys(a, b) >= 0 ? a : b))),
              ...(color !== undefined && { color }),
            };
        const [out] = await writeOrThrow(deps, snapshot, [{ entity: 'tag', entityId: tag.name, set }], { nowMs: now });
        return formatTag(snapshot, out!.row!);
      },
    },
  ];
}
