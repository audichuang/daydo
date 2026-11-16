import { serializePublicRow, type EntityName } from '../sync/entities';

/** Who reads a row out of a scope: its owner sees `isMe` and the private `folderId`, others do not. */
export interface ScopeViewer {
  isScopeOwner: boolean;
  /** The owner's bound member id; only meaningful when `isScopeOwner`. */
  meMemberId: string | null;
}

/** The app-facing JSON of a scope row as seen by `viewer`. */
export function rowView(
  entity: EntityName,
  row: Record<string, unknown>,
  purgedAt: number | null,
  viewer: ScopeViewer,
): Record<string, unknown> {
  return serializePublicRow(entity, row, purgedAt, {
    meMemberId: viewer.isScopeOwner ? viewer.meMemberId : null,
    omitFolderId: !viewer.isScopeOwner,
  });
}
