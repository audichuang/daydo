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

    public let database: AppDatabase
    private let transport: any SyncTransport
    private let tokenStore: any SyncTokenStore
    private let clock: Clock
    private let pushBatchSize: Int
    private let pullLimit: Int
    private let baseBackoffSeconds: TimeInterval
    private let maxBackoffSeconds: TimeInterval

    private var inFlightSync: Task<SyncSummary, Error>?
    private var inFlightRefresh: Task<String, Error>?
    private var consecutiveRetryableFailures: Int = 0
    private var continuations: [UUID: AsyncStream<SyncSummary>.Continuation] = [:]

    private let encoder = Outbox.encoder
    private let decoder = JSONDecoder()

    public init(
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

    /// Runs push followed by pull. Concurrent callers join the in-flight sync cycle.
    @discardableResult
    public func syncNow() async throws -> SyncSummary {
        if let existing = inFlightSync {
            return try await existing.value
        }
        let task = Task {
            try await self.performSyncCycle()
        }
        inFlightSync = task
        defer { inFlightSync = nil }
        return try await task.value
    }

    private func performSyncCycle() async throws -> SyncSummary {
        var pushProgress = PushProgress()
        var pullProgress = PullProgress()
        defer {
            let summary = makeSummary(push: pushProgress, pull: pullProgress)
            if summary.didChangeLocalData {
                emitChange(summary)
            }
        }

        try await performPush(&pushProgress)
        try await performPull(&pullProgress)

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

    private func performPush(_ progress: inout PushProgress) async throws {
        let batchLimit = pushBatchSize

        while true {
            let (deviceId, batch) = try await database.writer.write { db -> (String, [ChangeRecord]) in
                let devId = try HLC.ensureDeviceId(in: db)
                let rows = try ChangeRecord
                    .filter(Column("ackedAt") == nil)
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

    private func performPull(_ progress: inout PullProgress) async throws {
        var cursors = try await database.writer.read { db in
            try Self.loadPullCursors(in: db)
        }

        while true {
            let requestData = try encoder.encode(SyncPullRequest(cursors: cursors, limit: pullLimit))
            let responseData = try await sendAuthorized(method: "POST", path: "/sync/pull", body: requestData)
            let response = try decode(SyncPullResponse.self, from: responseData)

            let now = clock.now().epochMillis
            let (pageRowCount, pageChanged, updatedCursors) = try await database.writer.write { db -> (Int, Bool, [String: Int64]) in
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

                var rowCount = 0
                var changed = false
                var nextCursors = try Self.loadPullCursors(in: db)
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
                        let outcome = try SyncApplier.applyRow(
                            entity: "member",
                            entityId: entityId,
                            row: memberRow,
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

                if let maxSeenHLC {
                    try HLC.receive(maxSeenHLC, in: db, now: now)
                }

                try Self.savePullCursors(nextCursors, in: db)
                return (rowCount, changed, nextCursors)
            }

            cursors = updatedCursors
            progress.pulledCount += pageRowCount
            if pageChanged {
                progress.didChangeLocalData = true
            }

            if !response.scopes.contains(where: { $0.hasMore }) {
                break
            }
        }
    }

    // MARK: - Authorized HTTP + Refresh

    private func sendAuthorized(method: String, path: String, body: Data?) async throws -> Data {
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
            return try validateHTTPResponse(retryResponse)
        }

        return try validateHTTPResponse(firstResponse)
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
