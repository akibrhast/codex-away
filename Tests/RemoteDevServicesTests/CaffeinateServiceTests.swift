import XCTest
@testable import RemoteDevServices

@MainActor
final class CaffeinateServiceTests: XCTestCase {
    func testStoppedServiceStartsOnceAndRecordsIdentity() async throws {
        let process = MockLongRunningProcess(processIdentifier: 73)
        let factory = MockLongRunningProcessFactory(processes: [process])
        let inspector = MockProcessInspector()
        inspector.identities[73] = process.identity
        let ownership = MockOwnershipStore()
        var logs: [String] = []
        let service = makeService(
            factory: factory,
            inspector: inspector,
            ownership: ownership,
            logger: { logs.append($0) }
        )

        try await service.start(reason: "test")
        try await service.start(reason: "duplicate")

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(process.starts.first?.0, "/usr/bin/caffeinate")
        XCTAssertEqual(process.starts.first?.1, ["-s"])
        let health = await service.inspect()
        XCTAssertEqual(health, .healthy)
        XCTAssertEqual(ownership.records["caffeinate"]?.processIdentity, process.identity)
        XCTAssertEqual(logs, ["caffeinate started (pid 73)"])
    }

    func testOwnedProcessIsReAdoptedAfterControllerRestart() async throws {
        let identity = makeIdentity(pid: 88)
        let ownership = MockOwnershipStore()
        ownership.records["caffeinate"] = ownedRecord(identity)
        let inspector = MockProcessInspector()
        inspector.identities[88] = identity
        let signaler = MockProcessSignaler()
        let factory = MockLongRunningProcessFactory(processes: [MockLongRunningProcess()])
        let service = makeService(
            factory: factory,
            inspector: inspector,
            signaler: signaler,
            ownership: ownership
        )

        let health = await service.inspect()
        XCTAssertEqual(health, .healthy)
        try await service.start(reason: "restart")
        try await service.stop(reason: "unlock")

        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(signaler.terminatedPIDs, [88])
        XCTAssertFalse(ownership.records["caffeinate"]?.owned ?? true)
    }

    func testStopTerminatesOwnedInMemoryProcess() async throws {
        let process = MockLongRunningProcess()
        let inspector = MockProcessInspector()
        inspector.identities[42] = process.identity
        let service = makeService(
            factory: MockLongRunningProcessFactory(processes: [process]),
            inspector: inspector
        )
        try await service.start(reason: "test")

        try await service.stop(reason: "unlock")

        XCTAssertEqual(process.terminateCount, 1)
        let health = await service.inspect()
        XCTAssertEqual(health, .stopped)
    }

    func testStalePIDIsRejectedAndNeverSignaled() async throws {
        let identity = makeIdentity(pid: 51)
        let ownership = MockOwnershipStore()
        ownership.records["caffeinate"] = ownedRecord(identity)
        let signaler = MockProcessSignaler()
        let service = makeService(
            inspector: MockProcessInspector(),
            signaler: signaler,
            ownership: ownership
        )

        let health = await service.inspect()
        XCTAssertEqual(
            health,
            .unhealthy("controller-owned caffeinate process is not running")
        )
        try await service.stop(reason: "unlock")

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
        XCTAssertFalse(ownership.records["caffeinate"]?.owned ?? true)
    }

    func testReusedPIDWithDifferentStartTimeIsNeverSignaled() async throws {
        let expected = makeIdentity(pid: 52, seconds: 100)
        let replacement = makeIdentity(pid: 52, seconds: 200)
        let ownership = MockOwnershipStore()
        ownership.records["caffeinate"] = ownedRecord(expected)
        let inspector = MockProcessInspector()
        inspector.identities[52] = replacement
        let signaler = MockProcessSignaler()
        let service = makeService(
            inspector: inspector,
            signaler: signaler,
            ownership: ownership
        )

        try await service.stop(reason: "unlock")

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
    }

    func testUnownedCaffeinateIsNotAdoptedOrStopped() async throws {
        let inspector = MockProcessInspector()
        inspector.identities[99] = makeIdentity(pid: 99)
        let signaler = MockProcessSignaler()
        let service = makeService(inspector: inspector, signaler: signaler)

        try await service.stop(reason: "unlock")

        let health = await service.inspect()
        XCTAssertEqual(health, .stopped)
        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
    }

    func testLaunchFailureReportsUnhealthyStateWithoutOwnership() async {
        let process = MockLongRunningProcess()
        process.startError = MockProcessError.launchFailed
        let ownership = MockOwnershipStore()
        let service = makeService(
            factory: MockLongRunningProcessFactory(processes: [process]),
            ownership: ownership
        )

        do { try await service.start(reason: "test"); XCTFail("expected launch failure") } catch {}
        let health = await service.inspect()
        XCTAssertEqual(health, .unhealthy("launchFailed"))
        XCTAssertNil(ownership.records["caffeinate"])
    }

    private func makeService(
        factory: MockLongRunningProcessFactory = MockLongRunningProcessFactory(
            processes: [MockLongRunningProcess()]
        ),
        inspector: MockProcessInspector = MockProcessInspector(),
        signaler: MockProcessSignaler = MockProcessSignaler(),
        ownership: MockOwnershipStore = MockOwnershipStore(),
        logger: @escaping ServiceLogger = { _ in }
    ) -> CaffeinateService {
        CaffeinateService(
            processFactory: factory,
            processInspector: inspector,
            processSignaler: signaler,
            ownershipStore: ownership,
            stopTimeout: 0.01,
            logger: logger
        )
    }

    private func ownedRecord(_ identity: ProcessIdentity) -> ServiceOwnershipRecord {
        ServiceOwnershipRecord(
            owned: true,
            processIdentity: identity,
            lastSuccessfulAction: .start
        )
    }
}
