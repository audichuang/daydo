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
}
