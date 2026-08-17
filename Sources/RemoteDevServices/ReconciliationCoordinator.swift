import Foundation

@MainActor
public final class ReconciliationCoordinator {
    private struct Request: Equatable {
        let revision: UInt64
        let desiredRemoteState: Bool
        let reason: String
    }

    private let reconciler: ServiceReconciler
    private let recoveryPolicy: RecoveryPolicy
    private let sleeper: any RecoverySleeping
    private let exitMonitor: any ProcessExitMonitoring
    private let logger: ServiceLogger

    private var revision: UInt64 = 0
    private var desiredRemoteState = false
    private var activeDesiredState: Bool?
    private var pendingRequest: Request?
    private var worker: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var auditTask: Task<Void, Never>?
    private var stableHealthTask: Task<Void, Never>?
    private var processMonitorTasks: [Task<Void, Never>] = []
    private var monitorGeneration: UInt64 = 0
    private var policyGeneration: UInt64 = 0
    private var recoveryAttempts = 0

    public private(set) var lifecycle = RemoteLifecycleSnapshot(
        phase: .off,
        reason: "controller initialized",
        failure: nil,
        revision: 0
    )

    public init(
        reconciler: ServiceReconciler,
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy(),
        sleeper: any RecoverySleeping = SystemRecoverySleeper(),
        exitMonitor: any ProcessExitMonitoring = DarwinProcessExitMonitor(),
        logger: @escaping ServiceLogger = { _ in }
    ) {
        self.reconciler = reconciler
        self.recoveryPolicy = recoveryPolicy
        self.sleeper = sleeper
        self.exitMonitor = exitMonitor
        self.logger = logger
    }

    @discardableResult
    public func submit(desiredRemoteState: Bool, reason: String) -> UInt64 {
        if self.desiredRemoteState != desiredRemoteState {
            recoveryAttempts = 0
            policyGeneration &+= 1
        }
        self.desiredRemoteState = desiredRemoteState
        if !desiredRemoteState {
            cancelRecoveryWork()
        } else {
            retryTask?.cancel()
            retryTask = nil
            cancelMonitoring()
        }
        return enqueue(desiredRemoteState: desiredRemoteState, reason: reason)
    }

    public func isCurrent(revision candidate: UInt64) -> Bool {
        candidate == revision
    }

    public func waitUntilIdle() async {
        await worker?.value
    }

    private func enqueue(desiredRemoteState: Bool, reason: String) -> UInt64 {
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

        pendingRequest = request
        startWorkerIfNeeded()
        return revision
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
            complete(request: request, inProgress: inProgress, report: report)
        }
        activeDesiredState = nil
        worker = nil
        if pendingRequest != nil {
            startWorkerIfNeeded()
        }
    }

    private func complete(
        request: Request,
        inProgress: RemoteLifecycleSnapshot,
        report: ReconciliationReport
    ) {
        guard request.desiredRemoteState else {
            transition(to: RemoteLifecycleEvaluator.complete(inProgress: inProgress, report: report))
            return
        }

        if report.requiredServicesHealthy {
            let wasRecovering = lifecycle.phase == .recovering || recoveryAttempts > 0
            transition(to: RemoteLifecycleEvaluator.complete(inProgress: inProgress, report: report))
            if wasRecovering { logger("recovery succeeded") }
            armMonitoring(report.observations)
            scheduleStableHealthReset()
            return
        }

        recoveryAttempts += 1
        stableHealthTask?.cancel()
        stableHealthTask = nil
        let failure = report.requiredFailure ?? "required services are not healthy"
        if recoveryAttempts >= recoveryPolicy.maximumAttempts {
            transition(
                to: RemoteLifecycleSnapshot(
                    phase: .error,
                    reason: request.reason,
                    failure: failure,
                    revision: request.revision
                )
            )
            logger("recovery exhausted after \(recoveryAttempts) attempts")
            return
        }

        transition(
            to: RemoteLifecycleSnapshot(
                phase: .recovering,
                reason: request.reason,
                failure: failure,
                revision: request.revision
            )
        )
        scheduleRetry(afterFailedAttempt: recoveryAttempts)
    }

    private func scheduleRetry(afterFailedAttempt attempt: Int) {
        let delay = recoveryPolicy.backoff(afterFailedAttempt: attempt)
        logger("recovery attempt \(attempt)/\(recoveryPolicy.maximumAttempts) failed; retrying in \(delay)s")
        retryTask?.cancel()
        retryTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.desiredRemoteState else { return }
            self.retryTask = nil
            let nextAttempt = self.recoveryAttempts + 1
            self.logger("recovery attempt \(nextAttempt)/\(self.recoveryPolicy.maximumAttempts)")
            _ = self.enqueue(
                desiredRemoteState: true,
                reason: "automatic recovery attempt \(nextAttempt)"
            )
        }
    }

    private func armMonitoring(_ observations: [ServiceObservation]) {
        cancelMonitoring()
        monitorGeneration &+= 1
        let generation = monitorGeneration

        for observation in observations where observation.required {
            guard let identity = observation.processIdentity else { continue }
            let events = exitMonitor.events(for: identity.processIdentifier)
            processMonitorTasks.append(
                Task { [weak self] in
                    for await _ in events {
                        guard let self else { return }
                        self.requiredProcessExited(
                            serviceID: observation.serviceID,
                            identity: identity,
                            generation: generation
                        )
                        return
                    }
                }
            )
        }

        auditTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: self?.recoveryPolicy.healthAuditInterval ?? 0)
            } catch {
                return
            }
            guard let self,
                  self.desiredRemoteState,
                  generation == self.monitorGeneration
            else { return }
            self.cancelMonitoring()
            _ = self.enqueue(desiredRemoteState: true, reason: "scheduled health audit")
        }
    }

    private func requiredProcessExited(
        serviceID: String,
        identity: ProcessIdentity,
        generation: UInt64
    ) {
        guard desiredRemoteState, generation == monitorGeneration else { return }
        logger("required service exited: \(serviceID) (pid \(identity.processIdentifier))")
        cancelMonitoring()
        _ = enqueue(desiredRemoteState: true, reason: "\(serviceID) process exited")
    }

    private func scheduleStableHealthReset() {
        guard recoveryAttempts > 0, stableHealthTask == nil else { return }
        let generation = policyGeneration
        stableHealthTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: self?.recoveryPolicy.stableHealthInterval ?? 0)
            } catch {
                return
            }
            guard let self,
                  self.desiredRemoteState,
                  generation == self.policyGeneration
            else { return }
            self.recoveryAttempts = 0
            self.stableHealthTask = nil
            self.logger("recovery counter reset after stable health")
        }
    }

    private func cancelMonitoring() {
        monitorGeneration &+= 1
        auditTask?.cancel()
        auditTask = nil
        processMonitorTasks.forEach { $0.cancel() }
        processMonitorTasks.removeAll()
    }

    private func cancelRecoveryWork() {
        cancelMonitoring()
        retryTask?.cancel()
        retryTask = nil
        stableHealthTask?.cancel()
        stableHealthTask = nil
        recoveryAttempts = 0
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
