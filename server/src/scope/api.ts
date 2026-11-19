import type { EntityName, MembershipRole } from '../sync/entities';
import type { SyncOpValidation } from '../sync/envelope';

export interface PushOpResult {
  opId: string;
  status: 'applied' | 'rejected';
  reason?: string;
  row: Record<string, unknown> | null;
  clocks: Record<string, string>;
  gone?: boolean;
}

export interface ScopePushInput {
  scope: string;
  scopeUserId: string;
  pusherUserId: string;
  deviceId: string;
  memberships: Record<string, MembershipRole>;
  purgedProjects: string[];
  meMemberId: string | null;
  /**
   * Raw ops in push order, exactly as the client sent them (invalid ones too: they reject here).
   * This RPC must stay forward and backward compatible: during a deploy old and new Workers and
   * DOs run side by side, and an older DO reads and validates `ops` itself.
   */
  ops: unknown[];
  /**
   * The Worker's validation of each op, parallel to `ops`. Optional so an older Worker (which does
   * not send it) still works: the DO validates `ops` itself when it is absent or misaligned.
   */
  validated?: SyncOpValidation[];
}

export interface ScopePushResponse {
  results: PushOpResult[];
  serverSeq: number;
  boundMeMemberId: string | null;
  /** Server HLC string (`<13-digit ms>:<4-digit counter>:server`). */
  serverTime: string;
}

export interface ExpectedProjectMember {
  memberId: string;
  role: MembershipRole;
}

export interface ScopeProjectMemberInput {
  projectId: string;
  memberId: string;
  role: MembershipRole;
  deleted: boolean;
  nowMs?: number;
}

export interface ScopePurgeProjectInput {
  projectId: string;
  purgedAt: number;
  opId?: string;
  pusherUserId?: string;
}

export interface ScopePurgeProjectResponse {
  projectId: string;
  purgedRow: Record<string, unknown> | null;
  clocks: Record<string, string>;
  serverTime: string;
}

export interface ScopeProjectInfo {
  name: string;
  purgedAt: number | null;
}

export interface ScopeAttachmentInfo {
  id: string;
  taskId: string;
  projectId: string;
  size: number;
  mimeType: string;
  deletedAt: number | null;
  purgedAt: number | null;
  taskPurgedAt: number | null;
}

export interface ScopePullInput {
  scope: string;
  scopeUserId: string;
  requesterUserId: string;
  since: number;
  limit: number;
  memberships: Record<string, MembershipRole>;
  backfillProjectIds?: string[];
  meMemberId: string | null;
  expectedProjectMembers?: Record<string, ExpectedProjectMember[]>;
}

export type PullScopeRow =
  | {
      entity: EntityName;
      row: Record<string, unknown>;
      clocks: Record<string, string>;
      serverSeq: number;
    }
  | {
      entity: EntityName;
      entityId: string;
      gone: true;
      serverSeq: number;
    };

export interface ScopePullResponse {
  scope: string;
  rows: PullScopeRow[];
  cursor: number;
  hasMore: boolean;
}

export type ScopeRelocationState = 'live' | 'frozen' | 'importing';

export interface ScopeRelocationStatus {
  state: ScopeRelocationState;
  tables: Record<string, number>;
  maxServerSeq: number;
  counter: Array<{ id: number; value: number }>;
}

export interface ScopeSetRelocationStateInput {
  state: ScopeRelocationState;
  expect: ScopeRelocationState;
  /** Required for importing -> live: target recomputes its digest inside the state transition transaction and refuses on mismatch. */
  expectDigest?: Record<string, ScopeTableDigest>;
}

export interface ScopeSetRelocationStateResponse {
  previous: ScopeRelocationState;
  state: ScopeRelocationState;
}

export interface ScopeExportedRow {
  rowid: number;
  values: Record<string, string | number | null>;
}

export interface ScopeExportPageInput {
  table: string;
  afterRowid?: number;
  maxChars?: number;
}

export interface ScopeExportPageResponse {
  table: string;
  rows: ScopeExportedRow[];
  nextAfterRowid: number;
  done: boolean;
}

export interface ScopeImportPageInput {
  table: string;
  rows: ScopeExportedRow[];
}

export interface ScopeImportPageResponse {
  table: string;
  imported: number;
}

export interface ScopeTableDigest {
  count: number;
  sha256: string;
}

export interface ScopeDigest {
  state: ScopeRelocationState;
  tables: Record<string, ScopeTableDigest>;
}

export interface ScopeStub {
  push(input: ScopePushInput): Promise<ScopePushResponse>;
  pull(input: ScopePullInput): Promise<ScopePullResponse>;
  getInboxProjectId(input: { readableProjectIds: string[] }): Promise<string | null>;
  getProjectInfo(input: { projectId: string }): Promise<ScopeProjectInfo | null>;
  getAttachmentInfo(input: { attachmentId: string }): Promise<ScopeAttachmentInfo | null>;
  projectMember(input: ScopeProjectMemberInput): Promise<void>;
  purgeProject(input: ScopePurgeProjectInput): Promise<ScopePurgeProjectResponse>;
}

export interface ScopeRelocationStub {
  relocationStatus(): Promise<ScopeRelocationStatus>;
  setRelocationState(input: ScopeSetRelocationStateInput): Promise<ScopeSetRelocationStateResponse>;
  exportPage(input: ScopeExportPageInput): Promise<ScopeExportPageResponse>;
  importPage(input: ScopeImportPageInput): Promise<ScopeImportPageResponse>;
  digest(): Promise<ScopeDigest>;
}
