import Foundation
import GRDB
import Testing
@testable import DayDoCore

private let firstLoginBaseURL = ProcessInfo.processInfo.environment["DAYDO_SYNC_BASE_URL"]
private let firstLoginGoogleIdToken = ProcessInfo.processInfo.environment["DAYDO_SYNC_FIRST_LOGIN_GOOGLE_ID_TOKEN"]
private let firstLoginEnabled = firstLoginBaseURL != nil && firstLoginGoogleIdToken != nil

@Suite struct FirstLoginTests {
    @Test(.enabled(if: firstLoginEnabled))
    func firstLoginTwoPhonesConvergeWithRemapAndDedup() async throws {
        let baseURLString = try #require(firstLoginBaseURL)
        let baseURL = try #require(URL(string: baseURLString))
        let idToken = try #require(firstLoginGoogleIdToken)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-first-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbA = try AppDatabase.open(at: tempDir.appendingPathComponent("device-a.sqlite"))
        let dbB = try AppDatabase.open(at: tempDir.appendingPathComponent("device-b.sqlite"))

        let baseMs = Date().epochMillis
        let clockA = MutableClock(startMs: baseMs)
        let clockB = MutableClock(startMs: baseMs + 500)

        let apiA = LocalDayDoAPI(
            database: dbA,
            clock: clockA.clock,
            attachmentsDirectory: tempDir.appendingPathComponent("att-a")
        )
        let apiB = LocalDayDoAPI(
            database: dbB,
            clock: clockB.clock,
            attachmentsDirectory: tempDir.appendingPathComponent("att-b")
        )

        let transport = HTTPSyncTransport(baseURL: baseURL)
        let tokensA = InMemorySyncTokenStore()
        let tokensB = InMemorySyncTokenStore()
        let syncA = SyncEngine(database: dbA, transport: transport, tokenStore: tokensA, clock: clockA.clock)
        let syncB = SyncEngine(database: dbB, transport: transport, tokenStore: tokensB, clock: clockB.clock)

        // Phone A bootstraps locally and creates tasks in inbox and 工作 before signing in.
        try await apiA.bootstrap()
        let inboxA = try #require(try await apiA.listProjects(includeArchived: false).first(where: \.isInbox))
        let workA = try #require(try await apiA.listProjects(includeArchived: false).first(where: { $0.name == "工作" }))
        let meA = try #require(try await apiA.listMembers().first(where: \.isMe))

        clockA.advance(by: 100)
        let taskAInbox = try await apiA.createTask(CreateTaskInput(projectId: inboxA.id, title: "A 收件匣任務"))
        clockA.advance(by: 100)
        let taskAWork = try await apiA.createTask(CreateTaskInput(
            projectId: workA.id,
            title: "A 工作任務",
            subtasks: ["準備簡報"],
            tags: ["#工作"]
        ))

        // Phone A signs in to an empty account -> uploads defaults + tasks.
        _ = try await syncA.signIn(with: .google(idToken: idToken))
        #expect(try await syncA.isSignedIn)

        // Phone B bootstraps independently and creates its own local task in its inbox before signing in.
        try await apiB.bootstrap()
        let inboxB = try #require(try await apiB.listProjects(includeArchived: false).first(where: \.isInbox))
        let meB = try #require(try await apiB.listMembers().first(where: \.isMe))
        #expect(inboxB.id != inboxA.id)
        #expect(meB.id != meA.id)

        clockB.advance(by: 200)
        let taskBInbox = try await apiB.createTask(CreateTaskInput(
            projectId: inboxB.id,
            title: "B 離線收件匣任務",
            assigneeId: meB.id
        ))

        // Phone B signs in to the same account -> remaps me/inbox, drops untouched 工作/個人/購物, syncs.
        _ = try await syncB.signIn(with: .google(idToken: idToken))
        #expect(try await syncB.isSignedIn)
        #expect(try await syncA.signedInUserId == syncB.signedInUserId)

        // Let A pull B's task and confirm quiet convergence.
        try await syncUntilQuiet(syncA, syncB)
        let quietA = try await syncA.syncNow()
        let quietB = try await syncB.syncNow()
        #expect(quietA.pushedCount == 0 && quietA.pulledCount == 0)
        #expect(quietB.pushedCount == 0 && quietB.pulledCount == 0)

        for (api, label) in [(apiA, "A"), (apiB, "B")] {
            let projects = try await api.listProjects(includeArchived: false)
            let inboxes = projects.filter(\.isInbox)
            #expect(inboxes.count == 1, "Expected 1 inbox on phone \(label)")
            #expect(inboxes.first?.id == inboxA.id)
            #expect(projects.map(\.name) == ["收件匣", "工作", "個人", "購物"], "Expected no duplicate default lists on phone \(label)")

            let members = try await api.listMembers()
            let meMembers = members.filter(\.isMe)
            #expect(meMembers.count == 1, "Expected 1 isMe member on phone \(label)")
            #expect(meMembers.first?.id == meA.id)

            let fetchedBTask = try await api.getTask(id: taskBInbox.id)
            #expect(fetchedBTask.projectId == inboxA.id)
            #expect(fetchedBTask.assigneeId == meA.id)
            #expect(fetchedBTask.title == "B 離線收件匣任務")

            _ = try await api.getTask(id: taskAInbox.id)
            let fetchedAWork = try await api.getTask(id: taskAWork.id)
            #expect(fetchedAWork.projectId == workA.id)
            #expect(fetchedAWork.items.map(\.title) == ["準備簡報"])
        }

        for db in [dbA, dbB] {
            let (unacked, staged) = try await db.writer.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change WHERE ackedAt IS NULL") ?? -1,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") ?? -1
                )
            }
            #expect(unacked == 0)
            #expect(staged == 0)
        }

        let snapA = try await snapshot(of: dbA)
        let snapB = try await snapshot(of: dbB)
        #expect(snapA == snapB)

        let serverSnap = try await fetchServerSnapshot(transport: transport, accessToken: try #require(tokensA.accessToken))
        #expect(snapA == serverSnap)
    }
}
