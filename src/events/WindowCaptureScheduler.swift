import Foundation

/// Main-thread scheduler for asynchronous captures. A slot lives until the OS callback, not until the
/// submission closure returns. There is at most one active and one latest pending job per key.
final class WindowCaptureScheduler<Key: Hashable> {
    typealias Completion = () -> Void
    typealias Work = (@escaping Completion) -> Void

    private struct Job {
        let key: Key
        let priority: Int
        let order: UInt64
        let isValid: () -> Bool
        let work: Work
    }

    private let limit: Int
    private var pending = [Key: Job]()
    private var active = [Key: UUID]()
    private var order: UInt64 = 0
    private var draining = false

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    var activeCount: Int { active.count }
    var pendingCount: Int { pending.count }

    func submit(_ key: Key, priority: Int = 0, isValid: @escaping () -> Bool = { true }, work: @escaping Work) {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = pending[key]
        order &+= 1
        pending[key] = Job(key: key, priority: priority, order: previous?.order ?? order, isValid: isValid, work: work)
        drain()
    }

    func discardInvalidPending() {
        dispatchPrecondition(condition: .onQueue(.main))
        pending = pending.filter { $0.value.isValid() }
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        discardInvalidPending()
        while active.count < limit {
            let next = pending.values.filter { active[$0.key] == nil }.min {
                $0.priority != $1.priority ? $0.priority > $1.priority : $0.order < $1.order
            }
            guard let job = next else { return }
            pending[job.key] = nil
            guard job.isValid() else { continue }
            let id = UUID()
            active[job.key] = id
            job.work { [weak self] in
                let finish = { self?.finish(job.key, id) }
                if Thread.isMainThread { finish() } else { DispatchQueue.main.async { finish() } }
            }
        }
    }

    private func finish(_ key: Key, _ id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active[key] == id else { return }
        active[key] = nil
        drain()
    }
}

/// Cancels submitted session work without reading mutable switcher state on the capture queue.
final class WindowCaptureScope {
    let id = UUID()
    private weak var session: AnyObject?
    let requiresSession: Bool
    private let lock = NSLock()
    private var cancelled = false

    init(session: AnyObject?, requiresSession: Bool) {
        self.session = session
        self.requiresSession = requiresSession
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func permits(currentSession: AnyObject?, backgroundCaptureEnabled: Bool) -> Bool {
        guard !isCancelled else { return false }
        if requiresSession { return session != nil && session === currentSession }
        return backgroundCaptureEnabled && currentSession == nil
    }
}

/// The existing rate limiter retains its first delayed closure. That closure must fetch the latest
/// request when it fires, rather than retaining the first window geometry and session snapshot.
final class WindowCaptureLatestRequests<Key: Hashable, Request> {
    private var pending = [Key: Request]()

    func submit(_ key: Key, _ request: Request, schedule: (@escaping () -> Void) -> Void, perform: @escaping (Request) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending[key] = request
        schedule { [weak self] in
            guard let request = self?.pending.removeValue(forKey: key) else { return }
            perform(request)
        }
    }

    func discard(where shouldDiscard: (Request) -> Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending = pending.filter { !shouldDiscard($0.value) }
    }
}

/// A content query may have taken its window snapshot before a later request's window existed.
/// Such a request gets one query that includes it; an unchanged missing request does not retry itself.
struct WindowCaptureDiscoveryBatch<Key: Hashable, Request: AnyObject> {
    private let queriedRequests: [Key: Request]

    init(_ requests: [Key: Request]) { queriedRequests = requests }

    func resolve(_ requests: [Key: Request], querySucceeded: Bool, isAvailable: (Key) -> Bool,
                 isValid: (Request) -> Bool) -> (ready: [Key: Request], retry: [Key: Request]) {
        guard querySucceeded else { return ([:], [:]) }
        var ready = [Key: Request]()
        var retry = [Key: Request]()
        for (key, request) in requests where isValid(request) {
            if isAvailable(key) {
                ready[key] = request
            } else if queriedRequests[key] !== request {
                retry[key] = request
            }
        }
        return (ready, retry)
    }
}
