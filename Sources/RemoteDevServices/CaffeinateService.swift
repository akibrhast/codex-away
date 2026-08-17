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
    private let stopTimeout: TimeInterval
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
        stopTimeout: TimeInterval = 5,
        logger: @escaping ServiceLogger
    ) {
        self.executable = executable
        self.required = required
        self.processFactory = processFactory
        self.processInspector = processInspector
        self.processSignaler = processSignaler
        self.ownershipStore = ownershipStore
        self.stopTimeout = stopTimeout
        self.logger = logger
    }

    public func inspect() async -> ServiceHealth {
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

    public func start(reason _: String) async throws {
        guard await inspect() != .healthy else { return }

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

    public func stop(reason _: String) async throws {
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
            try await process.terminateAndWait(timeout: stopTimeout)
        } else if !processSignaler.terminate(processIdentifier: expectedIdentity.processIdentifier) {
            throw ServiceOperationError(
                serviceID: id,
                operation: .stop,
                message: "could not terminate pid \(expectedIdentity.processIdentifier)"
            )
        } else {
            let deadline = Date().addingTimeInterval(stopTimeout)
            while processIdentityMatches(
                processInspector.inspect(processIdentifier: expectedIdentity.processIdentifier),
                expected: expectedIdentity
            ), Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            if processIdentityMatches(
                processInspector.inspect(processIdentifier: expectedIdentity.processIdentifier),
                expected: expectedIdentity
            ) {
                guard processSignaler.forceTerminate(
                    processIdentifier: expectedIdentity.processIdentifier
                ) else {
                    throw ServiceOperationError(
                        serviceID: id,
                        operation: .stop,
                        message: "could not force terminate pid \(expectedIdentity.processIdentifier)"
                    )
                }
            }
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
