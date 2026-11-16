import Foundation

/// Offline/local implementation of `ListSharing`.
///
/// Member role updates and removals persist via `DayDoAPI` (writing
/// `projectMember` rows and outbox entries), while invite links use the local
/// preview stub and leave the local `"等待同步"` `DayDoAPI` invite APIs intact.
public struct LocalListSharing: ListSharing, Sendable {
    private static let inviteLifetimeMillis: EpochMillis = 7 * 86_400_000

    private let api: any DayDoAPI
    private let clock: Clock

    public init(api: any DayDoAPI, clock: Clock = .system) {
        self.api = api
        self.clock = clock
    }

    public func createInvite(projectId: String, role: String, email: String?) async throws -> CreatedInvite {
        CreatedInvite(
            code: "preview",
            url: "daydo://invite/preview",
            expiresAt: clock.now().epochMillis + Self.inviteLifetimeMillis
        )
    }

    public func revokeInvite(code: String) async throws {
        // Preview invite links have no server state to revoke in offline mode.
    }

    public func inviteInfo(code: String) async throws -> InviteInfo {
        InviteInfo(
            projectName: "家庭採買",
            inviterName: "小安",
            role: "editor",
            expiresAt: clock.now().epochMillis + Self.inviteLifetimeMillis
        )
    }

    @discardableResult
    public func acceptInvite(code: String) async throws -> AcceptedInvite {
        throw DayDoError.invalid("無法在離線模式加入共享清單")
    }

    public func changeMemberRole(projectId: String, member: ProjectMemberInfo, role: String) async throws {
        try await api.updateMemberRole(projectId: projectId, memberId: member.memberId, role: role)
    }

    public func removeMember(projectId: String, member: ProjectMemberInfo) async throws {
        try await api.removeMember(projectId: projectId, memberId: member.memberId)
    }

    public func leaveList(projectId: String) async throws {
        // Offline mode has no remote membership to leave.
    }
}
