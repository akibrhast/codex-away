import Foundation

@MainActor
public final class CodexRemoteService: ManagedService {
    public let id = "codex-remote"
    public let required: Bool

    private let executable: String
    private let outputURL: URL
    private let commandRunner: any CommandRunning
    private let runtimeInspector: any CodexRuntimeInspecting
    private let ownershipStore: any ServiceOwnershipPersisting
    private let logger: ServiceLogger

    public init(
        executable: String,
        outputURL: URL,
        required: Bool = true,
        commandRunner: any CommandRunning,
        runtimeInspector: any CodexRuntimeInspecting,
        ownershipStore: any ServiceOwnershipPersisting,
        logger: @escaping ServiceLogger
    ) {
        self.executable = executable
        self.outputURL = outputURL
        self.required = required
        self.commandRunner = commandRunner
        self.runtimeInspector = runtimeInspector
        self.ownershipStore = ownershipStore
        self.logger = logger
    }

    public func inspect() -> ServiceHealth {
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

        let processIdentity: ProcessIdentity?
        switch runtimeInspector.inspect() {
        case let .running(identity):
            processIdentity = identity
        case .stopped:
            processIdentity = nil
        case .invalid:
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

    public func stop(reason: String) throws {
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

        saveStoppedOwnership()
        logger("remote control stopped; trigger: \(reason)")
    }

    private var isOwned: Bool {
        ownershipStore.load(serviceID: id)?.owned == true
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
