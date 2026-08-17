import Foundation

@MainActor
public final class CaffeinateService: ManagedService {
    public let id = "caffeinate"
    public let required: Bool

    private let executable: String
    private let processFactory: any LongRunningProcessCreating
    private let processInspector: any ProcessInspecting
    private let processSignaler: any ProcessSignaling
    private let ownershipStore: any ServiceOwnershipPersisting
    private let logger: ServiceLogger
    private var process: (any LongRunningProcess)?
    private var lastFailure: String?

    public init(
        executable: String = "/usr/bin/caffeinate",
        required: Bool = true,
        processFactory: any LongRunningProcessCreating,
        processInspector: any ProcessInspecting,
        processSignaler: any ProcessSignaling,
        ownershipStore: any ServiceOwnershipPersisting,
        logger: @escaping ServiceLogger
    ) {
        self.executable = executable
        self.required = required
        self.processFactory = processFactory
        self.processInspector = processInspector
        self.processSignaler = processSignaler
        self.ownershipStore = ownershipStore
        self.logger = logger
    }

    public func inspect() -> ServiceHealth {
        guard let record = ownershipStore.load(serviceID: id), record.owned else {
            if let lastFailure {
                return .unhealthy(lastFailure)
            }
            return .stopped
        }
        guard let expectedIdentity = record.processIdentity else {
            return .unhealthy("caffeinate ownership metadata has no process identity")
        }
        let observed = processInspector.inspect(
            processIdentifier: expectedIdentity.processIdentifier
        )
        if processIdentityMatches(observed, expected: expectedIdentity) {
            return .healthy
        }
        return .unhealthy("controller-owned caffeinate process is not running")
    }

    public func start(reason _: String) throws {
        guard inspect() != .healthy else { return }

        let newProcess = processFactory.makeProcess()
        do {
            let identity = try newProcess.start(executable: executable, arguments: ["-s"])
            process = newProcess
            lastFailure = nil
            ownershipStore.save(
                ServiceOwnershipRecord(
                    owned: true,
                    processIdentity: identity,
                    lastSuccessfulAction: .start
                ),
                serviceID: id
            )
            logger("caffeinate started (pid \(identity.processIdentifier))")
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
        guard let record = ownershipStore.load(serviceID: id), record.owned else {
            process = nil
            lastFailure = nil
            return
        }
        guard let expectedIdentity = record.processIdentity else {
            clearOwnership()
            process = nil
            lastFailure = nil
            return
        }

        let observed = processInspector.inspect(
            processIdentifier: expectedIdentity.processIdentifier
        )
        guard processIdentityMatches(observed, expected: expectedIdentity) else {
            logger("stale caffeinate ownership cleared without signaling pid \(expectedIdentity.processIdentifier)")
            clearOwnership()
            process = nil
            lastFailure = nil
            return
        }

        if let process,
           process.processIdentifier == expectedIdentity.processIdentifier,
           process.isRunning {
            process.terminateAndWait()
        } else if !processSignaler.terminate(processIdentifier: expectedIdentity.processIdentifier) {
            throw ServiceOperationError(
                serviceID: id,
                operation: .stop,
                message: "could not terminate pid \(expectedIdentity.processIdentifier)"
            )
        }
        logger("caffeinate stopped (pid \(expectedIdentity.processIdentifier))")
        clearOwnership()
        process = nil
        lastFailure = nil
    }

    private func clearOwnership() {
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
