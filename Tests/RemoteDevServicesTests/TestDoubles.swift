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

@MainActor
final class MockStateStore: ServiceStatePersisting {
    var state: String
    private(set) var writes: [String] = []

    init(state: String) {
        self.state = state
    }

    func read() -> String {
        state
    }

    func write(_ state: String) {
        self.state = state
        writes.append(state)
    }
}

enum MockProcessError: Error, Equatable {
    case launchFailed
}

@MainActor
final class MockLongRunningProcess: LongRunningProcess {
    var isRunning = false
    let processIdentifier: Int32
    var startError: Error?
    private(set) var starts: [(String, [String])] = []
    private(set) var terminateCount = 0

    init(processIdentifier: Int32 = 42) {
        self.processIdentifier = processIdentifier
    }

    func start(executable: String, arguments: [String]) throws {
        starts.append((executable, arguments))
        if let startError {
            throw startError
        }
        isRunning = true
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
