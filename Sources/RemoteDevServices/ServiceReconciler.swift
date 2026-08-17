@MainActor
public final class ServiceReconciler {
    private let services: [any ManagedService]

    public init(services: [any ManagedService]) {
        self.services = services
    }

    public func reconcile(desiredRemoteState: Bool, reason: String) {
        if desiredRemoteState {
            startServices(reason: reason)
        } else {
            stopServices(reason: reason)
        }
    }

    private func startServices(reason: String) {
        for service in services {
            switch service.inspect() {
            case .healthy, .starting:
                continue
            case .stopped, .unhealthy:
                do {
                    try service.start(reason: reason)
                } catch {
                    if service.required {
                        return
                    }
                }
            }
        }
    }

    private func stopServices(reason: String) {
        for service in services {
            switch service.inspect() {
            case .stopped:
                continue
            case .starting, .healthy, .unhealthy:
                try? service.stop(reason: reason)
            }
        }
    }
}
