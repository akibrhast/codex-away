import XCTest
@testable import RemoteDevServices

final class AsyncCommandRunnerTests: XCTestCase {
    func testCapturesSuccessfulOutputAndExitStatus() async throws {
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/echo",
            arguments: ["hello"],
            timeout: 2
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testReportsLaunchFailure() async {
        do {
            _ = try await ProcessCommandRunner().run(
                executable: "/definitely/missing",
                arguments: [],
                timeout: 1
            )
            XCTFail("expected launch failure")
        } catch let error as CommandExecutionError {
            guard case .launchFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTimesOutAndReapsChild() async {
        let started = Date()
        do {
            _ = try await ProcessCommandRunner(terminationGracePeriod: 0.1).run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 0.05
            )
            XCTFail("expected timeout")
        } catch let error as CommandExecutionError {
            guard case .timedOut = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellationStopsCommand() async {
        let task = Task {
            try await ProcessCommandRunner(terminationGracePeriod: 0.1).run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 10
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as CommandExecutionError {
            guard case .cancelled = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBoundsLargeOutputAndMarksTruncation() async throws {
        let result = try await ProcessCommandRunner(outputLimit: 32).run(
            executable: "/usr/bin/seq",
            arguments: ["1", "1000"],
            timeout: 2
        )

        XCTAssertEqual(result.stdout.utf8.count, 32)
        XCTAssertTrue(result.stdoutTruncated)
    }
}
