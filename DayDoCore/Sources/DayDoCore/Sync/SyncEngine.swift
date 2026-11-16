import Foundation
import GRDB

/// Summary of a completed `SyncEngine.syncNow()` cycle.
public struct SyncSummary: Sendable, Equatable {
    public let pushedCount: Int
    public let appliedCount: Int
    public let rejectedCount: Int
    public let pulledCount: Int
    public let didChangeLocalData: Bool

    public init(
        pushedCount: Int = 0,
        appliedCount: Int = 0,
        rejectedCount: Int = 0,
        pulledCount: Int = 0,
        didChangeLocalData: Bool = false
    ) {
        self.pushedCount = pushedCount
        self.appliedCount = appliedCount
        self.rejectedCount = rejectedCount
        self.pulledCount = pulledCount
        self.didChangeLocalData = didChangeLocalData
    }
}

/// Coordinates push/pull synchronization and token refresh for one signed-in user.
public actor SyncEngine {
    public static let pullCursorsMetaKey = "pullCursors"
    public static let signedInUserIdMetaKey = "signedInUserId"
    public static let meAvatarUrlMetaKey = "meAvatarUrl"

    let database: AppDatabase
    private let transport: any SyncTransport
    private let tokenStore: any SyncTokenStore
    private let clock: Clock
    private let pushBatchSize: Int
    private let pullLimit: Int
    private let baseBackoffSeconds: TimeInterval
    private let maxBackoffSeconds: TimeInterval

    private var inFlightSync: Task<SyncSummary, Error>?
    private var rerunRequested: Bool = false
    private var inFlightRefresh: Task<String, Error>?
    private var consecutiveRetryableFailures: Int = 0
    private var sessionGeneration: UInt64 = 0
    private var continuations: [UUID: AsyncStream<SyncSummary>.Continuation] = [:]

    private let encoder = Outbox.encoder
    private let decoder = JSONDecoder()

    init(
        database: AppDatabase,
        transport: any SyncTransport,
        tokenStore: any SyncTokenStore,
        clock: Clock = .system,
        pushBatchSize: Int = 50,
        pullLimit: Int = 500,
        baseBackoffSeconds: TimeInterval = 1.0,
        maxBackoffSeconds: TimeInterval = 300.0
    ) {
        self.database = database
        self.transport = transport
        self.tokenStore = tokenStore
        self.clock = clock
        self.pushBatchSize = max(1, pushBatchSize)
        self.pullLimit = max(1, pullLimit)
        self.baseBackoffSeconds = max(0.1, baseBackoffSeconds)
        self.maxBackoffSeconds = max(self.baseBackoffSeconds, maxBackoffSeconds)
    }

    /// Emits a `SyncSummary` whenever a sync cycle changes local data.
    public func changeNotifications() -> AsyncStream<SyncSummary> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emitChange(_ summary: SyncSummary) {
        for continuation in continuations.values {
            continuation.yield(summary)
        }
    }

    /// Currently signed-in account user id persisted in `meta`, if any.
    public var signedInUserId: String? {
        get async throws {
            try await database.writer.read { db in
                try Self.loadSignedInUserId(in: db)
            }
        }
    }

    /// Stored avatar URL for the currently signed-in user, if any.
    public var meAvatarUrl: String? {
        get async throws {
            try await database.writer.read { db in
                try Self.loadMeAvatarUrl(in: db)
            }
        }
    }

    /// True when a signed-in user id is persisted and auth tokens are present.
    public var isSignedIn: Bool {
        get async throws {
            guard let userId = try await signedInUserId, !userId.isEmpty else {
                return false
            }
            return hasStoredTokens()
        }
    }

    /// Signs in with Google or Apple, runs first-login reconciliation once in a single write
    /// transaction before the first push, and runs `syncNow()`.
    @discardableResult
    public func signIn(with credential: SyncAuthCredential) async throws -> SyncSummary {
        let generation = sessionGeneration
        let deviceId = try await database.writer.write { db in
            try HLC.ensureDeviceId(in: db)
        }

        let path: String
        let requestBody: Data
        switch credential {
        case let .google(idToken):
            path = "/auth/google"
            requestBody = try encoder.encode(AuthGoogleRequest(idToken: idToken, deviceId: deviceId))
        case let .apple(identityToken, nonce):
            path = "/auth/apple"
            requestBody = try encoder.encode(AuthAppleRequest(identityToken: identityToken, nonce: nonce, deviceId: deviceId))
        }

        let response = try await sendWithNetworkRetryable(
            method: "POST",
            path: path,
            headers: [:],
            body: requestBody
        )
        let data = try validateHTTPResponse(response)
        let auth = try decode(AuthLoginResponse.self, from: data)

        guard generation == sessionGeneration else {
            throw SyncError.signedOut
        }

        if let existingUserId = try await signedInUserId, existingUserId != auth.user.id {
            throw SyncError.protocolError("Already signed in as a different user; sign out first")
        }

        tokenStore.refreshToken = auth.refreshToken
        tokenStore.accessToken = auth.accessToken
        consecutiveRetryableFailures = 0

        let now = clock.now().epochMillis
        let didChangeInReconcile = try await database.writer.write { db -> Bool in
            if try Self.loadSignedInUserId(in: db) != nil {
                try Self.markLocalProjectInviteOpsLocalOnly(in: db, now: now)
                let changedAvatar = try Self.saveMeAvatarUrl(auth.avatarUrl, in: db)
                return changedAvatar
            }
            let changed = try Self.reconcileFirstLogin(auth: auth, in: db, now: now)
            try Self.saveSignedInUserId(auth.user.id, in: db)
            let changedAvatar = try Self.saveMeAvatarUrl(auth.avatarUrl, in: db)
            return changed || changedAvatar
        }

        let summary: SyncSummary
        do {
            summary = try await syncNow()
        } catch {
            if didChangeInReconcile {
                emitChange(SyncSummary(didChangeLocalData: true))
            }
            throw error
        }
        if didChangeInReconcile && !summary.didChangeLocalData {
            let combined = SyncSummary(
                pushedCount: summary.pushedCount,
                appliedCount: summary.appliedCount,
                rejectedCount: summary.rejectedCount,
                pulledCount: summary.pulledCount,
                didChangeLocalData: true
            )
            emitChange(combined)
            return combined
        }
        return summary
    }

    /// Clears stored tokens and wipes all local synced tables, outbox, purgedId, staging,
    /// pull cursors, and signed-in userId while keeping `deviceId` and `hlc`.
    public func signOut() async throws {
        sessionGeneration &+= 1
        inFlightSync?.cancel()
        inFlightRefresh?.cancel()
        tokenStore.accessToken = nil
        tokenStore.refreshToken = nil
        consecutiveRetryableFailures = 0

        try await database.writer.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for table in [
                "comment",
                "attachment",
                "checklistItem",
                "task",
                "projectInvite",
                "projectMember",
                "project",
                "folder",
                "member",
                "tag",
                "change",
                "purgedId",
                "syncStaging",
                "projectMembership",
                "memberUser",
            ] {
                try db.execute(sql: "DELETE FROM \"\(table)\"")
            }
            try db.execute(
                sql: "DELETE FROM meta WHERE key IN (?, ?, ?)",
                arguments: [Self.pullCursorsMetaKey, Self.signedInUserIdMetaKey, Self.meAvatarUrlMetaKey]
            )
        }
    }

    /// Runs push followed by pull. Concurrent callers join the in-flight run and request one coalesced rerun.
    @discardableResult
    public func syncNow() async throws -> SyncSummary {
        if let existing = inFlightSync {
            rerunRequested = true
            return try await existing.value
        }
        let generation = sessionGeneration
        let task = Task {
            try await self.runSyncLoop(generation: generation)
        }
        inFlightSync = task
        return try await task.value
    }

    /// Updates the signed-in user's avatar URL on the server (`PUT /me/avatar`) and stores the result locally.
    @discardableResult
    public func updateMeAvatar(_ avatarUrl: String) async throws -> String {
        let generation = sessionGeneration
        let body = try encoder.encode(UpdateMeAvatarRequest(avatarUrl: avatarUrl))
        let data = try await sendAuthorized(method: "PUT", path: "/me/avatar", body: body)
        let decoded = try decode(UpdateMeAvatarResponse.self, from: data)
        guard generation == sessionGeneration else {
            throw SyncError.signedOut
        }
        let didUpdate = try await database.writer.write { db in
            try Self.saveMeAvatarUrl(decoded.avatarUrl, in: db)
        }
        if didUpdate {
            emitChange(SyncSummary(didChangeLocalData: true))
        }
        return decoded.avatarUrl
    }

    // MARK: - Sharing

    public static func parseInviteCode(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "daydo",
              url.host?.lowercased() == "invite",
              url.query == nil else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segments.count == 1 else {
            return nil
        }
        return segments[0]
    }

    public static func parseInviteCode(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return nil
        }
        return parseInviteCode(from: url)
    }

    private func runSyncLoop(generation: UInt64) async throws -> SyncSummary {
        defer {
            inFlightSync = nil
            rerunRequested = false
        }

        var total = SyncSummary()
        while true {
            guard generation == sessionGeneration else {
                throw SyncError.signedOut
            }
            rerunRequested = false
            let cycle = try await performSyncCycle(generation: generation)
            total = SyncSummary(
                pushedCount: total.pushedCount + cycle.pushedCount,
                appliedCount: total.appliedCount + cycle.appliedCount,
                rejectedCount: total.rejectedCount + cycle.rejectedCount,
                pulledCount: total.pulledCount + cycle.pulledCount,
                didChangeLocalData: total.didChangeLocalData || cycle.didChangeLocalData
            )
            if !rerunRequested {
                return total
            }
        }
    }

    private func performSyncCycle(generation: UInt64) async throws -> SyncSummary {
        var pushProgress = PushProgress()
        var pullProgress = PullProgress()
        defer {
            let summary = makeSummary(push: pushProgress, pull: pullProgress)
            if summary.didChangeLocalData {
                emitChange(summary)
            }
        }

        try await performPush(&pushProgress, generation: generation)
        try await performPull(&pullProgress, generation: generation)

        consecutiveRetryableFailures = 0

        return makeSummary(push: pushProgress, pull: pullProgress)
    }

    private func makeSummary(push: PushProgress, pull: PullProgress) -> SyncSummary {
        SyncSummary(
            pushedCount: push.pushedCount,
            appliedCount: push.appliedCount,
            rejectedCount: push.rejectedCount,
            pulledCount: pull.pulledCount,
            didChangeLocalData: push.didChangeLocalData || pull.didChangeLocalData
        )
    }

    // MARK: - Push

    private struct PushProgress {
        var pushedCount: Int = 0
        var appliedCount: Int = 0
        var rejectedCount: Int = 0
        var didChangeLocalData: Bool = false
    }

    private func performPush(_ progress: inout PushProgress, generation: UInt64) async throws {
        let batchLimit = pushBatchSize

        while true {
            guard generation == sessionGeneration else {
                throw SyncError.signedOut
            }
            let (deviceId, batch) = try await database.writer.write { db -> (String, [ChangeRecord]) in
                let devId = try HLC.ensureDeviceId(in: db)
                let rows = try ChangeRecord
                    .filter(Column("ackedAt") == nil && Column("entity") != "projectInvite")
                    .order(Column("seq"))
                    .limit(batchLimit)
                    .fetchAll(db)
                return (devId, rows)
            }

            if batch.isEmpty {
                break
            }

            let ops: [SyncPushOp] = try batch.map { change in
                guard let opId = change.opId, !opId.isEmpty,
                      let hlc = change.hlc, !hlc.isEmpty else {
                    throw SyncError.protocolError("Outbox row missing opId or hlc")
                }
                let rowObj = try decoder.decode([String: SyncJSONValue].self, from: Data(change.row.utf8))
                return SyncPushOp(
                    opId: opId,
                    hlc: hlc,
                    entity: change.entity,
                    entityId: change.entityId,
                    op: change.op,
                    fields: change.fields,
                    row: rowObj
                )
            }

            let requestData = try encoder.encode(SyncPushRequest(deviceId: deviceId, ops: ops))
            let responseData = try await sendAuthorized(method: "POST", path: "/sync/push", body: requestData)
            guard generation == sessionGeneration else {
                throw SyncError.signedOut
            }
            let response = try decode(SyncPushResponse.self, from: responseData)

            guard response.results.count == batch.count else {
                throw SyncError.protocolError("Push response result count (\(response.results.count)) does not match batch (\(batch.count))")
            }

            let now = clock.now().epochMillis
            let batchStats = try await database.writer.write { db -> (applied: Int, rejected: Int, changed: Bool) in
                if let serverHLC = HLC(response.serverTime) {
                    try HLC.receive(serverHLC, in: db, now: now)
                }

                var applied = 0
                var rejected = 0
                var changed = false

                for (change, result) in zip(batch, response.results) {
                    guard let seq = change.seq else { continue }
                    let ackStatus = result.status == "rejected" ? "rejected" : "applied"
                    if ackStatus == "rejected" {
                        rejected += 1
                    } else {
                        applied += 1
                    }

                    try db.execute(
                        sql: "UPDATE change SET ackedAt = ?, result = ? WHERE seq = ?",
                        arguments: [now, ackStatus, seq]
                    )

                    if result.gone == true {
                        if try SyncApplier.applyGone(entity: change.entity, entityId: change.entityId, in: db) {
                            changed = true
                        }
                        continue
                    }

                    if let serverRow = result.row {
                        let clocks = result.clocks ?? [:]
                        if let maxClock = clocks.values.compactMap(HLC.init).max() {
                            try HLC.receive(maxClock, in: db, now: now)
                        }
                        let outcome = try SyncApplier.applyRow(
                            entity: change.entity,
                            entityId: change.entityId,
                            row: serverRow,
                            clocks: clocks,
                            in: db
                        )
                        if outcome.didChangeLocalData {
                            changed = true
                        }
                    }
                }

                if try SyncApplier.retryStagedRows(in: db) {
                    changed = true
                }

                return (applied, rejected, changed)
            }

            progress.pushedCount += batch.count
            progress.appliedCount += batchStats.applied
            progress.rejectedCount += batchStats.rejected
            if batchStats.changed {
                progress.didChangeLocalData = true
            }
        }
    }

    // MARK: - Pull

    private struct PullProgress {
        var pulledCount: Int = 0
        var didChangeLocalData: Bool = false
    }

    private func performPull(_ progress: inout PullProgress, generation: UInt64) async throws {
        var backfilledProjectIds: Set<String> = []
        try await runPendingBackfill(
            excluding: &backfilledProjectIds,
            progress: &progress,
            generation: generation
        )

        var cursors = try await database.writer.read { db in
            try Self.loadPullCursors(in: db)
        }

        while true {
            guard generation == sessionGeneration else {
                throw SyncError.signedOut
            }
            let requestData = try encoder.encode(SyncPullRequest(cursors: cursors, limit: pullLimit))
            let responseData = try await sendAuthorized(method: "POST", path: "/sync/pull", body: requestData)
            guard generation == sessionGeneration else {
                throw SyncError.signedOut
            }
            let response = try decode(SyncPullResponse.self, from: responseData)
            let (pageRowCount, pageChanged, updatedCursors) = try await applyPullResponsePage(
                response,
                isBackfill: false,
                fallbackCursors: cursors
            )

            cursors = updatedCursors
            progress.pulledCount += pageRowCount
            if pageChanged {
                progress.didChangeLocalData = true
            }

            if !response.scopes.contains(where: { $0.hasMore }) {
                break
            }
        }

        try await runPendingBackfill(
            excluding: &backfilledProjectIds,
            progress: &progress,
            generation: generation
        )
    }

    private func runPendingBackfill(
        excluding attemptedBackfill: inout Set<String>,
        progress: inout PullProgress,
        generation: UInt64
    ) async throws {
        while true {
            let pendingBackfill = try await database.writer.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT projectId FROM projectMembership WHERE needsBackfill = 1 ORDER BY projectId"
                )
            }.filter { !attemptedBackfill.contains($0) }

            if pendingBackfill.isEmpty {
                return
            }
            attemptedBackfill.formUnion(pendingBackfill)

            var backfillCursors: [String: Int64] = [:]
            while true {
                guard generation == sessionGeneration else {
                    throw SyncError.signedOut
                }
                let requestData = try encoder.encode(
                    SyncPullRequest(cursors: backfillCursors, limit: pullLimit, backfill: pendingBackfill)
                )
                let responseData = try await sendAuthorized(method: "POST", path: "/sync/pull", body: requestData)
                guard generation == sessionGeneration else {
                    throw SyncError.signedOut
                }
                let response = try decode(SyncPullResponse.self, from: responseData)
                let (pageRowCount, pageChanged, updatedBackfillCursors) = try await applyPullResponsePage(
                    response,
                    isBackfill: true,
                    fallbackCursors: backfillCursors
                )
                backfillCursors = updatedBackfillCursors
                progress.pulledCount += pageRowCount
                if pageChanged {
                    progress.didChangeLocalData = true
                }
                if !response.scopes.contains(where: { $0.hasMore }) {
                    break
                }
            }
            try await database.writer.write { db in
                for pid in pendingBackfill {
                    try db.execute(
                        sql: "UPDATE projectMembership SET needsBackfill = 0 WHERE projectId = ?",
                        arguments: [pid]
                    )
                }
            }
        }
    }

    private func applyPullResponsePage(
        _ response: SyncPullResponse,
        isBackfill: Bool,
        fallbackCursors: [String: Int64]
    ) async throws -> (Int, Bool, [String: Int64]) {
        let now = clock.now().epochMillis
        return try await database.writer.write { db -> (Int, Bool, [String: Int64]) in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            var rowCount = 0
            var changed = false
            var nextCursors = isBackfill ? fallbackCursors : try Self.loadPullCursors(in: db)
            var maxSeenHLC: HLC?

            struct PendingUpsert {
                let entity: String
                let entityId: String
                let row: [String: SyncJSONValue]
                let clocks: [String: String]
                let serverSeq: Int64
            }
            var deferredUpserts: [PendingUpsert] = []

            if let members = response.members {
                for memberRow in members {
                    guard let entityId = SyncApplier.entityId(for: "member", row: memberRow) else { continue }
                    let existingIsMe = try Bool.fetchOne(
                        db,
                        sql: "SELECT isMe FROM member WHERE id = ?",
                        arguments: [entityId]
                    ) ?? false
                    if existingIsMe {
                        continue
                    }
                    let uid = memberRow["userId"]?.stringValue ?? ""
                    let avatarUrl = memberRow["avatarUrl"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    let existingRow = try Row.fetchOne(
                        db,
                        sql: "SELECT userId, avatarUrl FROM memberUser WHERE memberId = ?",
                        arguments: [entityId]
                    )
                    let existingAvatar: String? = existingRow?["avatarUrl"]
                    if !uid.isEmpty || avatarUrl != nil || existingRow != nil {
                        try db.execute(
                            sql: """
                                INSERT INTO memberUser (memberId, userId, avatarUrl) VALUES (?, ?, ?)
                                ON CONFLICT(memberId) DO UPDATE SET
                                    userId = CASE WHEN excluded.userId != '' THEN excluded.userId ELSE memberUser.userId END,
                                    avatarUrl = excluded.avatarUrl
                                """,
                            arguments: [entityId, uid, avatarUrl]
                        )
                        if existingAvatar != avatarUrl {
                            changed = true
                        }
                    }
                    var sanitizedRow = memberRow
                    sanitizedRow["isMe"] = .bool(false)
                    let outcome = try SyncApplier.applyRow(
                        entity: "member",
                        entityId: entityId,
                        row: sanitizedRow,
                        clocks: [:],
                        in: db
                    )
                    if outcome.didChangeLocalData {
                        changed = true
                    }
                }
            }

            for scopeSlice in response.scopes {
                nextCursors[scopeSlice.scope] = max(nextCursors[scopeSlice.scope] ?? 0, scopeSlice.cursor)

                for item in scopeSlice.rows {
                    rowCount += 1
                    guard SyncApplier.isKnownEntity(item.entity) else { continue }

                    if item.gone == true {
                        guard let entityId = item.entityId, !entityId.isEmpty else {
                            throw SyncError.protocolError("Pull gone row missing entityId for \(item.entity)")
                        }
                        if try SyncApplier.applyGone(entity: item.entity, entityId: entityId, in: db) {
                            changed = true
                        }
                        if item.entity == "project" {
                            try db.execute(
                                sql: "DELETE FROM projectMembership WHERE projectId = ?",
                                arguments: [entityId]
                            )
                        }
                        continue
                    }

                    guard let row = item.row,
                          let entityId = SyncApplier.entityId(for: item.entity, row: row) else {
                        throw SyncError.protocolError("Pull row missing row payload or id for \(item.entity)")
                    }
                    let clocks = item.clocks ?? [:]
                    if let pageHLC = clocks.values.compactMap(HLC.init).max() {
                        if let currentMax = maxSeenHLC {
                            if pageHLC > currentMax { maxSeenHLC = pageHLC }
                        } else {
                            maxSeenHLC = pageHLC
                        }
                    }

                    let outcome = try SyncApplier.applyRow(
                        entity: item.entity,
                        entityId: entityId,
                        row: row,
                        clocks: clocks,
                        in: db
                    )
                    if outcome.staged {
                        deferredUpserts.append(PendingUpsert(
                            entity: item.entity,
                            entityId: entityId,
                            row: row,
                            clocks: clocks,
                            serverSeq: item.serverSeq
                        ))
                    } else {
                        try SyncApplier.deleteStagedRow(entity: item.entity, entityId: entityId, in: db)
                        if outcome.didChangeLocalData {
                            changed = true
                        }
                    }
                }
            }

            // Retry deferred rows from this page (parents may have arrived later in the same page)
            // and persist any still-blocked rows to `syncStaging`.
            for pending in deferredUpserts {
                try SyncApplier.stageRow(
                    entity: pending.entity,
                    entityId: pending.entityId,
                    row: pending.row,
                    clocks: pending.clocks,
                    serverSeq: pending.serverSeq,
                    now: now,
                    in: db
                )
            }

            if try SyncApplier.retryStagedRows(in: db) {
                changed = true
            }

            if let memberships = response.memberships {
                if try Self.reconcileMemberships(memberships, in: db) {
                    changed = true
                }
            }

            if let maxSeenHLC {
                try HLC.receive(maxSeenHLC, in: db, now: now)
            }

            if !isBackfill {
                try Self.savePullCursors(nextCursors, in: db)
            }
            return (rowCount, changed, nextCursors)
        }
    }

    private static func reconcileMemberships(_ memberships: [SyncPullMembership], in db: Database) throws -> Bool {
        var changed = false
        let meMemberId = try String.fetchOne(db, sql: "SELECT id FROM member WHERE isMe = 1 AND deletedAt IS NULL")

        struct ExistingMembership {
            let projectId: String
            let role: String
        }
        let existingRows = try Row.fetchAll(db, sql: "SELECT projectId, role FROM projectMembership").map { row in
            ExistingMembership(projectId: row["projectId"], role: row["role"])
        }
        let existingIds = Set(existingRows.map(\.projectId))
        let incomingIds = Set(memberships.map(\.projectId))

        for m in memberships {
            if existingIds.contains(m.projectId) {
                try db.execute(
                    sql: "UPDATE projectMembership SET scope = ?, role = ? WHERE projectId = ?",
                    arguments: [m.scope, m.role, m.projectId]
                )
            } else {
                let localOwnerId = try String.fetchOne(
                    db,
                    sql: "SELECT ownerId FROM project WHERE id = ?",
                    arguments: [m.projectId]
                )
                let isMine = (m.role == "owner") || (meMemberId != nil && localOwnerId == meMemberId)
                let needsBackfill = !isMine
                try db.execute(
                    sql: """
                        INSERT INTO projectMembership (projectId, scope, role, needsBackfill)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [m.projectId, m.scope, m.role, needsBackfill]
                )
            }
        }

        for old in existingRows where !incomingIds.contains(old.projectId) {
            let localOwnerId = try String.fetchOne(
                db,
                sql: "SELECT ownerId FROM project WHERE id = ?",
                arguments: [old.projectId]
            )
            let isMine = (meMemberId != nil && localOwnerId == meMemberId) || old.role == "owner"
            guard !isMine else { continue }
            if try SyncApplier.applyGone(entity: "project", entityId: old.projectId, in: db) {
                changed = true
            }
            try db.execute(
                sql: "DELETE FROM projectMembership WHERE projectId = ?",
                arguments: [old.projectId]
            )
        }

        return changed
    }

    // MARK: - Authorized HTTP + Refresh

    private func sendAuthorized(method: String, path: String, body: Data?) async throws -> Data {
        let response = try await sendAuthorizedResponse(method: method, path: path, body: body)
        return try validateHTTPResponse(response)
    }

    func sendAuthorizedResponse(method: String, path: String, body: Data?) async throws -> SyncHTTPResponse {
        let initialToken: String
        if let access = tokenStore.accessToken, !access.isEmpty {
            initialToken = access
        } else if let refresh = tokenStore.refreshToken, !refresh.isEmpty {
            initialToken = try await refreshAccessToken(failedAccessToken: nil)
        } else {
            throw SyncError.signedOut
        }

        let firstResponse = try await sendWithNetworkRetryable(
            method: method,
            path: path,
            headers: ["Authorization": "Bearer \(initialToken)"],
            body: body
        )

        if firstResponse.status == 401 {
            let newAccess = try await refreshAccessToken(failedAccessToken: initialToken)
            let retryResponse = try await sendWithNetworkRetryable(
                method: method,
                path: path,
                headers: ["Authorization": "Bearer \(newAccess)"],
                body: body
            )
            if retryResponse.status == 401 {
                tokenStore.accessToken = nil
                tokenStore.refreshToken = nil
                throw SyncError.signedOut
            }
            return retryResponse
        }

        return firstResponse
    }

    private func refreshAccessToken(failedAccessToken: String?) async throws -> String {
        if let current = tokenStore.accessToken, !current.isEmpty,
           let failedAccessToken, current != failedAccessToken {
            return current
        }
        if let existing = inFlightRefresh {
            return try await existing.value
        }

        let task = Task {
            try await self.performTokenRefresh()
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func performTokenRefresh() async throws -> String {
        guard let refreshToken = tokenStore.refreshToken, !refreshToken.isEmpty else {
            tokenStore.accessToken = nil
            throw SyncError.signedOut
        }

        let requestBody = try encoder.encode(AuthRefreshRequest(refreshToken: refreshToken))
        let response = try await sendWithNetworkRetryable(
            method: "POST",
            path: "/auth/refresh",
            headers: [:],
            body: requestBody
        )

        if response.status == 400 || response.status == 401 || response.status == 403 {
            tokenStore.accessToken = nil
            tokenStore.refreshToken = nil
            throw SyncError.signedOut
        }

        let data = try validateHTTPResponse(response)
        let decoded = try decode(AuthRefreshResponse.self, from: data)

        // Persist the rotated refresh token before exposing/using the new access token.
        tokenStore.refreshToken = decoded.refreshToken
        tokenStore.accessToken = decoded.accessToken
        if let avatarUrl = decoded.avatarUrl, !avatarUrl.isEmpty {
            _ = try? await database.writer.write { db in
                try Self.saveMeAvatarUrl(avatarUrl, in: db)
            }
        }
        return decoded.accessToken
    }

    private func sendWithNetworkRetryable(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> SyncHTTPResponse {
        do {
            return try await transport.send(method: method, path: path, headers: headers, body: body)
        } catch let error as SyncError {
            throw error
        } catch {
            throw nextRetryableError(statusCode: nil, message: error.localizedDescription)
        }
    }

    private func validateHTTPResponse(_ response: SyncHTTPResponse) throws -> Data {
        if (200...299).contains(response.status) {
            return response.body
        }
        let bodyText = String(data: response.body, encoding: .utf8) ?? ""
        if response.status == 429 || (500...599).contains(response.status) {
            throw nextRetryableError(statusCode: response.status, message: bodyText)
        }
        throw SyncError.protocolError("HTTP \(response.status): \(bodyText)")
    }

    func recordRetryableFailure(statusCode: Int?, message: String) -> SyncError {
        nextRetryableError(statusCode: statusCode, message: message)
    }

    private func nextRetryableError(statusCode: Int?, message: String) -> SyncError {
        consecutiveRetryableFailures += 1
        let exponent = Double(max(0, consecutiveRetryableFailures - 1))
        let delay = min(maxBackoffSeconds, baseBackoffSeconds * pow(2.0, exponent))
        return .retryable(retryAfter: delay, statusCode: statusCode, message: message)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SyncError.protocolError("Failed to decode \(T.self): \(error.localizedDescription)")
        }
    }

    // MARK: - First-Login Reconciliation

    private func hasStoredTokens() -> Bool {
        let hasAccess = !(tokenStore.accessToken ?? "").isEmpty
        let hasRefresh = !(tokenStore.refreshToken ?? "").isEmpty
        return hasAccess || hasRefresh
    }

    private static func loadSignedInUserId(in db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM meta WHERE key = ?",
            arguments: [signedInUserIdMetaKey]
        )
    }

    private static func saveSignedInUserId(_ userId: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [signedInUserIdMetaKey, userId]
        )
    }

    private static func loadMeAvatarUrl(in db: Database) throws -> String? {
        let existing = try String.fetchOne(
            db,
            sql: "SELECT value FROM meta WHERE key = ?",
            arguments: [meAvatarUrlMetaKey]
        )
        return (existing?.isEmpty == false) ? existing : nil
    }

    @discardableResult
    private static func saveMeAvatarUrl(_ url: String?, in db: Database) throws -> Bool {
        let normalized = (url?.isEmpty == false) ? url : nil
        let normalizedExisting = try loadMeAvatarUrl(in: db)
        if let normalized {
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [meAvatarUrlMetaKey, normalized]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM meta WHERE key = ?",
                arguments: [meAvatarUrlMetaKey]
            )
        }
        return normalizedExisting != normalized
    }

    /// Saves a client-obtained avatar URL (e.g. from Google Sign-In SDK) only when no server URL is stored.
    public func setMeAvatarUrlIfMissing(_ avatarUrl: String?) async throws {
        guard let avatarUrl, !avatarUrl.isEmpty else { return }
        let didUpdate = try await database.writer.write { db -> Bool in
            if try Self.loadMeAvatarUrl(in: db) == nil {
                return try Self.saveMeAvatarUrl(avatarUrl, in: db)
            }
            return false
        }
        if didUpdate {
            emitChange(SyncSummary(didChangeLocalData: true))
        }
    }

    private static func reconcileFirstLogin(
        auth: AuthLoginResponse,
        in db: Database,
        now: EpochMillis
    ) throws -> Bool {
        let localMe = try MemberRecord.filter(Column("isMe") == true).fetchOne(db)
        let didChange: Bool

        switch (localMe != nil, auth.hasData) {
        case (false, false):
            try LocalDayDoAPI.bootstrap(in: db, now: now)
            didChange = true

        case (false, true):
            didChange = false

        case (true, false):
            didChange = false

        case (true, true):
            guard let localMe else {
                try markLocalProjectInviteOpsLocalOnly(in: db, now: now)
                return false
            }
            let localInbox = try ProjectRecord
                .filter(Column("isInbox") == true)
                .order(Column("createdAt"))
                .fetchOne(db)

            let oldMeId = localMe.id
            let newMeId = auth.meMemberId.flatMap { $0.isEmpty ? nil : $0 }
            let oldInboxId = localInbox?.id
            let newInboxId = auth.inboxProjectId.flatMap { $0.isEmpty ? nil : $0 }

            let remapMe: (from: String, to: String)? = newMeId.flatMap {
                $0 != oldMeId ? (oldMeId, $0) : nil
            }
            let remapInbox: (from: String, to: String)? = oldInboxId.flatMap { oldId in
                newInboxId.flatMap { $0 != oldId ? (oldId, $0) : nil }
            }

            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            if let remapMe {
                try db.execute(sql: "UPDATE member SET id = ? WHERE id = ?", arguments: [remapMe.to, remapMe.from])
                try db.execute(sql: "UPDATE project SET ownerId = ? WHERE ownerId = ?", arguments: [remapMe.to, remapMe.from])
                try db.execute(sql: "UPDATE projectMember SET memberId = ? WHERE memberId = ?", arguments: [remapMe.to, remapMe.from])
                try db.execute(sql: "UPDATE task SET assigneeId = ? WHERE assigneeId = ?", arguments: [remapMe.to, remapMe.from])
                try db.execute(sql: "UPDATE comment SET authorId = ? WHERE authorId = ?", arguments: [remapMe.to, remapMe.from])
            }

            if let remapInbox {
                try db.execute(sql: "UPDATE project SET id = ? WHERE id = ?", arguments: [remapInbox.to, remapInbox.from])
                try db.execute(sql: "UPDATE projectMember SET projectId = ? WHERE projectId = ?", arguments: [remapInbox.to, remapInbox.from])
                try db.execute(sql: "UPDATE projectInvite SET projectId = ? WHERE projectId = ?", arguments: [remapInbox.to, remapInbox.from])
                try db.execute(sql: "UPDATE task SET projectId = ? WHERE projectId = ?", arguments: [remapInbox.to, remapInbox.from])
            }

            if remapMe != nil || remapInbox != nil {
                try remapUnackedChanges(remapMe: remapMe, remapInbox: remapInbox, in: db)
            }

            let droppedAny = try dropUntouchedDefaultLists(in: db)

            if let newMeId {
                try deleteCreateOps(entity: "member", entityId: newMeId, in: db)
            }
            if let newInboxId {
                try deleteCreateOps(entity: "project", entityId: newInboxId, in: db)
            }

            didChange = remapMe != nil || remapInbox != nil || droppedAny
        }

        try markLocalProjectInviteOpsLocalOnly(in: db, now: now)
        return didChange
    }

    private static func markLocalProjectInviteOpsLocalOnly(in db: Database, now: EpochMillis) throws {
        try db.execute(
            sql: """
                UPDATE change
                SET ackedAt = ?, result = 'local-only'
                WHERE entity = 'projectInvite' AND ackedAt IS NULL
                """,
            arguments: [now]
        )
    }

    private static func remapUnackedChanges(
        remapMe: (from: String, to: String)?,
        remapInbox: (from: String, to: String)?,
        in db: Database
    ) throws {
        let decoder = JSONDecoder()
        let unacked = try ChangeRecord
            .filter(Column("ackedAt") == nil)
            .order(Column("seq"))
            .fetchAll(db)

        for change in unacked {
            guard let seq = change.seq else { continue }

            var newEntityId = change.entityId
            switch change.entity {
            case "member":
                if let remapMe, newEntityId == remapMe.from {
                    newEntityId = remapMe.to
                }
            case "project":
                if let remapInbox, newEntityId == remapInbox.from {
                    newEntityId = remapInbox.to
                }
            case "projectMember":
                let parts = newEntityId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    var pid = String(parts[0])
                    var mid = String(parts[1])
                    if let remapInbox, pid == remapInbox.from { pid = remapInbox.to }
                    if let remapMe, mid == remapMe.from { mid = remapMe.to }
                    newEntityId = "\(pid):\(mid)"
                }
            default:
                break
            }

            var newRowJSON = change.row
            var rowChanged = false
            if var rowDict = try? decoder.decode([String: SyncJSONValue].self, from: Data(change.row.utf8)), !rowDict.isEmpty {
                if let remapMe {
                    let meKeys: [String]
                    switch change.entity {
                    case "member": meKeys = ["id"]
                    case "project": meKeys = ["ownerId"]
                    case "projectMember": meKeys = ["memberId"]
                    case "task": meKeys = ["assigneeId"]
                    case "comment": meKeys = ["authorId"]
                    default: meKeys = []
                    }
                    for key in meKeys where rowDict[key]?.stringValue == remapMe.from {
                        rowDict[key] = .string(remapMe.to)
                        rowChanged = true
                    }
                }
                if let remapInbox {
                    let inboxKeys: [String]
                    switch change.entity {
                    case "project": inboxKeys = ["id"]
                    case "projectMember", "projectInvite", "task": inboxKeys = ["projectId"]
                    default: inboxKeys = []
                    }
                    for key in inboxKeys where rowDict[key]?.stringValue == remapInbox.from {
                        rowDict[key] = .string(remapInbox.to)
                        rowChanged = true
                    }
                }
                if rowChanged {
                    let encoded = try Outbox.encoder.encode(rowDict)
                    newRowJSON = String(data: encoded, encoding: .utf8)!
                }
            }

            if newEntityId != change.entityId || rowChanged {
                try db.execute(
                    sql: "UPDATE change SET entityId = ?, row = ? WHERE seq = ?",
                    arguments: [newEntityId, newRowJSON, seq]
                )
            }
        }
    }

    private static func dropUntouchedDefaultLists(in db: Database) throws -> Bool {
        let meId = try MemberRecord.filter(Column("isMe") == true).fetchOne(db)?.id
        let meCreateAt = try meId.flatMap { id in
            try ChangeRecord
                .filter(Column("entity") == "member" && Column("entityId") == id)
                .order(Column("seq"))
                .fetchAll(db)
                .first(where: { isCreateOp($0) })?
                .at
        }
        guard let bootstrapAt = meCreateAt else { return false }

        let decoder = JSONDecoder()
        let projects = try ProjectRecord
            .filter(Column("isInbox") == false && Column("deletedAt") == nil)
            .fetchAll(db)

        var referencedProjectIds = Set(
            try String.fetchAll(db, sql: "SELECT DISTINCT projectId FROM task")
        )
        let taskChanges = try ChangeRecord
            .filter(Column("entity") == "task")
            .fetchAll(db)
        for tc in taskChanges {
            if let rowDict = try? decoder.decode([String: SyncJSONValue].self, from: Data(tc.row.utf8)),
               let pid = rowDict["projectId"]?.stringValue {
                referencedProjectIds.insert(pid)
            }
        }

        let allProjectMemberChanges = try ChangeRecord
            .filter(Column("entity") == "projectMember")
            .fetchAll(db)

        var droppedAny = false
        for project in projects {
            let matchesDefault = LocalDayDoAPI.defaultLists.contains { name, color in
                project.name == name && project.color == color
            }
            guard matchesDefault else { continue }
            guard !referencedProjectIds.contains(project.id) else { continue }

            let projectChanges = try ChangeRecord
                .filter(Column("entity") == "project" && Column("entityId") == project.id)
                .order(Column("seq"))
                .fetchAll(db)
            guard projectChanges.count == 1,
                  isCreateOp(projectChanges[0]),
                  projectChanges[0].at == bootstrapAt else { continue }

            let prefix = "\(project.id):"
            let pmChanges = allProjectMemberChanges.filter { $0.entityId.hasPrefix(prefix) }
            if pmChanges.count > 1 || pmChanges.contains(where: { !isCreateOp($0) }) {
                continue
            }

            let inviteCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM projectInvite WHERE projectId = ?",
                arguments: [project.id]
            ) ?? 0
            if inviteCount > 0 {
                continue
            }

            try db.execute(
                sql: "DELETE FROM change WHERE entity = 'project' AND entityId = ? AND ackedAt IS NULL",
                arguments: [project.id]
            )
            for pmc in pmChanges where pmc.ackedAt == nil {
                if let seq = pmc.seq {
                    try db.execute(sql: "DELETE FROM change WHERE seq = ?", arguments: [seq])
                }
            }
            try db.execute(
                sql: "DELETE FROM projectMember WHERE projectId = ?",
                arguments: [project.id]
            )
            try db.execute(
                sql: "DELETE FROM project WHERE id = ?",
                arguments: [project.id]
            )
            droppedAny = true
        }

        return droppedAny
    }

    private static func isCreateOp(_ change: ChangeRecord) -> Bool {
        guard change.op == "upsert", change.fields.contains("createdAt") else { return false }
        switch change.entity {
        case "projectMember":
            return change.fields.contains("projectId") && change.fields.contains("memberId")
        case "tag":
            return change.fields.contains("name")
        default:
            return change.fields.contains("id")
        }
    }

    private static func deleteCreateOps(entity: String, entityId: String, in db: Database) throws {
        let ops = try ChangeRecord
            .filter(Column("entity") == entity && Column("entityId") == entityId && Column("ackedAt") == nil)
            .order(Column("seq"))
            .fetchAll(db)
        for op in ops where isCreateOp(op) {
            if let seq = op.seq {
                try db.execute(sql: "DELETE FROM change WHERE seq = ?", arguments: [seq])
            }
        }
    }

    // MARK: - Cursor Meta Persistence

    static func loadPullCursors(in db: Database) throws -> [String: Int64] {
        guard let raw = try String.fetchOne(
            db,
            sql: "SELECT value FROM meta WHERE key = ?",
            arguments: [pullCursorsMetaKey]
        ) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Int64].self, from: Data(raw.utf8))) ?? [:]
    }

    static func savePullCursors(_ cursors: [String: Int64], in db: Database) throws {
        let data = try Outbox.encoder.encode(cursors)
        let json = String(data: data, encoding: .utf8)!
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [pullCursorsMetaKey, json]
        )
    }
}
