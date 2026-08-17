import Darwin
import Foundation

@MainActor
public protocol LongRunningProcess: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }

    func start(executable: String, arguments: [String]) throws -> ProcessIdentity
    func terminateAndWait(timeout: TimeInterval) async throws
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

    public func terminateAndWait(timeout: TimeInterval) async throws {
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < killDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        guard !process.isRunning else {
            throw ServiceOperationError(
                serviceID: "process",
                operation: .stop,
                message: "process did not exit"
            )
        }
    }
}

@MainActor
public struct FoundationLongRunningProcessFactory: LongRunningProcessCreating {
    public init() {}

    public func makeProcess() -> any LongRunningProcess {
        FoundationLongRunningProcess()
    }
}
