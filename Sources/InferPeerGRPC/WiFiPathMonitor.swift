import Foundation
import Network

final class WiFiPathMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kodlabs.inferpeer.grpc-path")
    private var monitor: NWPathMonitor?
    private var generation: UUID?

    func start(
        interfaceName: String,
        onDisallowedPath: @escaping @Sendable () -> Void
    ) {
        let state = lock.withLock { () -> (NWPathMonitor, UUID)? in
            guard monitor == nil else { return nil }
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let generation = UUID()
            self.monitor = monitor
            self.generation = generation
            return (monitor, generation)
        }
        guard let (monitor, generation) = state else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.isCurrent(generation) else { return }
            guard Self.isAllowed(path, interfaceName: interfaceName) else {
                onDisallowedPath()
                return
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        let monitor = lock.withLock { () -> NWPathMonitor? in
            defer {
                self.monitor = nil
                generation = nil
            }
            return self.monitor
        }
        monitor?.cancel()
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        lock.withLock { self.generation == generation }
    }

    private static func isAllowed(_ path: NWPath, interfaceName: String) -> Bool {
        path.status == .satisfied
            && path.usesInterfaceType(.wifi)
            && path.availableInterfaces.contains {
                $0.type == .wifi && $0.name == interfaceName
            }
    }
}
