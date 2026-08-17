import Foundation
import XCTest
@testable import RemoteDevServices

@MainActor
final class CodexRemoteServiceTests: XCTestCase {
    private let executable = "/test/codex"
    private let outputURL = URL(fileURLWithPath: "/test/controller.log")

    func testMissingStateStartsCodexAndWritesOn() throws {
        let runner = MockCommandRunner()
        let store = MockStateStore(state: "unknown")
        var logs: [String] = []
        let service = makeService(runner: runner, store: store, logger: { logs.append($0) })

        try service.start(reason: "screen lock")

        XCTAssertEqual(runner.calls, [
            .init(
                executable: executable,
                arguments: ["remote-control", "start"],
                outputURL: outputURL
            ),
        ])
        XCTAssertEqual(store.writes, ["on"])
        XCTAssertEqual(service.inspect(), .healthy)
        XCTAssertEqual(logs, ["remote control started; trigger: screen lock"])
    }

    func testHealthyServiceSkipsDuplicateStart() throws {
        let runner = MockCommandRunner()
        let store = MockStateStore(state: "on")
        let service = makeService(runner: runner, store: store)

        try service.start(reason: "duplicate")

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testFailedStartDoesNotWriteOn() {
        let runner = MockCommandRunner()
        runner.exitCodes = [9]
        let store = MockStateStore(state: "off")
        let service = makeService(runner: runner, store: store)

        XCTAssertThrowsError(try service.start(reason: "test")) { error in
            XCTAssertEqual(
                error as? ServiceOperationError,
                ServiceOperationError(serviceID: "codex-remote", operation: .start, message: "exit 9")
            )
        }
        XCTAssertEqual(store.state, "off")
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testHealthyServiceStopsCodexAndWritesOff() throws {
        let runner = MockCommandRunner()
        let store = MockStateStore(state: "on")
        let service = makeService(runner: runner, store: store)

        try service.stop(reason: "screen unlock")

        XCTAssertEqual(runner.calls.first?.arguments, ["remote-control", "stop"])
        XCTAssertEqual(store.writes, ["off"])
        XCTAssertEqual(service.inspect(), .stopped)
    }

    func testFailedStopPreservesOnState() {
        let runner = MockCommandRunner()
        runner.exitCodes = [4]
        let store = MockStateStore(state: "on")
        let service = makeService(runner: runner, store: store)

        XCTAssertThrowsError(try service.stop(reason: "test"))
        XCTAssertEqual(store.state, "on")
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testStoppedServiceSkipsStop() throws {
        let runner = MockCommandRunner()
        let store = MockStateStore(state: "off")
        let service = makeService(runner: runner, store: store)

        try service.stop(reason: "already stopped")

        XCTAssertTrue(runner.calls.isEmpty)
    }

    private func makeService(
        runner: MockCommandRunner,
        store: MockStateStore,
        logger: @escaping ServiceLogger = { _ in }
    ) -> CodexRemoteService {
        CodexRemoteService(
            executable: executable,
            outputURL: outputURL,
            commandRunner: runner,
            stateStore: store,
            logger: logger
        )
    }
}
