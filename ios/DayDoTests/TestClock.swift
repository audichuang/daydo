import Foundation

final class TestClock: Swift.Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }
    }

    private struct Waiter {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleeperWatch {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentOffset: Duration = .zero
    private var nextId: UInt64 = 0
    private var waiters: [Waiter] = []
    private var sleeperWatches: [SleeperWatch] = []

    var now: Instant {
        lock.withLock { Instant(offset: currentOffset) }
    }

    var minimumResolution: Duration { .milliseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = lock.withLock { () -> UInt64 in
            nextId += 1
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                var immediate = false
                var readyWatches: [CheckedContinuation<Void, Never>] = []
                lock.withLock {
                    if deadline <= Instant(offset: currentOffset) || Task.isCancelled {
                        immediate = true
                    } else {
                        waiters.append(Waiter(id: id, deadline: deadline, continuation: cont))
                        let count = waiters.count
                        let remaining = sleeperWatches.filter { $0.targetCount > count }
                        readyWatches = sleeperWatches.filter { $0.targetCount <= count }.map(\.continuation)
                        sleeperWatches = remaining
                    }
                }
                if immediate {
                    if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume()
                    }
                } else {
                    for w in readyWatches {
                        w.resume()
                    }
                }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, any Error>? = lock.withLock {
                if let idx = waiters.firstIndex(where: { $0.id == id }) {
                    return waiters.remove(at: idx).continuation
                }
                return nil
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `count` sleepers are waiting in `sleep(until:)`.
    func waitForSleeper(count: Int = 1) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let alreadyMet = lock.withLock {
                if waiters.count >= count {
                    return true
                }
                sleeperWatches.append(SleeperWatch(targetCount: count, continuation: cont))
                return false
            }
            if alreadyMet {
                cont.resume()
            }
        }
    }

    /// Advances the clock by `duration` and resumes any sleepers whose deadline has passed.
    @MainActor
    func advance(by duration: Duration) async {
        let ready: [CheckedContinuation<Void, any Error>] = lock.withLock {
            currentOffset += duration
            let target = Instant(offset: currentOffset)
            let due = waiters.filter { $0.deadline <= target }.sorted { $0.deadline < $1.deadline }
            waiters.removeAll { $0.deadline <= target }
            return due.map(\.continuation)
        }
        for cont in ready {
            cont.resume()
        }
        await Task.yield()
    }
}
