import XCTest
@testable import RemoteDevServices

@MainActor
final class ServiceReconcilerTests: XCTestCase {
    func testDesiredOnStartsStoppedServicesInOrder() {
        let first = MockManagedService(id: "first", health: .stopped)
        let second = MockManagedService(id: "second", health: .stopped)
        let reconciler = ServiceReconciler(services: [first, second])

        reconciler.reconcile(desiredRemoteState: true, reason: "lock")

        XCTAssertEqual(first.events, ["inspect", "start:lock"])
        XCTAssertEqual(second.events, ["inspect", "start:lock"])
    }

    func testRequiredStartFailureStopsLaterServices() {
        let first = MockManagedService(id: "required", health: .stopped)
        first.startError = MockProcessError.launchFailed
        let second = MockManagedService(id: "later", health: .stopped)
        let reconciler = ServiceReconciler(services: [first, second])

        reconciler.reconcile(desiredRemoteState: true, reason: "lock")

        XCTAssertEqual(first.events, ["inspect", "start:lock"])
        XCTAssertTrue(second.events.isEmpty)
    }

    func testOptionalStartFailureContinuesToLaterServices() {
        let first = MockManagedService(id: "optional", required: false, health: .stopped)
        first.startError = MockProcessError.launchFailed
        let second = MockManagedService(id: "later", health: .stopped)
        let reconciler = ServiceReconciler(services: [first, second])

        reconciler.reconcile(desiredRemoteState: true, reason: "lock")

        XCTAssertEqual(second.events, ["inspect", "start:lock"])
    }

    func testDesiredOffAttemptsEveryActiveServiceDespiteFailure() {
        let first = MockManagedService(id: "first", health: .healthy)
        first.stopError = MockProcessError.launchFailed
        let second = MockManagedService(id: "second", health: .unhealthy("failed"))
        let reconciler = ServiceReconciler(services: [first, second])

        reconciler.reconcile(desiredRemoteState: false, reason: "unlock")

        XCTAssertEqual(first.events, ["inspect", "stop:unlock"])
        XCTAssertEqual(second.events, ["inspect", "stop:unlock"])
    }

    func testHealthyAndStoppedServicesRequireNoAction() {
        let healthy = MockManagedService(id: "healthy", health: .healthy)
        let stopped = MockManagedService(id: "stopped", health: .stopped)

        ServiceReconciler(services: [healthy]).reconcile(desiredRemoteState: true, reason: "test")
        ServiceReconciler(services: [stopped]).reconcile(desiredRemoteState: false, reason: "test")

        XCTAssertEqual(healthy.events, ["inspect"])
        XCTAssertEqual(stopped.events, ["inspect"])
    }
}
