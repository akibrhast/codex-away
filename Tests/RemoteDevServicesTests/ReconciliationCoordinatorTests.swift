import XCTest
@testable import RemoteDevServices

@MainActor
final class ReconciliationCoordinatorTests: XCTestCase {
    func testLatestStateRunsAfterActiveReconciliation() async {
        let service = MockManagedService(id: "service", health: .stopped)
        service.startDelay = .milliseconds(50)
        let coordinator = ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [service])
        )

        coordinator.submit(desiredRemoteState: true, reason: "lock")
        try? await Task.sleep(for: .milliseconds(10))
        coordinator.submit(desiredRemoteState: false, reason: "unlock")
        await coordinator.waitUntilIdle()

        XCTAssertEqual(
            service.events,
            ["inspect", "start:lock", "inspect", "inspect", "stop:unlock", "inspect"]
        )
        XCTAssertEqual(service.health, .stopped)
        XCTAssertEqual(coordinator.lifecycle.phase, .off)
        XCTAssertEqual(coordinator.lifecycle.reason, "unlock")
    }

    func testPendingRequestsCoalesceToNewestState() async {
        let service = MockManagedService(id: "service", health: .stopped)
        service.startDelay = .milliseconds(50)
        let coordinator = ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [service])
        )

        coordinator.submit(desiredRemoteState: true, reason: "first")
        try? await Task.sleep(for: .milliseconds(10))
        coordinator.submit(desiredRemoteState: false, reason: "stale")
        let finalRevision = coordinator.submit(desiredRemoteState: true, reason: "latest")
        await coordinator.waitUntilIdle()

        XCTAssertTrue(coordinator.isCurrent(revision: finalRevision))
        XCTAssertEqual(service.health, .healthy)
        XCTAssertEqual(
            service.events,
            ["inspect", "start:first", "inspect", "inspect", "inspect"]
        )
        XCTAssertEqual(coordinator.lifecycle.phase, .ready)
        XCTAssertEqual(coordinator.lifecycle.reason, "latest")
    }

    func testRequiredFailureTransitionsToErrorAndLogsFailure() async {
        let service = MockManagedService(id: "codex", health: .stopped)
        service.startError = MockProcessError.launchFailed
        var logs: [String] = []
        let coordinator = ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [service]),
            logger: { logs.append($0) }
        )

        coordinator.submit(desiredRemoteState: true, reason: "lock")
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.lifecycle.phase, .error)
        XCTAssertEqual(coordinator.lifecycle.reason, "lock")
        XCTAssertNotNil(coordinator.lifecycle.failure)
        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs[0].contains("OFF → STARTING"))
        XCTAssertTrue(logs[1].contains("STARTING → ERROR"))
        XCTAssertTrue(logs[1].contains("failure:"))
    }

    func testHealthyAuditRemainsReadyWithoutFalseRecoveryTransition() async {
        let service = MockManagedService(id: "codex", health: .healthy)
        var logs: [String] = []
        let coordinator = ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [service]),
            logger: { logs.append($0) }
        )

        coordinator.submit(desiredRemoteState: true, reason: "initial")
        await coordinator.waitUntilIdle()
        coordinator.submit(desiredRemoteState: true, reason: "health audit")
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.lifecycle.phase, .ready)
        XCTAssertFalse(logs.contains { $0.contains("RECOVERING") })
    }

    func testFailedRecoveryTransitionsFromReadyThroughRecoveringToError() async {
        let service = MockManagedService(id: "codex", health: .healthy)
        var logs: [String] = []
        let coordinator = ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [service]),
            logger: { logs.append($0) }
        )
        coordinator.submit(desiredRemoteState: true, reason: "initial")
        await coordinator.waitUntilIdle()

        service.health = .unhealthy("exited")
        service.startError = MockProcessError.launchFailed
        coordinator.submit(desiredRemoteState: true, reason: "health audit")
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.lifecycle.phase, .error)
        XCTAssertNotNil(coordinator.lifecycle.failure)
        XCTAssertTrue(logs.contains { $0.contains("READY → RECOVERING") })
        XCTAssertTrue(logs.contains { $0.contains("RECOVERING → ERROR") })
    }
}
