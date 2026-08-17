import Foundation

@MainActor
public final class ReconciliationCoordinator {
    private struct Request: Equatable {
        let revision: UInt64
        let desiredRemoteState: Bool
        let reason: String
    }

    private let reconciler: ServiceReconciler
    private let logger: ServiceLogger
    private var revision: UInt64 = 0
    private var activeDesiredState: Bool?
    private var pendingRequest: Request?
    private var worker: Task<Void, Never>?

    public private(set) var lifecycle = RemoteLifecycleSnapshot(
        phase: .off,
        reason: "controller initialized",
        failure: nil,
        revision: 0
    )

    public init(
        reconciler: ServiceReconciler,
        logger: @escaping ServiceLogger = { _ in }
    ) {
        self.reconciler = reconciler
        self.logger = logger
    }

    @discardableResult
    public func submit(desiredRemoteState: Bool, reason: String) -> UInt64 {
        revision &+= 1
        let request = Request(
            revision: revision,
            desiredRemoteState: desiredRemoteState,
            reason: reason
        )

        if !desiredRemoteState {
            transition(
                to: RemoteLifecycleEvaluator.begin(
                    previous: lifecycle,
                    desiredRemoteState: false,
                    reason: reason,
                    revision: revision
                )
            )
        }

        if activeDesiredState == desiredRemoteState, pendingRequest == nil {
            return revision
        }
        pendingRequest = request
        startWorkerIfNeeded()
        return revision
    }

    public func isCurrent(revision candidate: UInt64) -> Bool {
        candidate == revision
    }

    public func waitUntilIdle() async {
        await worker?.value
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let request = pendingRequest {
            pendingRequest = nil
            activeDesiredState = request.desiredRemoteState

            let initialObservations = request.desiredRemoteState
                ? await reconciler.inspectServices()
                : nil
            let inProgress = RemoteLifecycleEvaluator.begin(
                previous: lifecycle,
                desiredRemoteState: request.desiredRemoteState,
                reason: request.reason,
                revision: request.revision,
                requiredServicesHealthy: initialObservations.map(
                    ReconciliationReport.requiredServicesHealthy
                )
            )
            transition(to: inProgress)

            let report = await reconciler.reconcile(
                desiredRemoteState: request.desiredRemoteState,
                reason: request.reason,
                initialObservations: initialObservations
            )
            guard request.revision == revision else { continue }
            transition(
                to: RemoteLifecycleEvaluator.complete(
                    inProgress: inProgress,
                    report: report
                )
            )
        }
        activeDesiredState = nil
        worker = nil
        if pendingRequest != nil {
            startWorkerIfNeeded()
        }
    }

    private func transition(to next: RemoteLifecycleSnapshot) {
        let previous = lifecycle
        lifecycle = next
        guard previous.phase != next.phase || previous.failure != next.failure else { return }

        var message = "lifecycle \(previous.phase.rawValue) → \(next.phase.rawValue): \(next.reason)"
        if let failure = next.failure {
            message += "; failure: \(failure)"
        }
        logger(message)
    }
}
