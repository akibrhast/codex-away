import Foundation

@MainActor
public final class CodexRemoteService: ManagedService {
    public let id = "codex-remote"
    public let required: Bool

    private let executable: String
    private let outputURL: URL
    private let commandRunner: any CommandRunning
    private let stateStore: any ServiceStatePersisting
    private let logger: ServiceLogger

    public init(
        executable: String,
        outputURL: URL,
        required: Bool = true,
        commandRunner: any CommandRunning,
        stateStore: any ServiceStatePersisting,
        logger: @escaping ServiceLogger
    ) {
        self.executable = executable
        self.outputURL = outputURL
        self.required = required
        self.commandRunner = commandRunner
        self.stateStore = stateStore
        self.logger = logger
    }

    public func inspect() -> ServiceHealth {
        stateStore.read() == "on" ? .healthy : .stopped
    }

    public func start(reason: String) throws {
        guard inspect() != .healthy else { return }

        let result = commandRunner.run(
            executable: executable,
            arguments: ["remote-control", "start"],
            outputURL: outputURL
        )
        guard result == 0 else {
            logger("remote-control start failed (exit \(result)); trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .start,
                message: "exit \(result)"
            )
        }

        stateStore.write("on")
        logger("remote control started; trigger: \(reason)")
    }

    public func stop(reason: String) throws {
        guard inspect() == .healthy else { return }

        let result = commandRunner.run(
            executable: executable,
            arguments: ["remote-control", "stop"],
            outputURL: outputURL
        )
        guard result == 0 else {
            logger("remote-control stop failed (exit \(result)); trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .stop,
                message: "exit \(result)"
            )
        }

        stateStore.write("off")
        logger("remote control stopped; trigger: \(reason)")
    }
}
