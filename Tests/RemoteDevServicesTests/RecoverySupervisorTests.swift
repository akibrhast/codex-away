import XCTest
@testable import RemoteDevServices

@MainActor
final class RecoverySupervisorTests: XCTestCase {
    func testExactProcessExitTriggersAutomaticRecovery() async {
        let identity = makeIdentity(pid: 900)
        let service = MockManagedService(id: "codex", health: .healthy)
        service.processIdentity = identity
        let monitor = MockProcessExitMonitor()
        let sleeper = ControlledRecoverySleeper()
        let coordinator = makeCoordinator(
            service: service,
            sleeper: sleeper,
            monitor: monitor
        )
        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()

        service.health = .stopped
        service.processIdentity = nil
        monitor.emit(processIdentifier: identity.processIdentifier)
        monitor.emit(processIdentifier: identity.processIdentifier)
        await waitUntil { service.events.contains("start:codex process exited") }
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.lifecycle.phase, .ready)
        XCTAssertEqual(service.health, .healthy)
        XCTAssertEqual(
            service.events.filter { $0.hasPrefix("start:") }.count,
            1
        )
    }

    func testFailuresUseExponentialBackoffAndStopAtLimit() async {
        let service = MockManagedService(id: "codex", health: .stopped)
        service.startError = MockProcessError.launchFailed
        let sleeper = ControlledRecoverySleeper()
        let coordinator = makeCoordinator(service: service, sleeper: sleeper)

        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.lifecycle.phase, .recovering)
        await waitUntil { sleeper.intervals.contains(1) }

        XCTAssertTrue(sleeper.resumeFirst(interval: 1))
        await waitUntil { service.events.filter { $0.hasPrefix("start:") }.count == 2 }
        await coordinator.waitUntilIdle()
        await waitUntil { sleeper.intervals.contains(2) }

        XCTAssertTrue(sleeper.resumeFirst(interval: 2))
        await waitUntil { service.events.filter { $0.hasPrefix("start:") }.count == 3 }
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.lifecycle.phase, .error)
        XCTAssertEqual(sleeper.intervals.filter { $0 == 1 || $0 == 2 }, [1, 2])
    }

    func testUnlockCancelsPendingBackoffAndPreventsRestart() async {
        let service = MockManagedService(id: "codex", health: .stopped)
        service.startError = MockProcessError.launchFailed
        let sleeper = ControlledRecoverySleeper()
        let coordinator = makeCoordinator(service: service, sleeper: sleeper)

        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()
        await waitUntil { sleeper.intervals.contains(1) }
        let startsBeforeUnlock = service.events.filter { $0.hasPrefix("start:") }.count

        coordinator.submit(desiredRemoteState: false, reason: "unlock")
        await coordinator.waitUntilIdle()
        XCTAssertFalse(sleeper.resumeFirst(interval: 1))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(coordinator.lifecycle.phase, .off)
        XCTAssertEqual(
            service.events.filter { $0.hasPrefix("start:") }.count,
            startsBeforeUnlock
        )
    }

    func testScheduledHealthyAuditDoesNotRestartService() async {
        let service = MockManagedService(id: "codex", health: .healthy)
        let sleeper = ControlledRecoverySleeper()
        let coordinator = makeCoordinator(service: service, sleeper: sleeper)
        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()
        await waitUntil { sleeper.intervals.contains(100) }

        XCTAssertTrue(sleeper.resumeFirst(interval: 100))
        await waitUntil { coordinator.lifecycle.reason == "scheduled health audit" }
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.lifecycle.phase, .ready)
        XCTAssertFalse(service.events.contains { $0.hasPrefix("start:") })
    }

    func testProcessExitAfterPolicyOffIsIgnored() async {
        let identity = makeIdentity(pid: 901)
        let service = MockManagedService(id: "codex", health: .healthy)
        service.processIdentity = identity
        let monitor = MockProcessExitMonitor()
        let sleeper = ControlledRecoverySleeper()
        let coordinator = makeCoordinator(
            service: service,
            sleeper: sleeper,
            monitor: monitor
        )
        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()
        coordinator.submit(desiredRemoteState: false, reason: "AC disconnected")
        await coordinator.waitUntilIdle()
        let startsBeforeEvent = service.events.filter { $0.hasPrefix("start:") }.count

        monitor.emit(processIdentifier: identity.processIdentifier)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(coordinator.lifecycle.phase, .off)
        XCTAssertEqual(
            service.events.filter { $0.hasPrefix("start:") }.count,
            startsBeforeEvent
        )
    }

    func testStableHealthResetsBackoffSequence() async {
        let service = MockManagedService(id: "codex", health: .healthy)
        let sleeper = ControlledRecoverySleeper()
        let coordinator = makeCoordinator(service: service, sleeper: sleeper)
        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()

        service.health = .stopped
        service.startError = MockProcessError.launchFailed
        coordinator.submit(desiredRemoteState: true, reason: "failure")
        await coordinator.waitUntilIdle()
        await waitUntil { sleeper.intervals.filter { $0 == 1 }.count == 1 }

        service.startError = nil
        XCTAssertTrue(sleeper.resumeFirst(interval: 1))
        await waitUntil { coordinator.lifecycle.phase == .ready }
        await coordinator.waitUntilIdle()
        await waitUntil { sleeper.intervals.contains(200) }
        XCTAssertTrue(sleeper.resumeFirst(interval: 200))
        for _ in 0..<10 { await Task.yield() }

        service.health = .stopped
        service.startError = MockProcessError.launchFailed
        coordinator.submit(desiredRemoteState: true, reason: "later failure")
        await coordinator.waitUntilIdle()
        await waitUntil { sleeper.intervals.filter { $0 == 1 }.count == 2 }

        XCTAssertEqual(coordinator.lifecycle.phase, .recovering)
    }

    private func makeCoordinator(
        service: MockManagedService,
        sleeper: ControlledRecoverySleeper,
        monitor: MockProcessExitMonitor = MockProcessExitMonitor()
    ) -> ReconciliationCoordinator {
        ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [service]),
            recoveryPolicy: RecoveryPolicy(
                healthAuditInterval: 100,
                maximumAttempts: 3,
                initialBackoff: 1,
                backoffMultiplier: 2,
                maximumBackoff: 4,
                stableHealthInterval: 200
            ),
            sleeper: sleeper,
            exitMonitor: monitor
        )
    }

    @discardableResult
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition was not met")
        return false
    }
}
