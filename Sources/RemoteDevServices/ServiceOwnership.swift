import Darwin
import Foundation

public struct ServiceOwnershipRecord: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case start
        case stop
    }

    public let owned: Bool
    public let processIdentity: ProcessIdentity?
    public let lastSuccessfulAction: Action

    public init(
        owned: Bool,
        processIdentity: ProcessIdentity?,
        lastSuccessfulAction: Action
    ) {
        self.owned = owned
        self.processIdentity = processIdentity
        self.lastSuccessfulAction = lastSuccessfulAction
    }
}

private struct OwnershipFile: Codable {
    let schemaVersion: Int
    var services: [String: ServiceOwnershipRecord]
}

@MainActor
public protocol ServiceOwnershipPersisting {
    func load(serviceID: String) -> ServiceOwnershipRecord?
    func save(_ record: ServiceOwnershipRecord, serviceID: String)
}

@MainActor
public final class FileServiceOwnershipStore: ServiceOwnershipPersisting {
    private let fileURL: URL
    private let legacyCodexStateURL: URL?

    public init(fileURL: URL, legacyCodexStateURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyCodexStateURL = legacyCodexStateURL
    }

    public func load(serviceID: String) -> ServiceOwnershipRecord? {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return readOwnershipFile()?.services[serviceID]
        }

        guard serviceID == "codex-remote", let legacyCodexStateURL else {
            return nil
        }
        let legacyState = (try? String(contentsOf: legacyCodexStateURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedRecord: ServiceOwnershipRecord
        switch legacyState {
        case "on":
            migratedRecord = ServiceOwnershipRecord(
                owned: true,
                processIdentity: nil,
                lastSuccessfulAction: .start
            )
        case "off":
            migratedRecord = ServiceOwnershipRecord(
                owned: false,
                processIdentity: nil,
                lastSuccessfulAction: .stop
            )
        default:
            return nil
        }
        save(migratedRecord, serviceID: serviceID)
        return migratedRecord
    }

    public func save(_ record: ServiceOwnershipRecord, serviceID: String) {
        var ownershipFile = readOwnershipFile()
            ?? OwnershipFile(schemaVersion: 1, services: [:])
        ownershipFile.services[serviceID] = record

        guard let data = try? JSONEncoder().encode(ownershipFile) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func readOwnershipFile() -> OwnershipFile? {
        guard let data = try? Data(contentsOf: fileURL),
              let ownershipFile = try? JSONDecoder().decode(OwnershipFile.self, from: data),
              ownershipFile.schemaVersion == 1
        else {
            return nil
        }
        return ownershipFile
    }
}

@MainActor
public protocol ProcessSignaling {
    func terminate(processIdentifier: Int32) -> Bool
    func forceTerminate(processIdentifier: Int32) -> Bool
}

@MainActor
public struct DarwinProcessSignaler: ProcessSignaling {
    public init() {}

    public func terminate(processIdentifier: Int32) -> Bool {
        Darwin.kill(processIdentifier, SIGTERM) == 0
    }

    public func forceTerminate(processIdentifier: Int32) -> Bool {
        Darwin.kill(processIdentifier, SIGKILL) == 0
    }
}
