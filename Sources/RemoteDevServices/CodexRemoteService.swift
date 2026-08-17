import Foundation

@MainActor
public final class CodexRemoteService: ManagedService {
    public let id = "codex-remote"
    public let required: Bool

    private let executable: String
    private let commandTimeout: TimeInterval
    private let commandRunner: any CommandRunning
    private let runtimeInspector: any CodexRuntimeInspecting
    private let ownershipStore: any ServiceOwnershipPersisting
    private let logger: ServiceLogger

    public init(
        executable: String,
        required: Bool = true,
        commandTimeout: TimeInterval = 10,
        commandRunner: any CommandRunning,
        runtimeInspector: any CodexRuntimeInspecting,
        ownershipStore: any ServiceOwnershipPersisting,
        logger: @escaping ServiceLogger
    ) {
        self.executable = executable
        self.required = required
        self.commandTimeout = commandTimeout
        self.commandRunner = commandRunner
        self.runtimeInspector = runtimeInspector
        self.ownershipStore = ownershipStore
        self.logger = logger
    }

    public func inspect() async -> ServiceHealth {
        switch runtimeInspector.inspect() {
        case .running:
            return .healthy
        case .stopped:
            return isOwned
                ? .unhealthy("controller-owned Codex Remote is not running")
                : .stopped
        case let .invalid(message):
            return .unhealthy(message)
        }
    }

    public func start(reason: String) async throws {
        guard await inspect() != .healthy else { return }

        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: executable,
                arguments: ["remote-control", "start"],
                timeout: commandTimeout
            )
            logCommandOutput(result)
        } catch {
            logCommandFailure(error)
            if let commandError = error as? CommandExecutionError {
                switch commandError {
                case .timedOut, .cancelled:
                    recordOwnershipAfterStartAttempt()
                case .launchFailed:
                    break
                }
            }
            logger("remote-control start failed (\(describe(error))); trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .start,
                message: describe(error)
            )
        }

        guard result.exitStatus == 0 else {
            recordOwnershipAfterStartAttempt()
            logger("remote-control start failed (exit \(result.exitStatus)); trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .start,
                message: "exit \(result.exitStatus)"
            )
        }

        let processIdentity = recordOwnershipAfterStartAttempt()

        guard processIdentity != nil else {
            logger("remote-control start verification failed; trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .start,
                message: "runtime could not be verified"
            )
        }
        logger("remote control started; trigger: \(reason)")
    }

    public func stop(reason: String) async throws {
        guard let ownershipRecord = ownershipStore.load(serviceID: id),
              ownershipRecord.owned
        else {
            return
        }

        switch runtimeInspector.inspect() {
        case .stopped:
            saveStoppedOwnership()
            return
        case let .running(observedIdentity):
            if let expectedIdentity = ownershipRecord.processIdentity,
               !processIdentityMatches(observedIdentity, expected: expectedIdentity) {
                logger("stale Codex ownership cleared without stopping an unowned daemon")
                saveStoppedOwnership()
                return
            }
        case let .invalid(message):
            throw ServiceOperationError(
                serviceID: id,
                operation: .stop,
                message: "refusing unverified stop: \(message)"
            )
        }

        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: executable,
                arguments: ["remote-control", "stop"],
                timeout: commandTimeout
            )
            logCommandOutput(result)
        } catch {
            logCommandFailure(error)
            if case .stopped = runtimeInspector.inspect() {
                saveStoppedOwnership()
                logger("remote control stopped after command \(describe(error)); trigger: \(reason)")
                return
            }
            logger("remote-control stop failed (\(describe(error))); trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .stop,
                message: describe(error)
            )
        }

        guard result.exitStatus == 0 else {
            logger("remote-control stop failed (exit \(result.exitStatus)); trigger: \(reason)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .stop,
                message: "exit \(result.exitStatus)"
            )
        }

        saveStoppedOwnership()
        logger("remote control stopped; trigger: \(reason)")
    }

    private var isOwned: Bool {
        ownershipStore.load(serviceID: id)?.owned == true
    }

    @discardableResult
    private func recordOwnershipAfterStartAttempt() -> ProcessIdentity? {
        let processIdentity: ProcessIdentity?
        switch runtimeInspector.inspect() {
        case let .running(identity):
            processIdentity = identity
        case .stopped, .invalid:
            processIdentity = nil
        }
        ownershipStore.save(
            ServiceOwnershipRecord(
                owned: true,
                processIdentity: processIdentity,
                lastSuccessfulAction: .start
            ),
            serviceID: id
        )
        return processIdentity
    }

    private func logCommandOutput(_ result: CommandResult) {
        logOutput(result.stdout, stream: "stdout", truncated: result.stdoutTruncated)
        logOutput(result.stderr, stream: "stderr", truncated: result.stderrTruncated)
    }

    private func logCommandFailure(_ error: any Error) {
        guard let commandError = error as? CommandExecutionError else { return }
        switch commandError {
        case let .timedOut(stdout, stderr), let .cancelled(stdout, stderr):
            logOutput(stdout, stream: "stdout", truncated: false)
            logOutput(stderr, stream: "stderr", truncated: false)
        case .launchFailed:
            break
        }
    }

    private func logOutput(_ output: String, stream: String, truncated: Bool) {
        let content = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || truncated else { return }
        logger("codex \(stream): \(content)\(truncated ? " [truncated]" : "")")
    }

    private func describe(_ error: any Error) -> String {
        guard let commandError = error as? CommandExecutionError else {
            return String(describing: error)
        }
        switch commandError {
        case .launchFailed:
            return "launch error"
        case .timedOut:
            return "timeout"
        case .cancelled:
            return "cancelled"
        }
    }

    private func saveStoppedOwnership() {
        ownershipStore.save(
            ServiceOwnershipRecord(
                owned: false,
                processIdentity: nil,
                lastSuccessfulAction: .stop
            ),
            serviceID: id
        )
    }
}
