import Foundation
import GRDB
import Testing
@testable import DayDoCore

private struct RecordedSharingRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

private actor RecordingSharingTransport: SyncTransport {
    typealias Handler = @Sendable (RecordedSharingRequest) async throws -> SyncHTTPResponse

    private var requests: [RecordedSharingRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> SyncHTTPResponse {
        let req = RecordedSharingRequest(method: method, path: path, headers: headers, body: body)
        requests.append(req)
        return try await handler(req)
    }

    func captured() -> [RecordedSharingRequest] {
        requests
    }
}

private func sharingJSONResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SyncHTTPResponse(status: status, body: data)
}

enum SharingAdapterKind: String, CaseIterable, Sendable {
    case local
    case remote
}

private struct SharingHarness {
    let kind: SharingAdapterKind
    let sharing: any ListSharing
    let api: LocalDayDoAPI
    let db: AppDatabase
    let transport: RecordingSharingTransport
    let projectId: String
    let otherMember: ProjectMemberInfo
    let myUserId: String
    let otherUserId: String

    static func make(_ kind: SharingAdapterKind) async throws -> SharingHarness {
        let nowMs = noon.epochMillis
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sharing-\(UUID().uuidString)")
        let clock = Clock.fixed(noon, timeZone: taipei)
        let api = LocalDayDoAPI(database: db, clock: clock, attachmentsDirectory: dir)
        try await api.bootstrap()

        let list = try await api.createProject(CreateProjectInput(name: "家庭採買"))
        let otherMemberId = "m-other"
        let myUserId = "user-self"
        let otherUserId = "user-other"

        try await db.writer.write { db in
            try MemberRecord(
                id: otherMemberId,
                name: "小安",
                initial: "小",
                color: "#4AA8E8",
                isMe: false,
                createdAt: nowMs,
                updatedAt: nowMs,
                deletedAt: nil
            ).insert(db)
            try ProjectMemberRecord(
                projectId: list.id,
                memberId: otherMemberId,
                role: "editor",
                createdAt: nowMs,
                updatedAt: nowMs,
                deletedAt: nil
            ).insert(db)
            try db.execute(
                sql: "INSERT INTO memberUser (memberId, userId, avatarUrl) VALUES (?, ?, NULL)",
                arguments: [otherMemberId, otherUserId]
            )
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                arguments: [SyncEngine.signedInUserIdMetaKey, myUserId]
            )
        }

        let members = try await api.listProjectMembers(projectId: list.id)
        let other = try #require(members.first { $0.memberId == otherMemberId })

        let transport = RecordingSharingTransport { req in
            if req.method == "POST" && req.path == "/invites" {
                return try sharingJSONResponse(200, [
                    "code": "srv-code-1",
                    "url": "daydo://invite/srv-code-1",
                    "expiresAt": nowMs + 7 * 86_400_000,
                ])
            }
            if req.method == "GET" && req.path == "/invites/srv-code-1" {
                return try sharingJSONResponse(200, [
                    "projectName": "家庭採買",
                    "inviterName": "我",
                    "role": "editor",
                    "expiresAt": nowMs + 7 * 86_400_000,
                ])
            }
            if req.method == "DELETE" && req.path == "/invites/srv-code-1" {
                return SyncHTTPResponse(status: 204, body: Data())
            }
            if req.method == "PUT" && req.path == "/projects/\(list.id)/members/\(otherUserId)" {
                return SyncHTTPResponse(status: 200, body: Data())
            }
            if req.method == "DELETE" && req.path == "/projects/\(list.id)/members/\(otherUserId)" {
                return SyncHTTPResponse(status: 200, body: Data())
            }
            if req.method == "DELETE" && req.path == "/projects/\(list.id)/members/\(myUserId)" {
                return SyncHTTPResponse(status: 200, body: Data())
            }
            return try sharingJSONResponse(404, ["error": "Unexpected \(req.method) \(req.path)"])
        }

        let tokens = InMemorySyncTokenStore(accessToken: "access-token", refreshToken: "refresh-token")
        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: clock)
        let sharing: any ListSharing = switch kind {
        case .local:
            LocalListSharing(api: api, clock: clock)
        case .remote:
            RemoteListSharing(syncEngine: engine)
        }

        return SharingHarness(
            kind: kind,
            sharing: sharing,
            api: api,
            db: db,
            transport: transport,
            projectId: list.id,
            otherMember: other,
            myUserId: myUserId,
            otherUserId: otherUserId
        )
    }
}

