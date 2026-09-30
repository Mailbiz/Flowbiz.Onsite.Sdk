import Foundation
import Network

protocol ReachabilityMonitor {
    func start(onNetworkAvailable: @escaping @Sendable () -> Void)

    func stop()
}

final class PathMonitorReachability: ReachabilityMonitor, @unchecked Sendable {

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var wasSatisfied = false

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
