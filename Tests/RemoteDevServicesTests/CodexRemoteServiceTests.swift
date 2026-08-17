import Foundation
import XCTest
@testable import RemoteDevServices

@MainActor
final class CodexRemoteServiceTests: XCTestCase {
    private let executable = "/test/codex"
    func testStoppedUnownedRuntimeIsStopped() async {
        let service = makeService(runtime: MockCodexRuntimeInspector([.stopped]))

        let health = await service.inspect()
        XCTAssertEqual(health, .stopped)
    }

    func testStoppedOwnedRuntimeIsUnhealthy() async {
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: nil)
        let service = makeService(
            runtime: MockCodexRuntimeInspector([.stopped]),
            ownership: ownership
        )

        let health = await service.inspect()
        XCTAssertEqual(
            health,
            .unhealthy("controller-owned Codex Remote is not running")
        )
    }

    func testRunningUnownedRuntimeIsHealthyAndSkipsStart() async throws {
        let runner = MockCommandRunner()
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(makeCodexIdentity())])
        )

        let health = await service.inspect()
        XCTAssertEqual(health, .healthy)
        try await service.start(reason: "duplicate")

        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testSuccessfulStartVerifiesRuntimeAndRecordsOwnership() async throws {
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

        try await service.start(reason: "screen lock")

        XCTAssertEqual(runner.calls, [
            .init(
                executable: executable,
                arguments: ["remote-control", "start"],
                timeout: 10
            ),
        ])
        XCTAssertEqual(ownership.records["codex-remote"], ownedRecord(identity: identity))
        XCTAssertEqual(logs, ["remote control started; trigger: screen lock"])
    }

    func testFailedStartRecordsConservativeOwnershipForLaterCleanup() async {
        let runner = MockCommandRunner()
        runner.exitCodes = [9]
        let ownership = MockOwnershipStore()
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.stopped]),
            ownership: ownership
        )

        do { try await service.start(reason: "test"); XCTFail("expected start failure") } catch {}
        XCTAssertEqual(ownership.records["codex-remote"], ownedRecord(identity: nil))
    }

    func testSuccessfulCommandWithoutObservedRuntimeIsNotHealthy() async {
        let ownership = MockOwnershipStore()
        let service = makeService(
            runtime: MockCodexRuntimeInspector([.stopped, .stopped]),
            ownership: ownership
        )

        do { try await service.start(reason: "test"); XCTFail("expected verification failure") } catch {}
        XCTAssertEqual(ownership.records["codex-remote"], ownedRecord(identity: nil))
    }

    func testOwnedRunningRuntimeStopsAndClearsOwnership() async throws {
        let runner = MockCommandRunner()
        let identity = makeCodexIdentity()
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: identity)
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(identity)]),
            ownership: ownership
        )

        try await service.stop(reason: "unlock")

        XCTAssertEqual(runner.calls.first?.arguments, ["remote-control", "stop"])
        XCTAssertEqual(
            ownership.records["codex-remote"],
            ServiceOwnershipRecord(owned: false, processIdentity: nil, lastSuccessfulAction: .stop)
        )
    }

    func testUnownedRunningRuntimeIsNeverStopped() async throws {
        let runner = MockCommandRunner()
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.running(makeCodexIdentity())])
        )

        try await service.stop(reason: "unlock")

        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testReplacedOwnedDaemonIsNeverStopped() async throws {
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

        try await service.stop(reason: "unlock")

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(ownership.records["codex-remote"]?.owned ?? true)
    }

    func testInvalidRuntimeRefusesOwnedStop() async {
        let runner = MockCommandRunner()
        let ownership = MockOwnershipStore()
        ownership.records["codex-remote"] = ownedRecord(identity: makeCodexIdentity())
        let service = makeService(
            runner: runner,
            runtime: MockCodexRuntimeInspector([.invalid("mismatch")]),
            ownership: ownership
        )

        do { try await service.stop(reason: "unlock"); XCTFail("expected stop failure") } catch {}
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
