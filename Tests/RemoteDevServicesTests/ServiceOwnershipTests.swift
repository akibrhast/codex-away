import Foundation
import XCTest
@testable import RemoteDevServices

@MainActor
final class ServiceOwnershipTests: XCTestCase {
    func testOwnershipRecordsRoundTripAndPreserveOtherServices() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileServiceOwnershipStore(
            fileURL: directory.appendingPathComponent("ownership.json")
        )
        let codex = ServiceOwnershipRecord(
            owned: true,
            processIdentity: makeIdentity(pid: 10),
            lastSuccessfulAction: .start
        )
        let caffeinate = ServiceOwnershipRecord(
            owned: false,
            processIdentity: nil,
            lastSuccessfulAction: .stop
        )

        store.save(codex, serviceID: "codex-remote")
        store.save(caffeinate, serviceID: "caffeinate")

        XCTAssertEqual(store.load(serviceID: "codex-remote"), codex)
        XCTAssertEqual(store.load(serviceID: "caffeinate"), caffeinate)
    }

    func testLegacyOnMigratesToOwnershipHintWithoutHealthProof() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("state")
        let ownershipURL = directory.appendingPathComponent("ownership.json")
        try "on\n".write(to: legacyURL, atomically: true, encoding: .utf8)
        let store = FileServiceOwnershipStore(
            fileURL: ownershipURL,
            legacyCodexStateURL: legacyURL
        )

        let record = store.load(serviceID: "codex-remote")

        XCTAssertTrue(record?.owned == true)
        XCTAssertNil(record?.processIdentity)
        XCTAssertEqual(record?.lastSuccessfulAction, .start)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownershipURL.path))
    }

    func testLegacyOffMigratesToUnowned() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("state")
        try "off".write(to: legacyURL, atomically: true, encoding: .utf8)
        let store = FileServiceOwnershipStore(
            fileURL: directory.appendingPathComponent("ownership.json"),
            legacyCodexStateURL: legacyURL
        )

        XCTAssertFalse(store.load(serviceID: "codex-remote")?.owned ?? true)
    }

    func testMalformedNewStateDoesNotFallBackToLegacyOwnership() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownershipURL = directory.appendingPathComponent("ownership.json")
        let legacyURL = directory.appendingPathComponent("state")
        try Data("not-json".utf8).write(to: ownershipURL)
        try "on".write(to: legacyURL, atomically: true, encoding: .utf8)
        let store = FileServiceOwnershipStore(
            fileURL: ownershipURL,
            legacyCodexStateURL: legacyURL
        )

        XCTAssertNil(store.load(serviceID: "codex-remote"))
    }

    func testUnsupportedSchemaFailsSafely() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownershipURL = directory.appendingPathComponent("ownership.json")
        try Data(#"{"schemaVersion":99,"services":{}}"#.utf8).write(to: ownershipURL)
        let store = FileServiceOwnershipStore(fileURL: ownershipURL)

        XCTAssertNil(store.load(serviceID: "codex-remote"))
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-dev-ownership-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
