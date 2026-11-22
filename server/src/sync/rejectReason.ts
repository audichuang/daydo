import type { PushOpResult } from '../scope/api';

/** Fixed wire strings used for push rejections across D1 planning, Scope DO, and server callers. */
export const REJECT_REASON = {
  ID_IN_OTHER_SCOPE: 'id-in-other-scope',
  UNKNOWN_ROW: 'unknown-row',
  PROJECT_PURGED: 'Project is purged',
  FORBIDDEN: 'Forbidden',
  MALFORMED_OP: 'Malformed op',
  CHILD_TASK_ID_IMMUTABLE: 'Child taskId cannot be changed',
  PROJECT_DELETE_VIA_D1: 'Project deletion must be purged via D1',
} as const;

export type RejectReason = (typeof REJECT_REASON)[keyof typeof REJECT_REASON];

export type RejectedPushOpResult = PushOpResult & { status: 'rejected' };

export function rejectedResult(
  opId: string,
  reason: string,
  row: Record<string, unknown> | null = null,
  clocks: Record<string, string> = {},
  gone?: boolean,
): RejectedPushOpResult {
  return {
    opId,
    status: 'rejected',
    reason,
    row,
    clocks,
    ...(gone ? { gone: true } : {}),
  };
}
