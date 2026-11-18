// Real-HTTP attachment upload/download e2e against a local dev stand-in (requires `/test/mail`).
// Run: `bash server/.claude/skills/verify/scripts/devserver.sh up` then
// `DAYDO_SYNC_BASE_URL=http://127.0.0.1:8787 DAYDO_SYNC_EMAIL_LOGIN=1 swift test --filter AttachmentTransportE2ETests`

import Foundation
import GRDB
import Testing
@testable import DayDoCore

private let attachmentE2EBaseURL = ProcessInfo.processInfo.environment["DAYDO_SYNC_BASE_URL"]
private let attachmentE2EEmailLogin = ProcessInfo.processInfo.environment["DAYDO_SYNC_EMAIL_LOGIN"] == "1"
private let attachmentE2EEnabled = attachmentE2EBaseURL != nil && attachmentE2EEmailLogin

private struct EmailStartRequest: Encodable, Sendable {
    let email: String
    let deviceId: String
}

private struct EmailVerifyRequest: Encodable, Sendable {
    let email: String
    let code: String
    let deviceId: String
}

private struct DevMailResponse: Decodable, Sendable {
    let code: String?
}

@Suite struct AttachmentTransportE2ETests {
    @Test(
        .enabled(
            if: attachmentE2EEnabled,
            "Requires DAYDO_SYNC_BASE_URL and DAYDO_SYNC_EMAIL_LOGIN=1"
        )
    )
    func attachmentUploadAndDownloadOverHTTPWithEmailLogin() async throws {
        let baseURLString = try #require(attachmentE2EBaseURL)
        let baseURL = try #require(URL(string: baseURLString))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-att-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let attDirA = tempDir.appendingPathComponent("att-a", isDirectory: true)
        let attDirB = tempDir.appendingPathComponent("att-b", isDirectory: true)
        let dbA = try AppDatabase.open(at: tempDir.appendingPathComponent("device-a.sqlite"))
        let dbB = try AppDatabase.open(at: tempDir.appendingPathComponent("device-b.sqlite"))

        let deviceIdA = try await dbA.writer.write { db in try HLC.ensureDeviceId(in: db) }
        let deviceIdB = try await dbB.writer.write { db in try HLC.ensureDeviceId(in: db) }
        #expect(deviceIdA != deviceIdB)

        let transport = HTTPSyncTransport(baseURL: baseURL)
        let tokensA = InMemorySyncTokenStore()
        let tokensB = InMemorySyncTokenStore()

        let clockA = MutableClock(startMs: Date().epochMillis)
        let clockB = MutableClock(startMs: Date().epochMillis)

        let apiA = LocalDayDoAPI(database: dbA, clock: clockA.clock, attachmentsDirectory: attDirA)
        let apiB = LocalDayDoAPI(database: dbB, clock: clockB.clock, attachmentsDirectory: attDirB)

        let syncA = SyncEngine(
            database: dbA,
            transport: transport,
            tokenStore: tokensA,
            clock: clockA.clock,
            attachmentsDirectory: attDirA
        )
        let syncB = SyncEngine(
            database: dbB,
            transport: transport,
            tokenStore: tokensB,
            clock: clockB.clock,
            attachmentsDirectory: attDirB
        )
        apiA.setSyncEngine(syncA)
        apiB.setSyncEngine(syncB)

        let email = "att-e2e-\(UUID().uuidString.lowercased())@example.com"

        // 1. Device A: email login -> bootstrap -> create task -> uploadAttachment -> syncNow -> waitForAttachmentUploads.
        let loginA = try await loginWithEmailCode(
            baseURL: baseURL,
            transport: transport,
            email: email,
            deviceId: deviceIdA,
            database: dbA,
            tokenStore: tokensA
        )
        #expect(loginA.isNewAccount)
        #expect(try await syncA.isSignedIn)

        try await apiA.bootstrap()
        let task = try await apiA.createTask(CreateTaskInput(title: "附件傳輸測試任務"))
        let payload = Data("這是附件測試內容：全家待辦清單。\n第二行 UTF-8 位元組驗證！\n".utf8)
        let attA = try await apiA.uploadAttachment(
            taskId: task.id,
            fileName: "備忘錄.txt",
            data: payload,
            mimeType: "text/plain",
            originalPath: nil
        )
        #expect(attA.localPath != nil)

        _ = try await syncA.syncNow()
        await syncA.waitForAttachmentUploads()

        let recA = try #require(try await dbA.writer.read { db in
            try AttachmentRecord.fetchOne(db, key: attA.id)
        })
        #expect(recA.fileUploadedAt != nil)
        #expect(recA.fileUploadFailed == false)

        // 2. Device B: email login -> pull -> attachment row has localPath == nil -> api.attachmentFile downloads bytes.
        let loginB = try await loginWithEmailCode(
            baseURL: baseURL,
            transport: transport,
            email: email,
            deviceId: deviceIdB,
            database: dbB,
            tokenStore: tokensB
        )
        #expect(!loginB.isNewAccount)
        #expect(loginB.user.id == loginA.user.id)
        #expect(try await syncB.isSignedIn)

        let pullSummaryB = try await syncB.syncNow()
        #expect(pullSummaryB.pulledCount > 0)

        let taskB = try await apiB.getTask(id: task.id)
        let attB = try #require(taskB.attachments.first { $0.id == attA.id })
        #expect(attB.fileName == attA.fileName)
        #expect(attB.size == Int64(payload.count))
        #expect(attB.localPath == nil)

        let changeCountBeforeDownload = try await dbB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? -1
        }

        let downloadedURL = try await apiB.attachmentFile(attB)
        let downloadedData = try Data(contentsOf: downloadedURL)
        #expect(downloadedData == payload)

        let refreshedTaskB = try await apiB.getTask(id: task.id)
        let refreshedAttB = try #require(refreshedTaskB.attachments.first { $0.id == attA.id })
        #expect(refreshedAttB.localPath == "\(attA.id)/\(attA.fileName)")
        #expect(downloadedURL == apiB.attachmentURL(refreshedAttB))

        let recB = try #require(try await dbB.writer.read { db in
            try AttachmentRecord.fetchOne(db, key: attA.id)
        })
        #expect(recB.localPath == "\(attA.id)/\(attA.fileName)")

        let changeCountAfterDownload = try await dbB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? -1
        }
        #expect(changeCountAfterDownload == changeCountBeforeDownload)
        #expect(try await apiB.unsyncedChangeCount() == 0)
    }
}

