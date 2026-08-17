import XCTest
@testable import RemoteDevServices

@MainActor
final class CaffeinateServiceTests: XCTestCase {
    func testStoppedServiceStartsCaffeinateOnce() throws {
        let process = MockLongRunningProcess(processIdentifier: 73)
        let factory = MockLongRunningProcessFactory(processes: [process])
        var logs: [String] = []
        let service = CaffeinateService(processFactory: factory, logger: { logs.append($0) })

        try service.start(reason: "test")
        try service.start(reason: "duplicate")

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(process.starts.count, 1)
        XCTAssertEqual(process.starts.first?.0, "/usr/bin/caffeinate")
        XCTAssertEqual(process.starts.first?.1, ["-s"])
        XCTAssertEqual(service.inspect(), .healthy)
        XCTAssertEqual(logs, ["caffeinate started (pid 73)"])
    }

    func testStopTerminatesOwnedProcess() throws {
        let process = MockLongRunningProcess()
        let service = CaffeinateService(
            processFactory: MockLongRunningProcessFactory(processes: [process]),
            logger: { _ in }
        )
        try service.start(reason: "test")

        try service.stop(reason: "unlock")

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(service.inspect(), .stopped)
    }

    func testStopIsHarmlessWhenAlreadyStopped() throws {
        let process = MockLongRunningProcess()
        let service = CaffeinateService(
            processFactory: MockLongRunningProcessFactory(processes: [process]),
            logger: { _ in }
        )

        try service.stop(reason: "already stopped")

        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(service.inspect(), .stopped)
    }

    func testLaunchFailureReportsUnhealthyState() {
        let process = MockLongRunningProcess()
        process.startError = MockProcessError.launchFailed
        let service = CaffeinateService(
            processFactory: MockLongRunningProcessFactory(processes: [process]),
            logger: { _ in }
        )

        XCTAssertThrowsError(try service.start(reason: "test"))
        XCTAssertEqual(service.inspect(), .unhealthy("launchFailed"))
    }
}
