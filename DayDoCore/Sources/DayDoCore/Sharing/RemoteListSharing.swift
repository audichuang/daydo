import Foundation
import GRDB

/// Synced/remote implementation of `ListSharing` backed by `SyncEngine`'s
/// authorized HTTP request and token-refresh path.
public struct RemoteListSharing: ListSharing, Sendable {
    private let syncEngine: SyncEngine

    public init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }

    public func createInvite(projectId: String, role: String, email: String?) async throws -> CreatedInvite {
        let body = try Outbox.encoder.encode(CreateInviteRequest(projectId: projectId, role: role, email: email))
        let data = try await sendAuthorizedSharing(method: "POST", path: "/invites", body: body)
        return try decode(CreatedInvite.self, from: data)
    }

    public func revokeInvite(code: String) async throws {
        let encoded = Self.percentEncodePathComponent(code)
        _ = try await sendAuthorizedSharing(method: "DELETE", path: "/invites/\(encoded)", body: nil)
    }

    public func inviteInfo(code: String) async throws -> InviteInfo {
        let encoded = Self.percentEncodePathComponent(code)
        let data = try await sendAuthorizedSharing(method: "GET", path: "/invites/\(encoded)", body: nil)
        return try decode(InviteInfo.self, from: data)
    }

    @discardableResult
    public func acceptInvite(code: String) async throws -> AcceptedInvite {
        let encoded = Self.percentEncodePathComponent(code)
        let data = try await sendAuthorizedSharing(method: "POST", path: "/invites/\(encoded)/accept", body: nil)
        let accepted = try decode(AcceptedInvite.self, from: data)
        try await syncEngine.database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO projectMembership (projectId, scope, role, needsBackfill)
                    VALUES (?, ?, ?, 1)
                    ON CONFLICT(projectId) DO UPDATE SET
                        scope = excluded.scope,
                        role = excluded.role,
                        needsBackfill = 1
                    """,
                arguments: [accepted.projectId, accepted.scope, accepted.role]
            )
        }
        _ = try await syncEngine.syncNow()
        return accepted
    }

    public func changeMemberRole(projectId: String, member: ProjectMemberInfo, role: String) async throws {
        let userId = try requireUserId(for: member)
        let body = try Outbox.encoder.encode(ChangeMemberRoleRequest(role: role))
        let encodedProject = Self.percentEncodePathComponent(projectId)
        let encodedUser = Self.percentEncodePathComponent(userId)
        _ = try await sendAuthorizedSharing(
            method: "PUT",
            path: "/projects/\(encodedProject)/members/\(encodedUser)",
            body: body
        )
    }

    public func removeMember(projectId: String, member: ProjectMemberInfo) async throws {
        let userId = try requireUserId(for: member)
        try await removeMember(projectId: projectId, userId: userId)
    }

    public func leaveList(projectId: String) async throws {
        guard let myUserId = try await syncEngine.signedInUserId, !myUserId.isEmpty else {
            throw SyncError.signedOut
        }
        try await removeMember(projectId: projectId, userId: myUserId)
    }

    private func removeMember(projectId: String, userId: String) async throws {
        let encodedProject = Self.percentEncodePathComponent(projectId)
        let encodedUser = Self.percentEncodePathComponent(userId)
        _ = try await sendAuthorizedSharing(
            method: "DELETE",
            path: "/projects/\(encodedProject)/members/\(encodedUser)",
            body: nil
        )
    }

    private func requireUserId(for member: ProjectMemberInfo) throws -> String {
        guard let userId = member.userId, !userId.isEmpty else {
            throw DayDoError.invalid("無法取得此成員的帳號識別碼")
        }
        return userId
    }

    private func sendAuthorizedSharing(method: String, path: String, body: Data?) async throws -> Data {
        let response = try await syncEngine.sendAuthorizedResponse(method: method, path: path, body: body)
        return try await validateSharingResponse(response)
    }

    private struct SharingErrorBody: Decodable {
        let error: String?
    }

    private func validateSharingResponse(_ response: SyncHTTPResponse) async throws -> Data {
        if (200...299).contains(response.status) {
            return response.body
        }
        let decoder = JSONDecoder()
        let message: String = {
            if let parsed = try? decoder.decode(SharingErrorBody.self, from: response.body),
               let err = parsed.error, !err.isEmpty {
                return err
            }
            let raw = String(data: response.body, encoding: .utf8) ?? ""
            return raw.isEmpty ? "HTTP \(response.status)" : raw
        }()
        switch response.status {
        case 400:
            throw SharingError.badRequest(message)
        case 403:
            throw SharingError.forbidden(message)
        case 404:
            throw SharingError.notFound(message)
        case 409:
            throw SharingError.conflict(message)
        case 429, 500...599:
            throw await syncEngine.recordRetryableFailure(statusCode: response.status, message: message)
        default:
            throw SyncError.protocolError("HTTP \(response.status): \(message)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SyncError.protocolError("Failed to decode \(T.self): \(error.localizedDescription)")
        }
    }

    private static func percentEncodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
