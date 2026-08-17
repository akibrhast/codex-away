import XCTest
@testable import RemoteDevServices

@MainActor
final class ServiceReconcilerTests: XCTestCase {
    func testDesiredOnStartsStoppedServicesInOrder() async {
        let first = MockManagedService(id: "first", health: .stopped)
        let second = MockManagedService(id: "second", health: .stopped)
        let reconciler = ServiceReconciler(services: [first, second])

        let report = await reconciler.reconcile(desiredRemoteState: true, reason: "lock")

        XCTAssertEqual(first.events, ["inspect", "start:lock", "inspect"])
        XCTAssertEqual(second.events, ["inspect", "start:lock", "inspect"])
        XCTAssertTrue(report.requiredServicesHealthy)
    }

    func testRequiredStartFailureStopsLaterServices() async {
        let first = MockManagedService(id: "required", health: .stopped)
        first.startError = MockProcessError.launchFailed
        let second = MockManagedService(id: "later", health: .stopped)
        let reconciler = ServiceReconciler(services: [first, second])

        let report = await reconciler.reconcile(desiredRemoteState: true, reason: "lock")

        XCTAssertEqual(first.events, ["inspect", "start:lock", "inspect"])
        XCTAssertEqual(second.events, ["inspect", "inspect"])
        XCTAssertFalse(report.requiredServicesHealthy)
        XCTAssertNotNil(report.requiredFailure)
    }

    func testOptionalStartFailureContinuesToLaterServices() async {
        let first = MockManagedService(id: "optional", required: false, health: .stopped)
        first.startError = MockProcessError.launchFailed
        let second = MockManagedService(id: "later", health: .stopped)
        let reconciler = ServiceReconciler(services: [first, second])

        let report = await reconciler.reconcile(desiredRemoteState: true, reason: "lock")

        XCTAssertEqual(second.events, ["inspect", "start:lock", "inspect"])
        XCTAssertTrue(report.requiredServicesHealthy)
    }

    func testDesiredOffAttemptsEveryActiveServiceDespiteFailure() async {
        let first = MockManagedService(id: "first", health: .healthy)
        first.stopError = MockProcessError.launchFailed
        let second = MockManagedService(id: "second", health: .unhealthy("failed"))
        let reconciler = ServiceReconciler(services: [first, second])

        let report = await reconciler.reconcile(desiredRemoteState: false, reason: "unlock")

        XCTAssertEqual(first.events, ["inspect", "stop:unlock", "inspect"])
        XCTAssertEqual(second.events, ["inspect", "stop:unlock", "inspect"])
        XCTAssertNotNil(report.requiredOperationFailure)
    }

    func testHealthyAndStoppedServicesRequireNoAction() async {
        let healthy = MockManagedService(id: "healthy", health: .healthy)
        let stopped = MockManagedService(id: "stopped", health: .stopped)

        _ = await ServiceReconciler(services: [healthy]).reconcile(
            desiredRemoteState: true,
            reason: "test"
        )
        _ = await ServiceReconciler(services: [stopped]).reconcile(
            desiredRemoteState: false,
            reason: "test"
        )

        XCTAssertEqual(healthy.events, ["inspect", "inspect"])
        XCTAssertEqual(stopped.events, ["inspect", "inspect"])
    }
}
