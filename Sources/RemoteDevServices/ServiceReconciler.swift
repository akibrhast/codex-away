@MainActor
public final class ServiceReconciler {
    private let services: [any ManagedService]

    public init(services: [any ManagedService]) {
        self.services = services
    }

    public func reconcile(
        desiredRemoteState: Bool,
        reason: String,
        initialObservations: [ServiceObservation]? = nil
    ) async -> ReconciliationReport {
        var operations: [ServiceOperationResult] = []
        let resolvedInitialObservations: [ServiceObservation]
        if let suppliedObservations = initialObservations {
            resolvedInitialObservations = suppliedObservations
        } else {
            resolvedInitialObservations = await inspectServices()
        }

        if desiredRemoteState {
            await startServices(
                reason: reason,
                initialObservations: resolvedInitialObservations,
                operations: &operations
            )
        } else {
            await stopServices(
                reason: reason,
                initialObservations: resolvedInitialObservations,
                operations: &operations
            )
        }

        let observations = await inspectServices()
        return ReconciliationReport(
            desiredRemoteState: desiredRemoteState,
            reason: reason,
            observations: observations,
            operations: operations
        )
    }

    public func inspectServices() async -> [ServiceObservation] {
        var observations: [ServiceObservation] = []
        for service in services {
            observations.append(
                ServiceObservation(
                    serviceID: service.id,
                    required: service.required,
                    health: await service.inspect()
                )
            )
        }
        return observations
    }

    private func startServices(
        reason: String,
        initialObservations: [ServiceObservation],
        operations: inout [ServiceOperationResult]
    ) async {
        for (service, observation) in zip(services, initialObservations) {
            switch observation.health {
            case .healthy, .starting:
                continue
            case .stopped, .unhealthy:
                do {
                    try await service.start(reason: reason)
                    operations.append(
                        .success(
                            serviceID: service.id,
                            required: service.required,
                            operation: .start
                        )
                    )
                } catch {
                    operations.append(
                        .failure(
                            serviceID: service.id,
                            required: service.required,
                            operation: .start,
                            message: String(describing: error)
                        )
                    )
                    if service.required { return }
                }
            }
        }
    }

    private func stopServices(
        reason: String,
        initialObservations: [ServiceObservation],
        operations: inout [ServiceOperationResult]
    ) async {
        for (service, observation) in zip(services, initialObservations) {
            switch observation.health {
            case .stopped:
                continue
            case .starting, .healthy, .unhealthy:
                do {
                    try await service.stop(reason: reason)
                    operations.append(
                        .success(
                            serviceID: service.id,
                            required: service.required,
                            operation: .stop
                        )
                    )
                } catch {
                    operations.append(
                        .failure(
                            serviceID: service.id,
                            required: service.required,
                            operation: .stop,
                            message: String(describing: error)
                        )
                    )
                }
            }
        }
    }
}

public struct ServiceObservation: Equatable, Sendable {
    public let serviceID: String
    public let required: Bool
    public let health: ServiceHealth
}

public struct ServiceOperationResult: Equatable, Sendable {
    public let serviceID: String
    public let required: Bool
    public let operation: ServiceOperationError.Operation
    public let failure: String?

    public static func success(
        serviceID: String,
        required: Bool,
        operation: ServiceOperationError.Operation
    ) -> ServiceOperationResult {
        ServiceOperationResult(
            serviceID: serviceID,
            required: required,
            operation: operation,
            failure: nil
        )
    }

    public static func failure(
        serviceID: String,
        required: Bool,
        operation: ServiceOperationError.Operation,
        message: String
    ) -> ServiceOperationResult {
        ServiceOperationResult(
            serviceID: serviceID,
            required: required,
            operation: operation,
            failure: message
        )
    }
}

public struct ReconciliationReport: Equatable, Sendable {
    public let desiredRemoteState: Bool
    public let reason: String
    public let observations: [ServiceObservation]
    public let operations: [ServiceOperationResult]

    public var requiredServicesHealthy: Bool {
        Self.requiredServicesHealthy(observations)
    }

    public static func requiredServicesHealthy(_ observations: [ServiceObservation]) -> Bool {
        observations.filter(\.required).allSatisfy { $0.health == .healthy }
    }

    public var requiredFailure: String? {
        if let requiredOperationFailure { return requiredOperationFailure }
        for observation in observations where observation.required {
            switch observation.health {
            case .healthy:
                continue
            case .stopped:
                return "\(observation.serviceID) is stopped"
            case .starting:
                return "\(observation.serviceID) is still starting"
            case let .unhealthy(message):
                return "\(observation.serviceID) is unhealthy: \(message)"
            }
        }
        return nil
    }

    public var requiredOperationFailure: String? {
        operations.first(where: { $0.required && $0.failure != nil })?.failure
    }
}
