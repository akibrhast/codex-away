import Foundation

@MainActor
public protocol CommandRunning {
    func run(executable: String, arguments: [String], outputURL: URL?) -> Int32
}

@MainActor
public final class ProcessCommandRunner: CommandRunning {
    private let logger: ServiceLogger

    public init(logger: @escaping ServiceLogger) {
        self.logger = logger
    }

    public func run(executable: String, arguments: [String], outputURL: URL?) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let outputURL, let handle = try? FileHandle(forWritingTo: outputURL) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            logger("failed to run \(executable): \(error)")
            return 127
        }
    }
}

@MainActor
public protocol LongRunningProcess: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }

    func start(executable: String, arguments: [String]) throws -> ProcessIdentity
    func terminateAndWait()
}

@MainActor
public protocol LongRunningProcessCreating {
    func makeProcess() -> any LongRunningProcess
}

@MainActor
public final class FoundationLongRunningProcess: LongRunningProcess {
    private let process = Process()

    public init() {}

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func start(executable: String, arguments: [String]) throws -> ProcessIdentity {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard let identity = DarwinProcessInspector().inspect(
            processIdentifier: process.processIdentifier
        ) else {
            process.terminate()
            process.waitUntilExit()
            throw ServiceOperationError(
                serviceID: "process",
                operation: .start,
                message: "could not inspect launched process"
            )
        }
        return identity
    }

    public func terminateAndWait() {
        process.terminate()
        process.waitUntilExit()
    }
}

@MainActor
public struct FoundationLongRunningProcessFactory: LongRunningProcessCreating {
    public init() {}

    public func makeProcess() -> any LongRunningProcess {
        FoundationLongRunningProcess()
    }
}
