import Foundation

public enum RemoteLifecyclePhase: String, Equatable, Sendable {
    case off = "OFF"
    case starting = "STARTING"
    case ready = "READY"
    case recovering = "RECOVERING"
    case error = "ERROR"
}

public struct RemoteLifecycleSnapshot: Equatable, Sendable {
    public let phase: RemoteLifecyclePhase
    public let reason: String
    public let failure: String?
    public let revision: UInt64
    public let transitionedAt: Date

    public init(
        phase: RemoteLifecyclePhase,
        reason: String,
        failure: String?,
        revision: UInt64,
        transitionedAt: Date = Date()
    ) {
        self.phase = phase
        self.reason = reason
        self.failure = failure
        self.revision = revision
        self.transitionedAt = transitionedAt
    }
}

public enum RemoteLifecycleEvaluator {
    public static func begin(
        previous: RemoteLifecycleSnapshot,
        desiredRemoteState: Bool,
        reason: String,
        revision: UInt64,
        requiredServicesHealthy: Bool? = nil,
        at date: Date = Date()
    ) -> RemoteLifecycleSnapshot {
        guard desiredRemoteState else {
            return RemoteLifecycleSnapshot(
                phase: .off,
                reason: reason,
                failure: nil,
                revision: revision,
                transitionedAt: date
            )
        }

        let phase: RemoteLifecyclePhase = switch previous.phase {
        case .ready:
            requiredServicesHealthy == false ? .recovering : .ready
        case .recovering:
            .recovering
        case .off, .starting, .error:
            .starting
        }
        return RemoteLifecycleSnapshot(
            phase: phase,
            reason: reason,
            failure: nil,
            revision: revision,
            transitionedAt: date
        )
    }

    public static func complete(
        inProgress: RemoteLifecycleSnapshot,
        report: ReconciliationReport,
        at date: Date = Date()
    ) -> RemoteLifecycleSnapshot {
        guard report.desiredRemoteState else {
            return RemoteLifecycleSnapshot(
                phase: .off,
                reason: report.reason,
                failure: report.requiredOperationFailure,
                revision: inProgress.revision,
                transitionedAt: date
            )
        }

        if report.requiredServicesHealthy {
            return RemoteLifecycleSnapshot(
                phase: .ready,
                reason: report.reason,
                failure: nil,
                revision: inProgress.revision,
                transitionedAt: date
            )
        }
        return RemoteLifecycleSnapshot(
            phase: .error,
            reason: report.reason,
            failure: report.requiredFailure ?? "required services are not healthy",
            revision: inProgress.revision,
            transitionedAt: date
        )
    }
}
