import Foundation
@testable import RemoteDevServices

final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    var exitCodes: [Int32] = [0]
    private(set) var calls: [Call] = []

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        let status = exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
        return CommandResult(exitStatus: status, stdout: "", stderr: "", stdoutTruncated: false, stderrTruncated: false, duration: 0)
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
    var forceResult = true
    private(set) var terminatedPIDs: [Int32] = []
    private(set) var forceTerminatedPIDs: [Int32] = []

    func terminate(processIdentifier: Int32) -> Bool {
        terminatedPIDs.append(processIdentifier)
        return result
    }

    func forceTerminate(processIdentifier: Int32) -> Bool {
        forceTerminatedPIDs.append(processIdentifier)
        return forceResult
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

    func terminateAndWait(timeout: TimeInterval) async throws {
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
    var startDelay: Duration?
    private(set) var events: [String] = []

    init(id: String, required: Bool = true, health: ServiceHealth) {
        self.id = id
        self.required = required
        self.health = health
    }

    func inspect() async -> ServiceHealth {
        events.append("inspect")
        return health
    }

    func start(reason: String) async throws {
        events.append("start:\(reason)")
        if let startDelay {
            try await Task.sleep(for: startDelay)
        }
        if let startError {
            throw startError
        }
        health = .healthy
    }

    func stop(reason: String) async throws {
        events.append("stop:\(reason)")
        if let stopError {
            throw stopError
        }
        health = .stopped
    }
}