@Suite struct ListSharingTests {
    @Test(arguments: SharingAdapterKind.allCases)
    func createInspectAndRevokeInvite(kind: SharingAdapterKind) async throws {
        let h = try await SharingHarness.make(kind)

        let created = try await h.sharing.createInvite(projectId: h.projectId, role: "editor")
        #expect(!created.code.isEmpty)
        #expect(created.url == "daydo://invite/\(created.code)")
        #expect(created.expiresAt > noon.epochMillis)

        let info = try await h.sharing.inviteInfo(code: created.code)
        #expect(!info.projectName.isEmpty)
        #expect(!info.inviterName.isEmpty)
        #expect(info.role == "editor" || info.role == "viewer")

        try await h.sharing.revokeInvite(code: created.code)

        let requests = await h.transport.captured()
        switch kind {
        case .local:
            #expect(created.code == "preview")
            #expect(created.url == "daydo://invite/preview")
            #expect(requests.isEmpty)
        case .remote:
            #expect(requests.map { "\($0.method) \($0.path)" } == [
                "POST /invites",
                "GET /invites/srv-code-1",
                "DELETE /invites/srv-code-1",
            ])
        }
    }

    @Test(arguments: SharingAdapterKind.allCases)
    func changeRoleAndRemoveMember(kind: SharingAdapterKind) async throws {
        let h = try await SharingHarness.make(kind)
        let changesBefore = try await h.api.pendingChanges().count

        try await h.sharing.changeMemberRole(projectId: h.projectId, member: h.otherMember, role: "viewer")
        try await h.sharing.removeMember(projectId: h.projectId, member: h.otherMember)

        let requests = await h.transport.captured()
        switch kind {
        case .local:
            #expect(requests.isEmpty)

            let activeMembers = try await h.api.listProjectMembers(projectId: h.projectId)
            #expect(!activeMembers.contains { $0.memberId == h.otherMember.memberId })

            let row = try await h.db.writer.read { db in
                try ProjectMemberRecord
                    .filter(Column("projectId") == h.projectId && Column("memberId") == h.otherMember.memberId)
                    .fetchOne(db)
            }
            let saved = try #require(row)
            #expect(saved.role == "viewer")
            #expect(saved.deletedAt != nil)

            let newChanges = Array(try await h.api.pendingChanges().dropFirst(changesBefore))
            let expectedEntityId = "\(h.projectId):\(h.otherMember.memberId)"
            #expect(newChanges.contains { $0.entity == "projectMember" && $0.entityId == expectedEntityId && $0.fields.contains("role") })
            #expect(newChanges.contains { $0.entity == "projectMember" && $0.entityId == expectedEntityId && $0.fields.contains("deletedAt") })

        case .remote:
            #expect(requests.count == 2)
            #expect(requests[0].method == "PUT")
            #expect(requests[0].path == "/projects/\(h.projectId)/members/\(h.otherUserId)")
            #expect(requests[0].headers["Authorization"] == "Bearer access-token")
            let rolePayload = try JSONSerialization.jsonObject(with: try #require(requests[0].body)) as? [String: String]
            #expect(rolePayload == ["role": "viewer"])

            #expect(requests[1].method == "DELETE")
            #expect(requests[1].path == "/projects/\(h.projectId)/members/\(h.otherUserId)")
            #expect(requests[1].headers["Authorization"] == "Bearer access-token")
        }
    }

    @Test(arguments: SharingAdapterKind.allCases)
    func leaveList(kind: SharingAdapterKind) async throws {
        let h = try await SharingHarness.make(kind)

        try await h.sharing.leaveList(projectId: h.projectId)

        let requests = await h.transport.captured()
        switch kind {
        case .local:
            #expect(requests.isEmpty)
        case .remote:
            #expect(requests.count == 1)
            #expect(requests[0].method == "DELETE")
            #expect(requests[0].path == "/projects/\(h.projectId)/members/\(h.myUserId)")
            #expect(requests[0].headers["Authorization"] == "Bearer access-token")
        }
    }

    @Test func localMissingUserIdUsesMemberIdAndAcceptThrowsOfflineError() async throws {
        let h = try await SharingHarness.make(.local)
        let memberWithoutUserId = ProjectMemberInfo(
            memberId: h.otherMember.memberId,
            name: h.otherMember.name,
            initial: h.otherMember.initial,
            color: h.otherMember.color,
            isMe: false,
            role: h.otherMember.role,
            userId: nil
        )

        try await h.sharing.changeMemberRole(projectId: h.projectId, member: memberWithoutUserId, role: "viewer")
        let updated = try await h.api.listProjectMembers(projectId: h.projectId)
        #expect(updated.first { $0.memberId == memberWithoutUserId.memberId }?.role == "viewer")

        try await h.sharing.removeMember(projectId: h.projectId, member: memberWithoutUserId)
        let afterRemove = try await h.api.listProjectMembers(projectId: h.projectId)
        #expect(!afterRemove.contains { $0.memberId == memberWithoutUserId.memberId })

        await #expect(throws: DayDoError.invalid("無法在離線模式加入共享清單")) {
            _ = try await h.sharing.acceptInvite(code: "preview")
        }
    }

    @Test func remoteMissingOrEmptyUserIdThrowsIdenticalErrorWithoutRequests() async throws {
        let h = try await SharingHarness.make(.remote)
        let expectedError = DayDoError.invalid("無法取得此成員的帳號識別碼")

        for badUserId in [String?.none, .some("")] {
            let member = ProjectMemberInfo(
                memberId: h.otherMember.memberId,
                name: h.otherMember.name,
                initial: h.otherMember.initial,
                color: h.otherMember.color,
                isMe: false,
                role: h.otherMember.role,
                userId: badUserId
            )
            await #expect(throws: expectedError) {
                try await h.sharing.changeMemberRole(projectId: h.projectId, member: member, role: "viewer")
            }
            await #expect(throws: expectedError) {
                try await h.sharing.removeMember(projectId: h.projectId, member: member)
            }
        }

        let requests = await h.transport.captured()
        #expect(requests.isEmpty)
    }

    @Test func remoteLeaveListThrowsSignedOutWhenNoSignedInUserId() async throws {
        let db = try AppDatabase.inMemory()
        let transport = RecordingSharingTransport { _ in
            SyncHTTPResponse(status: 200, body: Data())
        }
        let tokens = InMemorySyncTokenStore(accessToken: "access-1", refreshToken: "refresh-1")
        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens)
        let sharing = RemoteListSharing(syncEngine: engine)

        await #expect(throws: SyncError.signedOut) {
            try await sharing.leaveList(projectId: "proj-1")
        }
        #expect(await transport.captured().isEmpty)
    }
}
