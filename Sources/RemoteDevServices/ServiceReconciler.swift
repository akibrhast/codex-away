@MainActor
public final class ServiceReconciler {
    private let services: [any ManagedService]

    public init(services: [any ManagedService]) {
        self.services = services
    }

    public func reconcile(desiredRemoteState: Bool, reason: String) async {
        if desiredRemoteState {
            await startServices(reason: reason)
        } else {
            await stopServices(reason: reason)
        }
    }

    private func startServices(reason: String) async {
        for service in services {
            switch await service.inspect() {
            case .healthy, .starting:
                continue
            case .stopped, .unhealthy:
                do {
                    try await service.start(reason: reason)
                } catch {
                    if service.required {
                        return
                    }
                }
            }
        }
    }

    private func stopServices(reason: String) async {
        for service in services {
            switch await service.inspect() {
            case .stopped:
                continue
            case .starting, .healthy, .unhealthy:
                try? await service.stop(reason: reason)
            }
        }
    }
}
