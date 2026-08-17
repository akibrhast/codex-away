import Foundation

@MainActor
public final class CaffeinateService: ManagedService {
    public let id = "caffeinate"
    public let required: Bool

    private let executable: String
    private let processFactory: any LongRunningProcessCreating
    private let logger: ServiceLogger
    private var process: (any LongRunningProcess)?
    private var lastFailure: String?

    public init(
        executable: String = "/usr/bin/caffeinate",
        required: Bool = true,
        processFactory: any LongRunningProcessCreating,
        logger: @escaping ServiceLogger
    ) {
        self.executable = executable
        self.required = required
        self.processFactory = processFactory
        self.logger = logger
    }

    public func inspect() -> ServiceHealth {
        if process?.isRunning == true {
            return .healthy
        }
        if let lastFailure {
            return .unhealthy(lastFailure)
        }
        return .stopped
    }

    public func start(reason _: String) throws {
        guard process?.isRunning != true else { return }

        let newProcess = processFactory.makeProcess()
        do {
            try newProcess.start(executable: executable, arguments: ["-s"])
            process = newProcess
            lastFailure = nil
            logger("caffeinate started (pid \(newProcess.processIdentifier))")
        } catch {
            let message = String(describing: error)
            process = nil
            lastFailure = message
            logger("caffeinate start failed: \(message)")
            throw ServiceOperationError(
                serviceID: id,
                operation: .start,
                message: message
            )
        }
    }

    public func stop(reason _: String) throws {
        if let process, process.isRunning {
            let processIdentifier = process.processIdentifier
            process.terminateAndWait()
            logger("caffeinate stopped (pid \(processIdentifier))")
        }
        process = nil
        lastFailure = nil
    }
}
