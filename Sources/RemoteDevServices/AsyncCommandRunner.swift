import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let duration: TimeInterval

    public init(
        exitStatus: Int32,
        stdout: String,
        stderr: String,
        stdoutTruncated: Bool,
        stderrTruncated: Bool,
        duration: TimeInterval
    ) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.duration = duration
    }
}

public enum CommandExecutionError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(stdout: String, stderr: String)
    case cancelled(stdout: String, stderr: String)
}

public protocol CommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult
}

public final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    private let outputLimit: Int
    private let terminationGracePeriod: TimeInterval

    public init(
        outputLimit: Int = 65_536,
        terminationGracePeriod: TimeInterval = 1
    ) {
        self.outputLimit = outputLimit
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        if Task.isCancelled {
            throw CommandExecutionError.cancelled(stdout: "", stderr: "")
        }

        let control = CommandControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    execute(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        control: control,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    private func execute(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        control: CommandControl,
        continuation: CheckedContinuation<CommandResult, any Error>
    ) {
        let startedAt = Date()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = BoundedDataBuffer(limit: outputLimit)
        let stderrBuffer = BoundedDataBuffer(limit: outputLimit)
        let readers = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        control.install(process)
        if control.isCancelled {
            continuation.resume(
                throwing: CommandExecutionError.cancelled(stdout: "", stderr: "")
            )
            return
        }

        do {
            try process.run()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
        } catch {
            continuation.resume(
                throwing: CommandExecutionError.launchFailed(String(describing: error))
            )
            return
        }

        startReader(stdoutPipe.fileHandleForReading, buffer: stdoutBuffer, group: readers)
        startReader(stderrPipe.fileHandleForReading, buffer: stderrBuffer, group: readers)

        let deadline = startedAt.addingTimeInterval(max(0, timeout))
        var timedOut = false
        var cancelled = false

        while process.isRunning {
            if control.isCancelled {
                cancelled = true
                terminate(process)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminate(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        if !timedOut, control.isCancelled {
            cancelled = true
        }

        if process.isRunning {
            let graceDeadline = Date().addingTimeInterval(terminationGracePeriod)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        readers.wait()

        let stdout = stdoutBuffer.snapshot()
        let stderr = stderrBuffer.snapshot()
        if cancelled {
            continuation.resume(
                throwing: CommandExecutionError.cancelled(
                    stdout: stdout.text,
                    stderr: stderr.text
                )
            )
            return
        }
        if timedOut {
            continuation.resume(
                throwing: CommandExecutionError.timedOut(
                    stdout: stdout.text,
                    stderr: stderr.text
                )
            )
            return
        }

        continuation.resume(
            returning: CommandResult(
                exitStatus: process.terminationStatus,
                stdout: stdout.text,
                stderr: stderr.text,
                stdoutTruncated: stdout.truncated,
                stderrTruncated: stderr.truncated,
                duration: Date().timeIntervalSince(startedAt)
            )
        )
    }

    private func startReader(
        _ handle: FileHandle,
        buffer: BoundedDataBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
            }
            group.leave()
        }
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }
}

private final class CommandControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class BoundedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ newData: Data) {
        lock.withLock {
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(newData.prefix(remaining))
            }
            if newData.count > remaining {
                truncated = true
            }
        }
    }

    func snapshot() -> (text: String, truncated: Bool) {
        lock.withLock {
            (String(decoding: data, as: UTF8.self), truncated)
        }
    }
}
