import Foundation
@testable import RemoteDevServices

@MainActor
final class MockCommandRunner: CommandRunning {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let outputURL: URL?
    }

    var exitCodes: [Int32] = [0]
    private(set) var calls: [Call] = []

    func run(executable: String, arguments: [String], outputURL: URL?) -> Int32 {
        calls.append(Call(executable: executable, arguments: arguments, outputURL: outputURL))
        return exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
    }
}

func makeIdentity(
    pid: Int32 = 42,
    executable: String = "/usr/bin/caffeinate",
    arguments: [String] = ["-s"],
    seconds: UInt64 = 1_700_000_000,
    microseconds: UInt64 = 123
) -> ProcessIdentity {
    ProcessIdentity(
        processIdentifier: pid,
        executablePath: executable,
        arguments: arguments,
        startTimeSeconds: seconds,
        startTimeMicroseconds: microseconds
    )
}

@MainActor
final class MockOwnershipStore: ServiceOwnershipPersisting {
    var records: [String: ServiceOwnershipRecord] = [:]
    private(set) var saves: [(String, ServiceOwnershipRecord)] = []

    func load(serviceID: String) -> ServiceOwnershipRecord? {
        records[serviceID]
    }

    func save(_ record: ServiceOwnershipRecord, serviceID: String) {
        records[serviceID] = record
        saves.append((serviceID, record))
    }
}

@MainActor
final class MockProcessInspector: ProcessInspecting {
    var identities: [Int32: ProcessIdentity] = [:]

    func inspect(processIdentifier: Int32) -> ProcessIdentity? {
        identities[processIdentifier]
    }
}

@MainActor
final class MockCodexRuntimeInspector: CodexRuntimeInspecting {
    var observations: [CodexRuntimeObservation]

    init(_ observations: [CodexRuntimeObservation]) {
        self.observations = observations
    }

    func inspect() -> CodexRuntimeObservation {
        observations.count > 1 ? observations.removeFirst() : observations[0]
    }
}

@MainActor
final class MockProcessSignaler: ProcessSignaling {
    var result = true
    private(set) var terminatedPIDs: [Int32] = []

    func terminate(processIdentifier: Int32) -> Bool {
        terminatedPIDs.append(processIdentifier)
        return result
    }
}

enum MockProcessError: Error, Equatable {
    case launchFailed
}

@MainActor
final class MockLongRunningProcess: LongRunningProcess {
    var isRunning = false
    let processIdentifier: Int32
    let identity: ProcessIdentity
    var startError: Error?
    private(set) var starts: [(String, [String])] = []
    private(set) var terminateCount = 0

    init(processIdentifier: Int32 = 42) {
        self.processIdentifier = processIdentifier
        identity = makeIdentity(pid: processIdentifier)
    }

    func start(executable: String, arguments: [String]) throws -> ProcessIdentity {
        starts.append((executable, arguments))
        if let startError {
            throw startError
        }
        isRunning = true
        return identity
    }

    func terminateAndWait() {
        terminateCount += 1
        isRunning = false
    }
}

@MainActor
final class MockLongRunningProcessFactory: LongRunningProcessCreating {
    var processes: [MockLongRunningProcess]
    private(set) var makeCount = 0

    init(processes: [MockLongRunningProcess]) {
        self.processes = processes
    }

    func makeProcess() -> any LongRunningProcess {
        let process = processes[min(makeCount, processes.count - 1)]
        makeCount += 1
        return process
    }
}

@MainActor
final class MockManagedService: ManagedService {
    let id: String
    let required: Bool
    var health: ServiceHealth
    var startError: Error?
    var stopError: Error?
    private(set) var events: [String] = []

    init(id: String, required: Bool = true, health: ServiceHealth) {
        self.id = id
        self.required = required
        self.health = health
    }

    func inspect() -> ServiceHealth {
        events.append("inspect")
        return health
    }

    func start(reason: String) throws {
        events.append("start:\(reason)")
        if let startError {
            throw startError
        }
        health = .healthy
    }

    func stop(reason: String) throws {
        events.append("stop:\(reason)")
        if let stopError {
            throw stopError
        }
        health = .stopped
    }
}
