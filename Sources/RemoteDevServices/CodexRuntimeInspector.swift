import Foundation

public enum CodexRuntimeObservation: Equatable, Sendable {
    case stopped
    case running(ProcessIdentity)
    case invalid(String)
}

@MainActor
public protocol CodexRuntimeInspecting {
    func inspect() -> CodexRuntimeObservation
}

@MainActor
public final class FileCodexRuntimeInspector: CodexRuntimeInspecting {
    private struct Settings: Decodable {
        let remoteControlEnabled: Bool
    }

    private struct PIDRecord: Decodable {
        let pid: Int32
        let processStartTime: String
    }

    private let settingsURL: URL
    private let pidURL: URL
    private let expectedExecutable: String
    private let processInspector: any ProcessInspecting

    public init(
        settingsURL: URL,
        pidURL: URL,
        expectedExecutable: String,
        processInspector: any ProcessInspecting
    ) {
        self.settingsURL = settingsURL
        self.pidURL = pidURL
        self.expectedExecutable = expectedExecutable
        self.processInspector = processInspector
    }

    public func inspect() -> CodexRuntimeObservation {
        guard let settingsData = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: settingsData)
        else {
            return .invalid("Codex daemon settings are unavailable")
        }
        guard settings.remoteControlEnabled else {
            return .stopped
        }

        guard let pidData = try? Data(contentsOf: pidURL),
              let pidRecord = try? JSONDecoder().decode(PIDRecord.self, from: pidData)
        else {
            return .invalid("Codex daemon PID metadata is unavailable")
        }
        guard let observed = processInspector.inspect(processIdentifier: pidRecord.pid) else {
            return .invalid("Codex daemon PID is not running")
        }

        let resolvedObserved = URL(fileURLWithPath: observed.executablePath)
            .resolvingSymlinksInPath().path
        let resolvedExpected = URL(fileURLWithPath: expectedExecutable)
            .resolvingSymlinksInPath().path
        guard resolvedObserved == resolvedExpected else {
            return .invalid("Codex daemon executable does not match")
        }
        guard observed.arguments == ["app-server", "daemon", "pid-update-loop"] else {
            return .invalid("Codex daemon arguments do not match")
        }
        guard processStartTimeMatches(pidRecord.processStartTime, identity: observed) else {
            return .invalid("Codex daemon start time does not match")
        }

        return .running(observed)
    }

    private func processStartTimeMatches(_ value: String, identity: ProcessIdentity) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let recordedDate = formatter.date(from: value) else { return false }
        return UInt64(recordedDate.timeIntervalSince1970) == identity.startTimeSeconds
    }
}
