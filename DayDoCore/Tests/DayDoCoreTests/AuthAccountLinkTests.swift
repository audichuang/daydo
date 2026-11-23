import Foundation
import Testing
@testable import DayDoCore

private actor RecordingAuthTransport: SyncTransport {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let bodyJSON: [String: SyncJSONValue]?
    }

    var requests: [RecordedRequest] = []
    private let handler: @Sendable (RecordedRequest) async throws -> SyncHTTPResponse

    init(handler: @escaping @Sendable (RecordedRequest) async throws -> SyncHTTPResponse) {
        self.handler = handler
    }

    func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> SyncHTTPResponse {
        let bodyJSON = body.flatMap { try? JSONDecoder().decode([String: SyncJSONValue].self, from: $0) }
        let req = RecordedRequest(method: method, path: path, headers: headers, bodyJSON: bodyJSON)
        requests.append(req)
        return try await handler(req)
    }

    func allRequests() -> [RecordedRequest] {
        requests
    }
}

private func jsonHTTP(_ status: Int, _ object: Any) -> SyncHTTPResponse {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return SyncHTTPResponse(status: status, body: data)
}

@Suite struct AuthAccountLinkTests {
    private func makeEngine(
        tokenStore: InMemorySyncTokenStore = InMemorySyncTokenStore(accessToken: "acc-1", refreshToken: "ref-1"),
        handler: @escaping @Sendable (RecordingAuthTransport.RecordedRequest) async throws -> SyncHTTPResponse
    ) throws -> (SyncEngine, RecordingAuthTransport, InMemorySyncTokenStore) {
        let db = try AppDatabase.inMemory()
        let transport = RecordingAuthTransport(handler: handler)
        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokenStore)
        return (engine, transport, tokenStore)
    }

    @Test func startEmailSignInAndEmailVerifySignIn() async throws {
        let (engine, transport, tokens) = try makeEngine(
            tokenStore: InMemorySyncTokenStore()
        ) { req in
            switch (req.method, req.path) {
            case ("POST", "/auth/email/start"):
                if req.bodyJSON?["email"]?.stringValue == "bad" {
                    return jsonHTTP(400, ["error": "A valid email and deviceId are required"])
                }
                return jsonHTTP(202, ["sent": true])
            case ("POST", "/auth/email/verify"):
                if req.bodyJSON?["code"]?.stringValue != "123456" {
                    return jsonHTTP(401, ["error": "Invalid or expired code"])
                }
                return jsonHTTP(200, [
                    "accessToken": "email-acc",
                    "refreshToken": "email-ref",
                    "user": ["id": "u-email-1"],
                    "isNewAccount": true,
                    "hasData": false,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                    "avatarUrl": NSNull(),
                ])
            case ("POST", "/sync/push"):
                var results: [[String: Any]] = []
                if case let .array(ops) = req.bodyJSON?["ops"] {
                    for op in ops {
                        if case let .object(dict) = op, let opId = dict["opId"]?.stringValue {
                            results.append(["opId": opId, "status": "applied"])
                        }
                    }
                }
                return jsonHTTP(200, ["results": results, "serverTime": "0000000001000:0000:srv"])
            case ("POST", "/sync/pull"):
                return jsonHTTP(200, ["scopes": [], "members": []])
            default:
                return jsonHTTP(404, ["error": "Not found"])
            }
        }

        await #expect(throws: AuthError.badRequest("A valid email and deviceId are required")) {
            try await engine.startEmailSignIn(email: "bad")
        }

        try await engine.startEmailSignIn(email: "family@example.com")

        await #expect(throws: AuthError.invalidCode) {
            try await engine.signIn(with: .email(email: "family@example.com", code: "000000"))
        }

        _ = try await engine.signIn(with: .email(email: "family@example.com", code: "123456"))
        #expect(try await engine.signedInUserId == "u-email-1")
        #expect(tokens.accessToken == "email-acc")
        #expect(tokens.refreshToken == "email-ref")

        let reqs = await transport.allRequests()
        let startReq = try #require(reqs.first { $0.path == "/auth/email/start" && $0.bodyJSON?["email"]?.stringValue == "family@example.com" })
        #expect(startReq.bodyJSON?["deviceId"]?.stringValue?.isEmpty == false)
    }

    @Test func listIdentitiesAndLinkIdentitySuccessAndConflict() async throws {
        let (engine, transport, _) = try makeEngine { req in
            switch (req.method, req.path) {
            case ("GET", "/me/identities"):
                return jsonHTTP(200, [
                    ["provider": "apple", "email": "relay@privaterelay.appleid.com", "createdAt": 1000],
                ])
            case ("POST", "/auth/link"):
                let provider = req.bodyJSON?["provider"]?.stringValue
                if provider == "google", req.bodyJSON?["idToken"]?.stringValue == "taken-token" {
                    return jsonHTTP(409, ["error": "identity_in_use"])
                }
                return jsonHTTP(200, [
                    ["provider": "apple", "email": "relay@privaterelay.appleid.com", "createdAt": 1000],
                    ["provider": provider ?? "google", "email": "linked@example.com", "createdAt": 2000],
                ])
            default:
                return jsonHTTP(404, ["error": "Not found"])
            }
        }

        let initial = try await engine.listIdentities()
        #expect(initial == [
            LinkedIdentity(provider: .apple, email: "relay@privaterelay.appleid.com", createdAt: 1000),
        ])

        await #expect(throws: AuthError.identityInUse) {
            try await engine.linkIdentity(with: .google(idToken: "taken-token"))
        }
        #expect(AuthError.identityInUse.errorDescription == "這個登入方式已經屬於另一個 DayDo 帳號")

        let afterGoogle = try await engine.linkIdentity(with: .google(idToken: "good-google"))
        #expect(afterGoogle.map(\.provider) == [.apple, .google])

        let afterEmail = try await engine.linkIdentity(with: .email(email: "linked@example.com", code: "654321"))
        #expect(afterEmail.map(\.provider) == [.apple, .email])

        let afterApple = try await engine.linkIdentity(with: .apple(identityToken: "id-tok", nonce: "raw-nonce"))
        #expect(afterApple.count == 2)

        let linkReqs = await transport.allRequests().filter { $0.path == "/auth/link" }
        #expect(linkReqs.count == 4)
        #expect(linkReqs[1].bodyJSON?["provider"]?.stringValue == "google")
        #expect(linkReqs[1].bodyJSON?["idToken"]?.stringValue == "good-google")
        #expect(linkReqs[2].bodyJSON?["provider"]?.stringValue == "email")
        #expect(linkReqs[2].bodyJSON?["email"]?.stringValue == "linked@example.com")
        #expect(linkReqs[2].bodyJSON?["code"]?.stringValue == "654321")
        #expect(linkReqs[3].bodyJSON?["provider"]?.stringValue == "apple")
        #expect(linkReqs[3].bodyJSON?["identityToken"]?.stringValue == "id-tok")
        #expect(linkReqs[3].bodyJSON?["nonce"]?.stringValue == "raw-nonce")
    }

    @Test func linkInvalidEmailCode401DoesNotRefreshOrSignOut() async throws {
        let (engine, transport, tokens) = try makeEngine { req in
            switch (req.method, req.path) {
            case ("POST", "/auth/link"):
                return jsonHTTP(401, ["error": "Invalid or expired code"])
            default:
                return jsonHTTP(500, ["error": "unexpected \(req.path)"])
            }
        }

        await #expect(throws: AuthError.invalidCode) {
            try await engine.linkIdentity(with: .email(email: "a@example.com", code: "000000"))
        }

        // Must NOT have called /auth/refresh, must NOT have retried /auth/link, and must keep tokens!
        let reqs = await transport.allRequests()
        #expect(reqs.map(\.path) == ["/auth/link"])
        #expect(tokens.accessToken == "acc-1")
        #expect(tokens.refreshToken == "ref-1")
    }

    @Test func linkExpiredAccessToken401RefreshesAndRetries() async throws {
        let (engine, transport, tokens) = try makeEngine { req in
            switch (req.method, req.path) {
            case ("POST", "/auth/link"):
                if req.headers["Authorization"] == "Bearer acc-1" {
                    return jsonHTTP(401, ["error": "Unauthorized"])
                }
                return jsonHTTP(200, [
                    ["provider": "apple", "createdAt": 1000],
                    ["provider": "email", "email": "a@example.com", "createdAt": 2000],
                ])
            case ("POST", "/auth/refresh"):
                return jsonHTTP(200, [
                    "accessToken": "acc-2",
                    "refreshToken": "ref-2",
                ])
            default:
                return jsonHTTP(404, ["error": "Not found"])
            }
        }

        let linked = try await engine.linkIdentity(with: .email(email: "a@example.com", code: "123456"))
        #expect(linked.map(\.provider) == [.apple, .email])
        #expect(tokens.accessToken == "acc-2")
        #expect(tokens.refreshToken == "ref-2")
        #expect(await transport.allRequests().map(\.path) == ["/auth/link", "/auth/refresh", "/auth/link"])
    }

    @Test func emailAccountSwitchSendsVerifyOnceAndCancelPreservesLocalData() async throws {
        let db = try AppDatabase.inMemory()
        let api = LocalDayDoAPI(database: db, attachmentsDirectory: FileManager.default.temporaryDirectory)
        let tokens = InMemorySyncTokenStore()

        actor SingleUseEmailServer {
            var verifyCalls = 0
            func handle(_ req: RecordingAuthTransport.RecordedRequest) -> SyncHTTPResponse {
                switch (req.method, req.path) {
                case ("POST", "/auth/apple"):
                    return jsonHTTP(200, [
                        "accessToken": "acc-a",
                        "refreshToken": "ref-a",
                        "user": ["id": "user-a"],
                        "isNewAccount": true,
                        "hasData": false,
                        "meMemberId": NSNull(),
                        "inboxProjectId": NSNull(),
                        "avatarUrl": NSNull(),
                    ])
                case ("POST", "/auth/email/verify"):
                    verifyCalls += 1
                    // Server consumes the one-time 6-digit code on the first verify call.
                    guard verifyCalls == 1 else {
                        return jsonHTTP(401, ["error": "Invalid or expired code"])
                    }
                    return jsonHTTP(200, [
                        "accessToken": "acc-b",
                        "refreshToken": "ref-b",
                        "user": ["id": "user-b"],
                        "isNewAccount": true,
                        "hasData": false,
                        "meMemberId": NSNull(),
                        "inboxProjectId": NSNull(),
                        "avatarUrl": NSNull(),
                    ])
                case ("POST", "/sync/push"):
                    var results: [[String: Any]] = []
                    if case let .array(ops) = req.bodyJSON?["ops"] {
                        for op in ops {
                            if case let .object(dict) = op, let opId = dict["opId"]?.stringValue {
                                results.append(["opId": opId, "status": "applied"])
                            }
                        }
                    }
                    return jsonHTTP(200, ["results": results, "serverTime": "0000000001000:0000:srv"])
                case ("POST", "/sync/pull"):
                    return jsonHTTP(200, ["scopes": [], "members": []])
                default:
                    return jsonHTTP(404, ["error": "Not found"])
                }
            }
        }

        let server = SingleUseEmailServer()
        let transport = RecordingAuthTransport { req in
            await server.handle(req)
        }
        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens)

        // User A signs in and creates a local task, then loses tokens (forced sign-out state).
        _ = try await engine.signIn(with: .apple(identityToken: "a-tok", nonce: "a-nonce"))
        let savedTask = try await api.createTask(CreateTaskInput(title: "帳號 A 的本地任務"))
        tokens.accessToken = nil
        tokens.refreshToken = nil
        #expect(try await engine.signedInUserId == "user-a")

        // Signing in with User B's one-time email code consumes the code once and surfaces AuthError.differentAccount.
        var capturedAuth: AuthLoginResponse?
        do {
            _ = try await engine.signIn(with: .email(email: "b@example.com", code: "123456"))
            Issue.record("Expected AuthError.differentAccount")
        } catch let AuthError.differentAccount(auth) {
            capturedAuth = auth
        }
        let authB = try #require(capturedAuth)
        #expect(authB.user.id == "user-b")
        #expect(await server.verifyCalls == 1)

        // Cancel branch: User A's local data and signedInUserId remain intact.
        #expect(try await engine.signedInUserId == "user-a")
        let tasksBeforeConfirm = try await api.listTasks(TaskQuery(includeCompleted: true))
        #expect(tasksBeforeConfirm.contains { $0.id == savedTask.id })

        // Confirm branch: wipe old account and finish sign-in using the already-received AuthLoginResponse
        // without re-sending /auth/email/verify.
        try await engine.signOut()
        _ = try await engine.completeSignIn(with: authB)
        #expect(try await engine.signedInUserId == "user-b")
        #expect(tokens.accessToken == "acc-b")
        #expect(tokens.refreshToken == "ref-b")
        #expect(await server.verifyCalls == 1)
        let tasksAfterConfirm = try await api.listTasks(TaskQuery(includeCompleted: true))
        #expect(!tasksAfterConfirm.contains { $0.id == savedTask.id })
    }

    @Test func link5xxOrLostResponseConfirmsViaIdentitiesEndpoint() async throws {
        // 1. POST /auth/link fails with 500, but GET /me/identities shows email was already linked -> succeeds.
        let (engine500, transport500, _) = try makeEngine { req in
            switch (req.method, req.path) {
            case ("POST", "/auth/link"):
                return jsonHTTP(500, ["error": "D1 timeout"])
            case ("GET", "/me/identities"):
                return jsonHTTP(200, [
                    ["provider": "apple", "createdAt": 1000],
                    ["provider": "email", "email": "me@example.com", "createdAt": 2000],
                ])
            default:
                return jsonHTTP(404, ["error": "Not found"])
            }
        }

        let confirmed = try await engine500.linkIdentity(with: .email(email: "Me@Example.com ", code: "123456"))
        #expect(confirmed.map(\.provider) == [.apple, .email])
        #expect(await transport500.allRequests().map(\.path) == ["/auth/link", "/me/identities"])

        // 2. POST /auth/link drops connection, GET /me/identities does NOT show the identity -> throws retryable.
        let (engineLost, transportLost, _) = try makeEngine { req in
            switch (req.method, req.path) {
            case ("POST", "/auth/link"):
                throw URLError(.networkConnectionLost)
            case ("GET", "/me/identities"):
                return jsonHTTP(200, [
                    ["provider": "apple", "createdAt": 1000],
                ])
            default:
                return jsonHTTP(404, ["error": "Not found"])
            }
        }

        var caughtRetryable = false
        do {
            _ = try await engineLost.linkIdentity(with: .email(email: "me@example.com", code: "123456"))
            Issue.record("Expected retryable error when identity was not persisted")
        } catch SyncError.retryable {
            caughtRetryable = true
        }
        #expect(caughtRetryable)
        #expect(await transportLost.allRequests().map(\.path) == ["/auth/link", "/me/identities"])
    }

    @Test func credentialErrorsUseFixedLocalizedChineseMessage() {
        #expect(AuthError.invalidCredentials("Nonce mismatch").errorDescription == "驗證失敗，請再試一次")
        #expect(AuthError.badRequest("Invalid JSON body").errorDescription == "驗證失敗，請再試一次")
        #expect(AuthError.invalidCode.errorDescription == "驗證碼錯誤或已過期，請再試一次")
        #expect(AuthError.identityInUse.errorDescription == "這個登入方式已經屬於另一個 DayDo 帳號")
    }
}
