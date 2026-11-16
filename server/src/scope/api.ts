import type { EntityName, MembershipRole } from '../sync/entities';
import type { OpEnvelope } from '../sync/envelope';

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
  /** Ops in push order, each validated once by the caller (invalid ones too: they reject here). */
  ops: OpEnvelope[];
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

export interface ScopeStub {
  push(input: ScopePushInput): Promise<ScopePushResponse>;
  pull(input: ScopePullInput): Promise<ScopePullResponse>;
  getInboxProjectId(input: { readableProjectIds: string[] }): Promise<string | null>;
  getProjectInfo(input: { projectId: string }): Promise<ScopeProjectInfo | null>;
  projectMember(input: ScopeProjectMemberInput): Promise<void>;
  purgeProject(input: ScopePurgeProjectInput): Promise<ScopePurgeProjectResponse>;
}
