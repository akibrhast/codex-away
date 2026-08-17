import Foundation
import XCTest
@testable import RemoteDevServices

final class ProcessExitMonitorTests: XCTestCase {
    func testDarwinMonitorObservesExactProcessExit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        try process.run()

        let events = DarwinProcessExitMonitor().events(
            for: process.processIdentifier
        )
        var iterator = events.makeAsyncIterator()
        let event: Void? = await iterator.next()
        process.waitUntilExit()

        XCTAssertNotNil(event)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