private func loginWithEmailCode(
    baseURL: URL,
    transport: HTTPSyncTransport,
    email: String,
    deviceId: String,
    database: AppDatabase,
    tokenStore: InMemorySyncTokenStore
) async throws -> AuthLoginResponse {
    let startBody = try Outbox.encoder.encode(EmailStartRequest(email: email, deviceId: deviceId))
    let startRes = try await transport.send(
        method: "POST",
        path: "/auth/email/start",
        headers: ["Content-Type": "application/json"],
        body: startBody
    )
    #expect(startRes.status == 202)

    var mailComponents = try #require(URLComponents(url: baseURL.appendingPathComponent("test/mail"), resolvingAgainstBaseURL: false))
    mailComponents.queryItems = [URLQueryItem(name: "to", value: email)]
    let mailURL = try #require(mailComponents.url)
    let (mailData, mailURLResponse) = try await URLSession.shared.data(from: mailURL)
    let mailHTTPResponse = try #require(mailURLResponse as? HTTPURLResponse)
    #expect(mailHTTPResponse.statusCode == 200)
    let mail = try JSONDecoder().decode(DevMailResponse.self, from: mailData)
    let code = try #require(mail.code)
    #expect(code.count == 6)

    let verifyBody = try Outbox.encoder.encode(EmailVerifyRequest(email: email, code: code, deviceId: deviceId))
    let verifyRes = try await transport.send(
        method: "POST",
        path: "/auth/email/verify",
        headers: ["Content-Type": "application/json"],
        body: verifyBody
    )
    #expect(verifyRes.status == 200)

    let decoded = try JSONDecoder().decode(AuthLoginResponse.self, from: verifyRes.body)
    tokenStore.refreshToken = decoded.refreshToken
    tokenStore.accessToken = decoded.accessToken
    try await database.writer.write { db in
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [SyncEngine.signedInUserIdMetaKey, decoded.user.id]
        )
    }
    return decoded
}
