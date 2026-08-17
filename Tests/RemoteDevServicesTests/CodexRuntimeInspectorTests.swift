import Foundation
import XCTest
@testable import RemoteDevServices

@MainActor
final class CodexRuntimeInspectorTests: XCTestCase {
    func testValidatedRemoteDaemonIsRunning() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(fixture.runtime.inspect(), .running(fixture.identity))
    }

    func testRemoteDisabledIsStoppedEvenWhenDaemonExists() throws {
        let fixture = try makeFixture(remoteEnabled: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(fixture.runtime.inspect(), .stopped)
    }

    func testInteractiveCodexArgumentsAreRejected() throws {
        let identity = makeIdentity(
            pid: 90,
            executable: "/test/codex",
            arguments: ["resume"]
        )
        let fixture = try makeFixture(identity: identity)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            fixture.runtime.inspect(),
            .invalid("Codex daemon arguments do not match")
        )
    }

    func testDifferentExecutableIsRejected() throws {
        let identity = makeIdentity(
            pid: 90,
            executable: "/test/not-codex",
            arguments: ["app-server", "daemon", "pid-update-loop"]
        )
        let fixture = try makeFixture(identity: identity)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            fixture.runtime.inspect(),
            .invalid("Codex daemon executable does not match")
        )
    }

    func testReusedPIDStartTimeIsRejected() throws {
        let fixture = try makeFixture(recordedSeconds: 1_700_000_100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            fixture.runtime.inspect(),
            .invalid("Codex daemon start time does not match")
        )
    }

    func testMissingPIDIsRejected() throws {
        let fixture = try makeFixture(includeObservedProcess: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            fixture.runtime.inspect(),
            .invalid("Codex daemon PID is not running")
        )
    }

    private func makeFixture(
        remoteEnabled: Bool = true,
        identity: ProcessIdentity? = nil,
        recordedSeconds: UInt64? = nil,
        includeObservedProcess: Bool = true
    ) throws -> (
        directory: URL,
        identity: ProcessIdentity,
        runtime: FileCodexRuntimeInspector
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let actualIdentity = identity ?? makeIdentity(
            pid: 90,
            executable: "/test/codex",
            arguments: ["app-server", "daemon", "pid-update-loop"]
        )
        let settingsURL = directory.appendingPathComponent("settings.json")
        let pidURL = directory.appendingPathComponent("daemon.pid")
        try JSONSerialization.data(withJSONObject: [
            "remoteControlEnabled": remoteEnabled,
        ]).write(to: settingsURL)
        try JSONSerialization.data(withJSONObject: [
            "pid": actualIdentity.processIdentifier,
            "processStartTime": formattedStartTime(
                seconds: recordedSeconds ?? actualIdentity.startTimeSeconds
            ),
        ]).write(to: pidURL)

        let processInspector = MockProcessInspector()
        if includeObservedProcess {
            processInspector.identities[actualIdentity.processIdentifier] = actualIdentity
        }
        let runtime = FileCodexRuntimeInspector(
            settingsURL: settingsURL,
            pidURL: pidURL,
            expectedExecutable: "/test/codex",
            processInspector: processInspector
        )
        return (directory, actualIdentity, runtime)
    }

    private func formattedStartTime(seconds: UInt64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
