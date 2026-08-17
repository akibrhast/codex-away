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
            ["inspect", "start:lock", "inspect", "stop:unlock"]
        )
        XCTAssertEqual(service.health, .stopped)
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
        XCTAssertEqual(service.events, ["inspect", "start:first", "inspect"])
    }
}
