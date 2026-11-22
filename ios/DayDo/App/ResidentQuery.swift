import Foundation
import Observation

/// Coordinates an async query bound to a resident tab:
/// - Skips fetching when the tab is hidden (`activeKey == nil`) or the key is already loaded.
/// - Clears stale state before fetching when `isStale(loadedKey, nextKey)` holds.
/// - Optionally debounces via an injectable clock before calling `fetch`.
/// - Joins an already in-flight request for the same key so concurrent callers share one fetch.
/// - Ignores `CancellationError` and ensures cancelled or superseded loads never overwrite newer data.
@MainActor
@Observable
final class ResidentQuery<Key: Hashable, Value> {
    enum Outcome: Sendable {
        case skipped
        case cancelled
        case loaded(sameQuery: Bool)
        case failed(any Error)
    }

    private(set) var value: Value
    private(set) var loadedKey: Key?
    private(set) var version: Int = 0

    private let initialValue: Value
    private let clock: any Swift.Clock<Duration>
    private let isStale: (Key, Key) -> Bool
    private let isSameQuery: (Key, Key) -> Bool
    private let debounce: (Key?, Key) -> Duration

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var nextFlightId: UInt64 = 0
    @ObservationIgnored private var nextWaiterId: UInt64 = 0
    @ObservationIgnored private var inFlight: ResidentQueryFlight<Key, Outcome>?
    @ObservationIgnored private var flightFetches: [UInt64: @MainActor (Key) async throws -> Value] = [:]
    @ObservationIgnored private var waiterApplies: [UInt64: @MainActor (Bool, @MainActor () -> Void) -> Void] = [:]

    /// Exposed internally for deterministic concurrency tests.
    var inFlightWaiterCount: Int {
        inFlight?.waiterCount ?? 0
    }

    init(
        initialValue: Value,
        clock: any Swift.Clock<Duration> = ContinuousClock(),
        isStale: @escaping (Key, Key) -> Bool = { _, _ in false },
        isSameQuery: @escaping (Key, Key) -> Bool = { _, _ in true },
        debounce: @escaping (Key?, Key) -> Duration = { _, _ in .zero }
    ) {
        self.value = initialValue
        self.initialValue = initialValue
        self.clock = clock
        self.isStale = isStale
        self.isSameQuery = isSameQuery
        self.debounce = debounce
    }

    /// Runs or joins the load for `activeKey`.
    /// Passing `nil` (hidden tab) performs no fetch and leaves loaded state intact.
    @discardableResult
    func run(
        activeKey: Key?,
        fetch: @escaping @MainActor (Key) async throws -> Value,
        apply: (@MainActor (_ sameQuery: Bool, _ commit: @MainActor () -> Void) -> Void)? = nil
    ) async -> Outcome {
        guard let key = activeKey else { return .skipped }
        if Task.isCancelled { return .cancelled }
        if loadedKey == key { return .skipped }

        let flight: ResidentQueryFlight<Key, Outcome>
        if let current = inFlight, current.key == key, !current.isCancelled {
            flight = current
        } else {
            generation += 1
            let gen = generation
            if let previous = inFlight {
                inFlight = nil
                flightFetches.removeValue(forKey: previous.id)
                previous.cancel(with: .cancelled)
            }

            let previousLoadedKey = loadedKey
            if let loaded = previousLoadedKey, isStale(loaded, key) {
                value = initialValue
                loadedKey = nil
                version += 1
            }

            let delay = debounce(previousLoadedKey, key)
            nextFlightId += 1
            let flightId = nextFlightId
            let created = ResidentQueryFlight<Key, Outcome>(id: flightId, key: key)
            inFlight = created
            flightFetches[flightId] = fetch
            let task = Task { @MainActor [weak self] in
                await self?.execute(flight: created, generation: gen, delay: delay)
                created.finish(with: .cancelled)
            }
            created.attach(task: task)
            flight = created
        }

        nextWaiterId += 1
        let waiterId = nextWaiterId
        if let apply {
            waiterApplies[waiterId] = apply
        }
        defer { waiterApplies.removeValue(forKey: waiterId) }
        return await flight.join(waiterId: waiterId, cancelledOutcome: .cancelled)
    }

    /// Resets value and loaded key back to initial state and invalidates any in-flight load.
    func reset() {
        generation += 1
        if let previous = inFlight {
            inFlight = nil
            flightFetches.removeValue(forKey: previous.id)
            previous.cancel(with: .cancelled)
        }
        value = initialValue
        loadedKey = nil
        version += 1
    }

