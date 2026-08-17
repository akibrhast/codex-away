import Foundation

@MainActor
public final class ReconciliationCoordinator {
    private struct Request: Equatable {
        let revision: UInt64
        let desiredRemoteState: Bool
        let reason: String
    }

    private let reconciler: ServiceReconciler
    private var revision: UInt64 = 0
    private var activeDesiredState: Bool?
    private var pendingRequest: Request?
    private var worker: Task<Void, Never>?

    public init(reconciler: ServiceReconciler) {
        self.reconciler = reconciler
    }

    @discardableResult
    public func submit(desiredRemoteState: Bool, reason: String) -> UInt64 {
        revision &+= 1
        let request = Request(
            revision: revision,
            desiredRemoteState: desiredRemoteState,
            reason: reason
        )

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
            await reconciler.reconcile(
                desiredRemoteState: request.desiredRemoteState,
                reason: request.reason
            )
        }
        activeDesiredState = nil
        worker = nil
        if pendingRequest != nil {
            startWorkerIfNeeded()
        }
    }
}
