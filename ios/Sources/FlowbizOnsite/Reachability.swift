import Foundation
import Network

/// Network-restoration seam (SPEC §9 retry trigger). Implementations invoke
/// the callback when connectivity (re)appears; the facade wires it to
/// `FlushController.requestFlush(.networkRestored)` in Slice 4. Injectable
/// so tests use a fake.
protocol ReachabilityMonitor {
    /// Starts monitoring; the callback may fire on the monitor queue. Idempotent.
    func start(onNetworkAvailable: @escaping @Sendable () -> Void)

    /// Stops monitoring. Safe to call when not started.
    func stop()
}

/// Production monitor over `NWPathMonitor` (SPEC §1), running on the SDK's
/// serial queue. Fires only on transitions **to** satisfied — including the
/// initial path update when the network is already up; that one extra flush
/// request is harmless (an empty-queue drain is a no-op).
///
/// Never throws (SPEC §3); a failed monitor degrades to "no reachability
/// trigger" — the other retry triggers still drain the queue.
final class PathMonitorReachability: ReachabilityMonitor, @unchecked Sendable {

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var wasSatisfied = false

    /// - Parameter queue: the SDK's serial queue.
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(onNetworkAvailable: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            self.lock.lock()
            let fire = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            self.lock.unlock()
            if fire { onNetworkAvailable() }
        }
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        monitor?.cancel()
        monitor = nil
        wasSatisfied = false
    }
}
