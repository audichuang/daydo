import Foundation

/// Domain-level list sharing operations (invite links, member roles/removal,
/// leaving a shared list). App screens call this contract without branching on
/// sync mode; `LocalListSharing` and `RemoteListSharing` provide the offline
/// and synced implementations.
public protocol ListSharing: Sendable {
    func createInvite(projectId: String, role: String, email: String?) async throws -> CreatedInvite
    func revokeInvite(code: String) async throws
    func inviteInfo(code: String) async throws -> InviteInfo
    @discardableResult
    func acceptInvite(code: String) async throws -> AcceptedInvite
    func changeMemberRole(projectId: String, member: ProjectMemberInfo, role: String) async throws
    func removeMember(projectId: String, member: ProjectMemberInfo) async throws
    func leaveList(projectId: String) async throws
}

public extension ListSharing {
    func createInvite(projectId: String, role: String) async throws -> CreatedInvite {
        try await createInvite(projectId: projectId, role: role, email: nil)
    }
}
