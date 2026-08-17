import Darwin
import XCTest
@testable import RemoteDevServices

@MainActor
final class ProcessObservationTests: XCTestCase {
    func testDarwinInspectorReadsCurrentProcessIdentity() {
        let identity = DarwinProcessInspector().inspect(processIdentifier: getpid())

        XCTAssertEqual(identity?.processIdentifier, getpid())
        XCTAssertFalse(identity?.executablePath.isEmpty ?? true)
        XCTAssertFalse(identity?.arguments.isEmpty ?? true)
        XCTAssertGreaterThan(identity?.startTimeSeconds ?? 0, 0)
    }

    func testExactIdentityMatches() {
        let identity = makeIdentity()

        XCTAssertTrue(processIdentityMatches(identity, expected: identity))
    }

    func testMissingPIDDoesNotMatch() {
        XCTAssertFalse(processIdentityMatches(nil, expected: makeIdentity()))
    }

    func testReusedPIDDoesNotMatch() {
        XCTAssertFalse(
            processIdentityMatches(
                makeIdentity(seconds: 200),
                expected: makeIdentity(seconds: 100)
            )
        )
    }

    func testDifferentExecutableDoesNotMatch() {
        XCTAssertFalse(
            processIdentityMatches(
                makeIdentity(executable: "/usr/bin/other"),
                expected: makeIdentity()
            )
        )
    }

    func testDifferentArgumentsDoNotMatch() {
        XCTAssertFalse(
            processIdentityMatches(
                makeIdentity(arguments: ["-di"]),
                expected: makeIdentity()
            )
        )
    }
}
