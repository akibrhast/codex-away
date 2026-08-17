import Foundation
import XCTest
@testable import RemoteDevServices

@MainActor
final class CodexRemoteServiceTests: XCTestCase {
    private let executable = "/test/codex"
    private let outputURL = URL(fileURLWithPath: "/test/controller.log")

    func testStoppedUnownedRuntimeIsStopped() {
        let service = makeService(runtime: MockCodexRuntimeInspector([.stopped]))

        XCTAssertEqual(service.inspect(), .stopped)
    }

    func testStoppedOwnedRuntimeIsUnhealthy() {
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: nil)
        let service = makeService(
            runtime: MockCodexRuntimeInspector([.stopped]),
            ownership: ownership
        )

        XCTAssertEqual(
            service.inspect(),
            .unhealthy("controller-owned Codex Remote is not running")
        )
    }

    func testRunningUnownedRuntimeIsHealthyAndSkipsStart() throws {
        let runner = MockCommandRunner()
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(makeCodexIdentity())])
        )

        XCTAssertEqual(service.inspect(), .healthy)
        try service.start(reason: "duplicate")

        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testSuccessfulStartVerifiesRuntimeAndRecordsOwnership() throws {
        let runner = MockCommandRunner()
        let identity = makeCodexIdentity()
        let ownership = MockOwnershipStore()
        let runtime = MockCodexRuntimeInspector([.stopped, .running(identity)])
        var logs: [String] = []
        let service = makeService(
            runner: runner,
            runtime: runtime,
            ownership: ownership,
            logger: { logs.append($0) }
        )

        try service.start(reason: "screen lock")

        XCTAssertEqual(runner.calls, [
            .init(
                executable: executable,
                arguments: ["remote-control", "start"],
                outputURL: outputURL
            ),
        ])
        XCTAssertEqual(ownership.records["codex-remote"], ownedRecord(identity: identity))
        XCTAssertEqual(logs, ["remote control started; trigger: screen lock"])
    }

    func testFailedStartDoesNotRecordOwnership() {
        let runner = MockCommandRunner()
        runner.exitCodes = [9]
        let ownership = MockOwnershipStore()
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.stopped]),
            ownership: ownership
        )

        XCTAssertThrowsError(try service.start(reason: "test"))
        XCTAssertNil(ownership.records["codex-remote"])
    }

    func testSuccessfulCommandWithoutObservedRuntimeIsNotHealthy() {
        let ownership = MockOwnershipStore()
        let service = makeService(
            runtime: MockCodexRuntimeInspector([.stopped, .stopped]),
            ownership: ownership
        )

        XCTAssertThrowsError(try service.start(reason: "test"))
        XCTAssertEqual(ownership.records["codex-remote"], ownedRecord(identity: nil))
    }

    func testOwnedRunningRuntimeStopsAndClearsOwnership() throws {
        let runner = MockCommandRunner()
        let identity = makeCodexIdentity()
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: identity)
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(identity)]),
            ownership: ownership
        )

        try service.stop(reason: "unlock")

        XCTAssertEqual(runner.calls.first?.arguments, ["remote-control", "stop"])
        XCTAssertEqual(
            ownership.records["codex-remote"],
            ServiceOwnershipRecord(owned: false, processIdentity: nil, lastSuccessfulAction: .stop)
        )
    }

    func testUnownedRunningRuntimeIsNeverStopped() throws {
        let runner = MockCommandRunner()
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(makeCodexIdentity())])
        )

        try service.stop(reason: "unlock")

        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testReplacedOwnedDaemonIsNeverStopped() throws {
        let runner = MockCommandRunner()
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: makeCodexIdentity())
        let replacement = makeIdentity(
            pid: 91,
            executable: executable,
            arguments: ["app-server", "--remote-control", "--listen", "unix://"]
        )
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(replacement)]),
            ownership: ownership
        )

        try service.stop(reason: "unlock")

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(ownership.records["codex-remote"]?.owned ?? true)
    }

    func testInvalidRuntimeRefusesOwnedStop() {
        let runner = MockCommandRunner()
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: makeCodexIdentity())
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.invalid("mismatch")]),
            ownership: ownership
        )

        XCTAssertThrowsError(try service.stop(reason: "unlock"))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(ownership.records["codex-remote"]?.owned == true)
    }

    private func makeService(
        runner: MockCommandRunner = MockCommandRunner(),
        runtime: MockCodexRuntimeInspector,
        ownership: MockOwnershipStore = MockOwnershipStore(),
        logger: @escaping ServiceLogger = { _ in }
    ) -> CodexRemoteService {
        CodexRemoteService(
            executable: executable,
            outputURL: outputURL,
            commandRunner: runner,
            runtimeInspector: runtime,
            ownershipStore: ownership,
            logger: logger
        )
    }

    private func makeCodexIdentity() -> ProcessIdentity {
        makeIdentity(
            pid: 90,
            executable: executable,
            arguments: ["app-server", "--remote-control", "--listen", "unix://"]
        )
    }

    private func ownedRecord(identity: ProcessIdentity?) -> ServiceOwnershipRecord {
        ServiceOwnershipRecord(
            owned: true,
            processIdentity: identity,
            lastSuccessfulAction: .start
        )
    }
}
