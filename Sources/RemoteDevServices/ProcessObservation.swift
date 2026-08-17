import Darwin
import Foundation

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let executablePath: String
    public let arguments: [String]
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(
        processIdentifier: Int32,
        executablePath: String,
        arguments: [String],
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.executablePath = executablePath
        self.arguments = arguments
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

@MainActor
public protocol ProcessInspecting {
    func inspect(processIdentifier: Int32) -> ProcessIdentity?
}

@MainActor
public final class DarwinProcessInspector: ProcessInspecting {
    public init() {}

    public func inspect(processIdentifier: Int32) -> ProcessIdentity? {
        guard processIdentifier > 0,
              let executablePath = readExecutablePath(processIdentifier: processIdentifier),
              let arguments = readArguments(processIdentifier: processIdentifier),
              let startTime = readStartTime(processIdentifier: processIdentifier)
        else {
            return nil
        }

        return ProcessIdentity(
            processIdentifier: processIdentifier,
            executablePath: executablePath,
            arguments: arguments,
            startTimeSeconds: startTime.seconds,
            startTimeMicroseconds: startTime.microseconds
        )
    }

    private func readExecutablePath(processIdentifier: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func readArguments(processIdentifier: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let argumentCount = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: Int32.self)
        }
        guard argumentCount > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        skipString(in: buffer, index: &index)
        skipNullBytes(in: buffer, index: &index)

        var arguments: [String] = []
        for _ in 0..<argumentCount where index < buffer.count {
            let start = index
            skipString(in: buffer, index: &index)
            let bytes = buffer[start..<max(start, index - 1)]
            arguments.append(String(decoding: bytes, as: UTF8.self))
            skipNullBytes(in: buffer, index: &index)
        }

        return Array(arguments.dropFirst())
    }

    private func readStartTime(processIdentifier: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard result == expectedSize else { return nil }
        return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
    }

    private func skipString(in buffer: [UInt8], index: inout Int) {
        while index < buffer.count, buffer[index] != 0 {
            index += 1
        }
        if index < buffer.count {
            index += 1
        }
    }

    private func skipNullBytes(in buffer: [UInt8], index: inout Int) {
        while index < buffer.count, buffer[index] == 0 {
            index += 1
        }
    }
}

public func processIdentityMatches(
    _ observed: ProcessIdentity?,
    expected: ProcessIdentity
) -> Bool {
    guard let observed else { return false }
    return observed.processIdentifier == expected.processIdentifier
        && URL(fileURLWithPath: observed.executablePath).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: expected.executablePath).resolvingSymlinksInPath().path
        && observed.arguments == expected.arguments
        && observed.startTimeSeconds == expected.startTimeSeconds
        && observed.startTimeMicroseconds == expected.startTimeMicroseconds
}
