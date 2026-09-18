import Foundation
import Network

final class WiFiPathMonitor: @unchecked Sendable {
    private static let disallowedPathGracePeriod = DispatchTimeInterval.seconds(1)

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kodlabs.inferpeer.grpc-path")
    private var monitor: NWPathMonitor?
    private var generation: UUID?
    private var enforcementState = WiFiPathEnforcementState()

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
            let isAllowed = Self.isAllowed(path, interfaceName: interfaceName)
            guard let token = self.observe(isAllowed: isAllowed) else { return }
            self.scheduleRevalidation(
                monitor: monitor,
                generation: generation,
                token: token,
                interfaceName: interfaceName,
                onDisallowedPath: onDisallowedPath
            )
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        let monitor = lock.withLock { () -> NWPathMonitor? in
            defer {
                self.monitor = nil
                generation = nil
                enforcementState = WiFiPathEnforcementState()
            }
            return self.monitor
        }
        monitor?.cancel()
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        lock.withLock { self.generation == generation }
    }

    private func observe(isAllowed: Bool) -> UUID? {
        lock.withLock { enforcementState.observe(isAllowed: isAllowed) }
    }

    private func scheduleRevalidation(
        monitor: NWPathMonitor,
        generation: UUID,
        token: UUID,
        interfaceName: String,
        onDisallowedPath: @escaping @Sendable () -> Void
    ) {
        queue.asyncAfter(deadline: .now() + Self.disallowedPathGracePeriod) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let isAllowed = Self.isAllowed(monitor.currentPath, interfaceName: interfaceName)
            guard self.shouldStop(token: token, isAllowed: isAllowed) else { return }
            onDisallowedPath()
        }
    }

    private func shouldStop(token: UUID, isAllowed: Bool) -> Bool {
        lock.withLock {
            if isAllowed {
                _ = enforcementState.observe(isAllowed: true)
                return false
            }
            return enforcementState.confirmDisallowedPath(token: token)
        }
    }

    private static func isAllowed(_ path: NWPath, interfaceName: String) -> Bool {
        path.status == .satisfied
            && path.usesInterfaceType(.wifi)
            && path.availableInterfaces.contains {
                $0.type == .wifi && $0.name == interfaceName
            }
    }
}

struct WiFiPathEnforcementState: Sendable {
    private(set) var hasObservedAllowedPath = false
    private var pendingDisallowedToken: UUID?

    mutating func observe(isAllowed: Bool) -> UUID? {
        if isAllowed {
            hasObservedAllowedPath = true
            pendingDisallowedToken = nil
            return nil
        }
        guard hasObservedAllowedPath, pendingDisallowedToken == nil else { return nil }
        let token = UUID()
        pendingDisallowedToken = token
        return token
    }

    mutating func confirmDisallowedPath(token: UUID) -> Bool {
        guard pendingDisallowedToken == token else { return false }
        pendingDisallowedToken = nil
        return true
    }
}
