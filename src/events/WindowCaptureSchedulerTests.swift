import XCTest

final class WindowCaptureSchedulerTests: XCTestCase {
    func testSlotsStayOccupiedUntilCaptureCallbacks() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 2)
        var started = [Int]()
        var completions = [Int: () -> Void]()
        for key in 0..<20 {
            scheduler.submit(key) { done in
                started.append(key)
                completions[key] = done
            }
        }
        XCTAssertEqual(started, [0, 1])
        XCTAssertEqual(scheduler.activeCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 18)
        completions[0]?()
        XCTAssertEqual(started, [0, 1, 2])
        XCTAssertEqual(scheduler.activeCount, 2)
    }

    func testSameWindowNeverOverlapsAndOnlyLatestPendingRuns() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 2)
        var finishFirst: (() -> Void)?
        var versions = [Int]()
        scheduler.submit(1) { done in finishFirst = done }
        for version in 1...100 {
            scheduler.submit(1) { done in versions.append(version); done() }
        }
        XCTAssertEqual(scheduler.activeCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)
        finishFirst?()
        XCTAssertEqual(versions, [100])
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testDeliveredPreviewInvalidatesPendingDuplicateBeforeSlotDrains() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        var finishFirst: (() -> Void)?
        var hasCachedPreview = false
        var starts = 0
        scheduler.submit(1, isValid: { !hasCachedPreview }) { done in
            starts += 1
            finishFirst = { hasCachedPreview = true; done() }
        }
        scheduler.submit(1, isValid: { !hasCachedPreview }) { done in starts += 1; done() }
        finishFirst?()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testVisibleRequestsPrecedeBackgroundRequests() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        var first: (() -> Void)?
        var order = [Int]()
        scheduler.submit(0) { first = $0 }
        scheduler.submit(1, priority: 0) { done in order.append(1); done() }
        scheduler.submit(2, priority: 2) { done in order.append(2); done() }
        scheduler.submit(3, priority: 2) { done in order.append(3); done() }
        first?()
        XCTAssertEqual(order, [2, 3, 1])
    }

    func testInvalidPendingSessionIsDiscardedWithoutStartingCapture() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        var first: (() -> Void)?
        var valid = true
        var starts = 0
        scheduler.submit(0) { first = $0 }
        scheduler.submit(1, isValid: { valid }) { done in starts += 1; done() }
        valid = false
        scheduler.discardInvalidPending()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.activeCount, 1)
        first?()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testValidityIsRecheckedWhenSlotBecomesAvailable() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        var first: (() -> Void)?
        var valid = true
        var started = false
        scheduler.submit(0) { first = $0 }
        scheduler.submit(1, isValid: { valid }) { done in started = true; done() }
        valid = false
        first?()
        XCTAssertFalse(started)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testDuplicateOldCallbackCannotReleaseNewCaptureSlot() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        var first: (() -> Void)?
        var second: (() -> Void)?
        scheduler.submit(1) { first = $0 }
        scheduler.submit(1) { second = $0 }
        first?()
        first?()
        XCTAssertEqual(scheduler.activeCount, 1)
        second?()
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testErrorCallbackReleasesSlot() {
        enum CaptureError: Error { case failed }
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        var systemCallback: ((Result<Int, Error>) -> Void)?
        var nextStarted = false
        scheduler.submit(1) { done in systemCallback = { _ in done() } }
        scheduler.submit(2) { done in nextStarted = true; done() }
        systemCallback?(.failure(CaptureError.failed))
        XCTAssertTrue(nextStarted)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testCallbackFromBackgroundQueueReleasesSlotOnMain() {
        let scheduler = WindowCaptureScheduler<Int>(limit: 1)
        let completed = expectation(description: "next request on main")
        var callback: (() -> Void)?
        scheduler.submit(1) { callback = $0 }
        scheduler.submit(2) { done in
            XCTAssertTrue(Thread.isMainThread)
            done()
            completed.fulfill()
        }
        let finish = callback!
        DispatchQueue.global().async { finish() }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testSessionScopeRejectsDismissalAndNextInvocation() {
        let first = NSObject()
        let second = NSObject()
        let scope = WindowCaptureScope(session: first, requiresSession: true)
        XCTAssertTrue(scope.permits(currentSession: first, backgroundCaptureEnabled: false))
        XCTAssertFalse(scope.permits(currentSession: nil, backgroundCaptureEnabled: true))
        XCTAssertFalse(scope.permits(currentSession: second, backgroundCaptureEnabled: true))
    }

    func testCancellationRejectsARequestEvenIfSameSessionIsStillRetained() {
        let session = NSObject()
        let scope = WindowCaptureScope(session: session, requiresSession: true)
        scope.cancel()
        XCTAssertTrue(scope.isCancelled)
        XCTAssertFalse(scope.permits(currentSession: session, backgroundCaptureEnabled: true))
    }

    func testScopeDoesNotRetainSessionOrItsPreviewFrames() {
        var session: NSObject? = NSObject()
        let weakSession = WeakCaptureTestObject(session)
        let scope = WindowCaptureScope(session: session, requiresSession: true)
        session = nil
        XCTAssertNil(weakSession.value)
        XCTAssertFalse(scope.permits(currentSession: nil, backgroundCaptureEnabled: true))
    }

    func testBackgroundScopeRequiresBackgroundPreference() {
        let scope = WindowCaptureScope(session: nil, requiresSession: false)
        XCTAssertTrue(scope.permits(currentSession: nil, backgroundCaptureEnabled: true))
        XCTAssertFalse(scope.permits(currentSession: nil, backgroundCaptureEnabled: false))
        XCTAssertFalse(scope.permits(currentSession: NSObject(), backgroundCaptureEnabled: false))
        XCTAssertFalse(scope.permits(currentSession: NSObject(), backgroundCaptureEnabled: true))
    }

    func testFirstThrottleTailUsesLatestGeometryRequest() {
        let latest = WindowCaptureLatestRequests<String, Int>()
        var tail: (() -> Void)?
        var delivered = [Int]()
        let throttle: (@escaping () -> Void) -> Void = { if tail == nil { tail = $0 } }
        latest.submit("window", 100, schedule: throttle) { delivered.append($0) }
        latest.submit("window", 200, schedule: throttle) { delivered.append($0) }
        latest.submit("window", 300, schedule: throttle) { delivered.append($0) }
        tail?()
        XCTAssertEqual(delivered, [300])
    }

    func testDismissedThrottleTailCannotStealNextSessionsRequest() {
        let latest = WindowCaptureLatestRequests<String, Int>()
        var oldTail: (() -> Void)?
        var nextTail: (() -> Void)?
        var delivered = [Int]()
        latest.submit("session1-window", 1, schedule: { oldTail = $0 }) { delivered.append($0) }
        latest.discard { $0 == 1 }
        latest.submit("session2-window", 2, schedule: { nextTail = $0 }) { delivered.append($0) }
        oldTail?()
        XCTAssertTrue(delivered.isEmpty)
        nextTail?()
        XCTAssertEqual(delivered, [2])
    }

    func testDiscardedThrottleTailReleasesItsRequest() {
        let latest = WindowCaptureLatestRequests<String, NSObject>()
        var tail: (() -> Void)?
        var request: NSObject? = NSObject()
        let weakRequest = WeakCaptureTestObject(request)
        latest.submit("window", request!, schedule: { tail = $0 }) { _ in XCTFail("discarded request") }
        request = nil
        XCTAssertNotNil(weakRequest.value)
        latest.discard { _ in true }
        XCTAssertNil(weakRequest.value)
        tail?()
    }

    func testMissingRequestIncludedInDiscoveryDoesNotRetry() {
        let request = NSObject()
        let batch = WindowCaptureDiscoveryBatch([1: request])
        let resolved = batch.resolve([1: request], querySucceeded: true, isAvailable: { _ in false }, isValid: { _ in true })
        XCTAssertTrue(resolved.ready.isEmpty)
        XCTAssertTrue(resolved.retry.isEmpty)
    }

    func testLateMissingRequestGetsExactlyOneFreshDiscovery() {
        let first = NSObject()
        let late = NSObject()
        let batch = WindowCaptureDiscoveryBatch([1: first])
        let resolved = batch.resolve([1: first, 2: late], querySucceeded: true,
            isAvailable: { $0 == 1 }, isValid: { _ in true })
        XCTAssertTrue(resolved.ready[1] === first)
        XCTAssertTrue(resolved.retry[2] === late)
        XCTAssertEqual(resolved.retry.count, 1)
        let followUp = WindowCaptureDiscoveryBatch(resolved.retry)
        let stillMissing = followUp.resolve(resolved.retry, querySucceeded: true,
            isAvailable: { _ in false }, isValid: { _ in true })
        XCTAssertTrue(stillMissing.retry.isEmpty)
    }

    func testNewerRequestForSameMissingWindowGetsFreshDiscovery() {
        let old = NSObject()
        let newer = NSObject()
        let batch = WindowCaptureDiscoveryBatch([1: old])
        let resolved = batch.resolve([1: newer], querySucceeded: true, isAvailable: { _ in false }, isValid: { _ in true })
        XCTAssertTrue(resolved.retry[1] === newer)
        let followUp = WindowCaptureDiscoveryBatch(resolved.retry)
        let found = followUp.resolve(resolved.retry, querySucceeded: true, isAvailable: { _ in true }, isValid: { _ in true })
        XCTAssertTrue(found.ready[1] === newer)
        XCTAssertTrue(found.retry.isEmpty)
    }

    func testLateRequestAlreadyPresentInDiscoveryIsCapturedWithoutAnotherQuery() {
        let late = NSObject()
        let batch = WindowCaptureDiscoveryBatch<Int, NSObject>([:])
        let resolved = batch.resolve([1: late], querySucceeded: true, isAvailable: { _ in true }, isValid: { _ in true })
        XCTAssertTrue(resolved.ready[1] === late)
        XCTAssertTrue(resolved.retry.isEmpty)
    }

    func testInvalidLateSessionIsNotRetriedByDiscovery() {
        let session = NSObject()
        let lateScope = WindowCaptureScope(session: session, requiresSession: true)
        let batch = WindowCaptureDiscoveryBatch<Int, WindowCaptureScope>([:])
        lateScope.cancel()
        let resolved = batch.resolve([1: lateScope], querySucceeded: true, isAvailable: { _ in false },
            isValid: { $0.permits(currentSession: session, backgroundCaptureEnabled: false) })
        XCTAssertTrue(resolved.ready.isEmpty)
        XCTAssertTrue(resolved.retry.isEmpty)
    }

    func testDiscoveryFailureDoesNotAutomaticallyRetryLateRequests() {
        let late = NSObject()
        let batch = WindowCaptureDiscoveryBatch<Int, NSObject>([:])
        let resolved = batch.resolve([1: late], querySucceeded: false, isAvailable: { _ in true }, isValid: { _ in true })
        XCTAssertTrue(resolved.ready.isEmpty)
        XCTAssertTrue(resolved.retry.isEmpty)
    }
}

private final class WeakCaptureTestObject {
    weak var value: NSObject?

    init(_ value: NSObject?) { self.value = value }
}
