import XCTest
@testable import DayDo

@MainActor
final class ResidentQueryTests: XCTestCase {
    private struct ScopedKey: Hashable {
        var scope: String
        var revision: Int
    }

    private struct DebouncedKey: Hashable {
        var text: String
        var activeOnly: Bool
        var revision: Int
    }

    private enum SampleError: Error, Equatable {
        case notFound
    }

    @MainActor
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<T, any Error>?
        private var pendingResult: Result<T, any Error>?

        func wait() async throws -> T {
            let enterList: [CheckedContinuation<Void, Never>] = lock.withLock {
                entered = true
                let list = enterWaiters
                enterWaiters.removeAll()
                return list
            }
            for cont in enterList {
                cont.resume()
            }
            return try await withCheckedThrowingContinuation { cont in
                let ready: Result<T, any Error>? = lock.withLock {
                    if let pendingResult {
                        return pendingResult
                    }
                    continuation = cont
                    return nil
                }
                if let ready {
                    cont.resume(with: ready)
                }
            }
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let alreadyEntered = lock.withLock {
                    if entered { return true }
                    enterWaiters.append(cont)
                    return false
                }
                if alreadyEntered {
                    cont.resume()
                }
            }
        }

        func resume(returning value: T) {
            let cont: CheckedContinuation<T, any Error>? = lock.withLock {
                pendingResult = .success(value)
                let c = continuation
                continuation = nil
                return c
            }
            cont?.resume(returning: value)
        }
    }

    func testHiddenKeyPerformsZeroFetches() async {
        let query = ResidentQuery<ScopedKey, [String]>(initialValue: [])
        let fetchCount = Box(0)

        let outcome = await query.run(activeKey: nil) { _ in
            fetchCount.value += 1
            return ["item"]
        }

        if case .skipped = outcome {} else {
            XCTFail("Expected .skipped for nil activeKey, got \(outcome)")
        }
        XCTAssertEqual(fetchCount.value, 0)
        XCTAssertEqual(query.value, [])
        XCTAssertNil(query.loadedKey)
    }

    func testSameKeyDoesNotRefetch() async {
        let query = ResidentQuery<ScopedKey, [String]>(
            initialValue: [],
            isSameQuery: { $0.scope == $1.scope }
        )
        let key = ScopedKey(scope: "today", revision: 1)
        let fetchCount = Box(0)

        let first = await query.run(activeKey: key) { _ in
            fetchCount.value += 1
            return ["a"]
        }
        if case .loaded(let sameQuery) = first {
            XCTAssertFalse(sameQuery, "First load has no prior loadedKey")
        } else {
            XCTFail("Expected .loaded, got \(first)")
        }

        let second = await query.run(activeKey: key) { _ in
            fetchCount.value += 1
            return ["b"]
        }
        if case .skipped = second {} else {
            XCTFail("Expected .skipped on same key, got \(second)")
        }

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(query.value, ["a"])
        XCTAssertEqual(query.loadedKey, key)

        // Switching to hidden key also keeps the loaded value without fetching.
        let hidden = await query.run(activeKey: nil) { _ in
            fetchCount.value += 1
            return ["c"]
        }
        if case .skipped = hidden {} else {
            XCTFail("Expected .skipped when hidden, got \(hidden)")
        }
        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(query.value, ["a"])
    }

    func testStalePredicateClearsValueBeforeFetchResolves() async {
        let query = ResidentQuery<ScopedKey, [String]>(
            initialValue: [],
            isStale: { $0.scope != $1.scope },
            isSameQuery: { $0.scope == $1.scope }
        )
        let keyA = ScopedKey(scope: "work", revision: 1)
        let keyB = ScopedKey(scope: "inbox", revision: 1)
        let keyB2 = ScopedKey(scope: "inbox", revision: 2)

        await query.run(activeKey: keyA) { _ in ["work-task"] }
        XCTAssertEqual(query.value, ["work-task"])
        XCTAssertEqual(query.loadedKey, keyA)

        let gate = Gate<[String]>()
        let appliedSameQuery = Box<Bool?>(nil)
        let switchTask = Task {
            await query.run(activeKey: keyB) { _ in
                try await gate.wait()
            } apply: { sameQuery, commit in
                appliedSameQuery.value = sameQuery
                commit()
            }
        }

        await gate.waitUntilEntered()
        XCTAssertEqual(query.value, [], "Stale predicate must clear old scope rows before fetch resolves")
        XCTAssertNil(query.loadedKey)

        gate.resume(returning: ["inbox-task"])
        let switchOutcome = await switchTask.value
        if case .loaded(let sameQuery) = switchOutcome {
            XCTAssertFalse(sameQuery)
        } else {
            XCTFail("Expected .loaded, got \(switchOutcome)")
        }
        XCTAssertEqual(appliedSameQuery.value, false)
        XCTAssertEqual(query.value, ["inbox-task"])
        XCTAssertEqual(query.loadedKey, keyB)

        // Same scope with bumped revision is NOT stale and reports sameQuery == true.
        let gate2 = Gate<[String]>()
        let reloadTask = Task {
            await query.run(activeKey: keyB2) { _ in
                try await gate2.wait()
            } apply: { sameQuery, commit in
                appliedSameQuery.value = sameQuery
                commit()
            }
        }
        await gate2.waitUntilEntered()
        XCTAssertEqual(query.value, ["inbox-task"], "Non-stale reload keeps previous rows while fetching")
        XCTAssertEqual(query.loadedKey, keyB)

        gate2.resume(returning: ["inbox-task-2"])
        let reloadOutcome = await reloadTask.value
        if case .loaded(let sameQuery) = reloadOutcome {
            XCTAssertTrue(sameQuery)
        } else {
            XCTFail("Expected .loaded, got \(reloadOutcome)")
        }
        XCTAssertEqual(appliedSameQuery.value, true)
        XCTAssertEqual(query.value, ["inbox-task-2"])
    }

    func testDebounceWaits180msOnTestClock() async {
        let clock = TestClock()
        let query = ResidentQuery<DebouncedKey, [String]>(
            initialValue: [],
            clock: clock,
            debounce: { loaded, next in
                guard !next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .zero }
                return loaded?.text == next.text ? .zero : .milliseconds(180)
            }
        )
        let fetchCount = Box(0)

        let firstKey = DebouncedKey(text: "訂位", activeOnly: false, revision: 1)
        let task = Task {
            await query.run(activeKey: firstKey) { key in
                fetchCount.value += 1
                return ["result:\(key.text)"]
            }
        }

        await clock.waitForSleeper()
        await clock.advance(by: .milliseconds(179))
        XCTAssertEqual(fetchCount.value, 0, "Fetch must not run before 180 ms elapses")
        XCTAssertEqual(query.value, [])

        await clock.advance(by: .milliseconds(1))
        let outcome = await task.value
        if case .loaded = outcome {} else {
            XCTFail("Expected .loaded after 180 ms, got \(outcome)")
        }
        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(query.value, ["result:訂位"])
        XCTAssertEqual(query.loadedKey, firstKey)

        // Changing only activeOnly (same text) skips debounce immediately.
        let toggleKey = DebouncedKey(text: "訂位", activeOnly: true, revision: 1)
        await query.run(activeKey: toggleKey) { _ in
            fetchCount.value += 1
            return ["active:訂位"]
        }
        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(query.value, ["active:訂位"])
    }

    func testTwoRequestsForOneKeyFetchOnce() async {
        let query = ResidentQuery<ScopedKey, [String]>(
            initialValue: [],
            isSameQuery: { $0.scope == $1.scope }
        )
        let key = ScopedKey(scope: "cal", revision: 2)
        let gate = Gate<[String]>()
        let fetchCount = Box(0)
        let applyCount = Box(0)

        let req1 = Task {
            await query.run(activeKey: key) { _ in
                fetchCount.value += 1
                return try await gate.wait()
            } apply: { _, commit in
                applyCount.value += 1
                commit()
            }
        }
        await gate.waitUntilEntered()

        let req2 = Task {
            await query.run(activeKey: key) { _ in
                fetchCount.value += 1
                return ["should-not-run"]
            } apply: { _, commit in
                applyCount.value += 1
                commit()
            }
        }
        while query.inFlightWaiterCount < 2 {
            await Task.yield()
        }

        gate.resume(returning: ["shared"])
        let out1 = await req1.value
        let out2 = await req2.value
        if case .loaded = out1 {} else { XCTFail("Expected .loaded for req1, got \(out1)") }
        if case .loaded = out2 {} else { XCTFail("Expected .loaded for req2, got \(out2)") }

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(applyCount.value, 1)
        XCTAssertEqual(query.value, ["shared"])
        XCTAssertEqual(query.loadedKey, key)
        XCTAssertEqual(query.version, 1)
    }

    func testCancelledLoadNeverOverwritesNewerValue() async {
        let query = ResidentQuery<ScopedKey, [String]>(
            initialValue: [],
            isSameQuery: { $0.scope == $1.scope }
        )
        let oldKey = ScopedKey(scope: "old", revision: 1)
        let newKey = ScopedKey(scope: "new", revision: 2)
        let slowGate = Gate<[String]>()

        let oldTask = Task {
            await query.run(activeKey: oldKey) { _ in
                // Deliberately ignores Task.isCancelled and resolves late.
                try await slowGate.wait()
            }
        }
        await slowGate.waitUntilEntered()

        oldTask.cancel()
        let oldOutcome = await oldTask.value
        if case .cancelled = oldOutcome {} else {
            XCTFail("Expected .cancelled for cancelled task, got \(oldOutcome)")
        }

        // Load a newer key while oldTask's fetch is still pending.
        await query.run(activeKey: newKey) { _ in ["newer"] }
        XCTAssertEqual(query.value, ["newer"])
        XCTAssertEqual(query.loadedKey, newKey)

        // Now resolve the old cancelled fetch; it must not overwrite newer state.
        slowGate.resume(returning: ["stale-old"])
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(query.value, ["newer"])
        XCTAssertEqual(query.loadedKey, newKey)
    }

    func testDragMoveAwaitingInFlightTabTaskCancelledByTabSwitchNeitherSticksNorClearsEarly() async {
        let query = ResidentQuery<ScopedKey, [String]>(
            initialValue: [],
            isSameQuery: { $0.scope == $1.scope }
        )
        let beforeKey = ScopedKey(scope: "week", revision: 1)
        let postWriteKey = ScopedKey(scope: "week", revision: 2)

        await query.run(activeKey: beforeKey) { _ in ["before-move"] }
        XCTAssertEqual(query.value, ["before-move"])

        let gate = Gate<[String]>()
        let fetchCount = Box(0)
        let moveToken = UUID()
        let pendingMove = Box<UUID?>(moveToken)

        // 1. Revision-triggered .task(id:) starts the post-write load first.
        let tabTask = Task {
            await query.run(activeKey: postWriteKey) { _ in
                fetchCount.value += 1
                return try await gate.wait()
            }
        }
        await gate.waitUntilEntered()

        // 2. Drag-move Task joins the same in-flight post-write load, then clears pendingMove.
        let moveTask = Task {
            await query.run(activeKey: postWriteKey) { _ in
                fetchCount.value += 1
                return ["duplicate-should-not-run"]
            }
            if pendingMove.value == moveToken {
                pendingMove.value = nil
            }
        }
        while query.inFlightWaiterCount < 2 {
            await Task.yield()
        }

        // 3. Tab switch cancels .task(id:) and passes activeKey = nil while fetch is still in flight.
        tabTask.cancel()
        let tabOutcome = await tabTask.value
        if case .cancelled = tabOutcome {} else {
            XCTFail("Expected .cancelled for tabTask, got \(tabOutcome)")
        }
        let hiddenOutcome = await query.run(activeKey: nil) { _ in
            fetchCount.value += 1
            return []
        }
        if case .skipped = hiddenOutcome {} else {
            XCTFail("Expected .skipped for nil activeKey, got \(hiddenOutcome)")
        }
        await Task.yield()

        // pendingMove must NOT clear early before the in-flight load finishes.
        XCTAssertEqual(pendingMove.value, moveToken, "pendingMove cleared before in-flight load finished")
        XCTAssertEqual(fetchCount.value, 1)

        // 4. In-flight load completes: value updates and moveTask clears pendingMove without sticking.
        gate.resume(returning: ["after-move"])
        await moveTask.value

        XCTAssertNil(pendingMove.value, "pendingMove must clear after the joined load finishes")
        XCTAssertEqual(query.value, ["after-move"])
        XCTAssertEqual(query.loadedKey, postWriteKey)
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testErrorReturnedToCallerWithoutUpdatingLoadedKeyAndResetClearsState() async {
        let query = ResidentQuery<ScopedKey, [String]>(initialValue: [])
        let key1 = ScopedKey(scope: "ok", revision: 1)
        let key2 = ScopedKey(scope: "missing", revision: 1)

        await query.run(activeKey: key1) { _ in ["ok"] }

        let outcome = await query.run(activeKey: key2) { _ in
            throw SampleError.notFound
        }
        if case .failed(let error) = outcome {
            XCTAssertEqual(error as? SampleError, .notFound)
        } else {
            XCTFail("Expected .failed(.notFound), got \(outcome)")
        }
        XCTAssertEqual(query.loadedKey, key1)
        XCTAssertEqual(query.value, ["ok"])

        query.reset()
        XCTAssertEqual(query.value, [])
        XCTAssertNil(query.loadedKey)
    }
}