    private func execute(
        flight: ResidentQueryFlight<Key, Outcome>,
        generation gen: UInt64,
        delay: Duration
    ) async {
        defer {
            flightFetches.removeValue(forKey: flight.id)
        }
        guard let fetch = flightFetches.removeValue(forKey: flight.id) else {
            if inFlight?.id == flight.id { inFlight = nil }
            flight.finish(with: .cancelled)
            return
        }

        do {
            if delay > .zero {
                try await clock.sleep(for: delay)
            }
            try Task.checkCancellation()
            guard !flight.isCancelled, generation == gen, inFlight?.id == flight.id else {
                if inFlight?.id == flight.id { inFlight = nil }
                flight.finish(with: .cancelled)
                return
            }

            let fetched = try await fetch(flight.key)

            guard !Task.isCancelled, !flight.isCancelled, generation == gen, inFlight?.id == flight.id else {
                if inFlight?.id == flight.id { inFlight = nil }
                flight.finish(with: .cancelled)
                return
            }

            let sameQuery = loadedKey.map { isSameQuery($0, flight.key) } ?? false
            let outcome = Outcome.loaded(sameQuery: sameQuery)
            guard let claimed = flight.claimCommit(outcome: outcome) else {
                if inFlight?.id == flight.id { inFlight = nil }
                return
            }

            let activeApply = claimed.waiterIds.compactMap { waiterApplies[$0] }.first
            let commit: @MainActor () -> Void = {
                self.value = fetched
                self.loadedKey = flight.key
                self.version += 1
            }
            if let activeApply {
                activeApply(sameQuery, commit)
            } else {
                commit()
            }
            if inFlight?.id == flight.id {
                inFlight = nil
            }
            for cont in claimed.continuations {
                cont.resume(returning: outcome)
            }
        } catch is CancellationError {
            if inFlight?.id == flight.id { inFlight = nil }
            flight.finish(with: .cancelled)
        } catch {
            guard !Task.isCancelled, !flight.isCancelled, generation == gen, inFlight?.id == flight.id else {
                if inFlight?.id == flight.id { inFlight = nil }
                flight.finish(with: .cancelled)
                return
            }
            inFlight = nil
            flight.finish(with: .failed(error))
        }
    }
}

/// Ref-counted in-flight load shared across concurrent callers awaiting the same key.
/// The underlying task is cancelled only when the last active waiter cancels or when
/// the query explicitly supersedes/resets the flight.
private final class ResidentQueryFlight<Key, Outcome: Sendable>: @unchecked Sendable {
    struct ClaimedCommit {
        let waiterIds: [UInt64]
        let continuations: [CheckedContinuation<Outcome, Never>]
    }

    let id: UInt64
    let key: Key

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Outcome, Never>)] = []
    private var completed: Outcome?
    private var cancelled = false

    init(id: UInt64, key: Key) {
        self.id = id
        self.key = key
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    func attach(task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func join(waiterId: UInt64, cancelledOutcome: Outcome) async -> Outcome {
        if Task.isCancelled {
            let taskToCancel: Task<Void, Never>? = lock.withLock {
                if waiters.isEmpty && completed == nil {
                    cancelled = true
                    completed = cancelledOutcome
                    return task
                }
                return nil
            }
            taskToCancel?.cancel()
            return cancelledOutcome
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                let (immediate, taskToCancel): (Outcome?, Task<Void, Never>?) = lock.withLock {
                    if let completed {
                        return (completed, nil)
                    }
                    if Task.isCancelled {
                        if waiters.isEmpty {
                            cancelled = true
                            completed = cancelledOutcome
                            return (cancelledOutcome, task)
                        }
                        return (cancelledOutcome, nil)
                    }
                    waiters.append((id: waiterId, continuation: cont))
                    return (nil, nil)
                }
                taskToCancel?.cancel()
                if let immediate {
                    cont.resume(returning: immediate)
                }
            }
        } onCancel: {
            let (cont, taskToCancel): (CheckedContinuation<Outcome, Never>?, Task<Void, Never>?) = lock.withLock {
                guard let idx = waiters.firstIndex(where: { $0.id == waiterId }) else {
                    return (nil, nil)
                }
                let removed = waiters.remove(at: idx).continuation
                if waiters.isEmpty && completed == nil {
                    cancelled = true
                    completed = cancelledOutcome
                    return (removed, task)
                }
                return (removed, nil)
            }
            cont?.resume(returning: cancelledOutcome)
            taskToCancel?.cancel()
        }
    }

    func claimCommit(outcome: Outcome) -> ClaimedCommit? {
        lock.withLock {
            guard !cancelled, completed == nil else {
                return nil
            }
            completed = outcome
            let ids = waiters.map(\.id)
            let conts = waiters.map(\.continuation)
            waiters.removeAll()
            return ClaimedCommit(waiterIds: ids, continuations: conts)
        }
    }

    func finish(with outcome: Outcome) {
        let waiting: [CheckedContinuation<Outcome, Never>] = lock.withLock {
            guard completed == nil else { return [] }
            completed = outcome
            let conts = waiters.map(\.continuation)
            waiters.removeAll()
            return conts
        }
        for cont in waiting {
            cont.resume(returning: outcome)
        }
    }

    func cancel(with cancelledOutcome: Outcome) {
        let (taskToCancel, waiting): (Task<Void, Never>?, [CheckedContinuation<Outcome, Never>]) = lock.withLock {
            cancelled = true
            let conts: [CheckedContinuation<Outcome, Never>]
            if completed == nil {
                completed = cancelledOutcome
                conts = waiters.map(\.continuation)
                waiters.removeAll()
            } else {
                conts = []
            }
            return (task, conts)
        }
        taskToCancel?.cancel()
        for cont in waiting {
            cont.resume(returning: cancelledOutcome)
        }
    }
}
