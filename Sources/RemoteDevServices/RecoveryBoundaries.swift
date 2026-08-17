import Dispatch
import Foundation

public struct RecoveryPolicy: Equatable, Sendable {
    public let healthAuditInterval: TimeInterval
    public let maximumAttempts: Int
    public let initialBackoff: TimeInterval
    public let backoffMultiplier: Double
    public let maximumBackoff: TimeInterval
    public let stableHealthInterval: TimeInterval

    public init(
        healthAuditInterval: TimeInterval = 30,
        maximumAttempts: Int = 3,
        initialBackoff: TimeInterval = 1,
        backoffMultiplier: Double = 2,
        maximumBackoff: TimeInterval = 30,
        stableHealthInterval: TimeInterval = 60
    ) {
        self.healthAuditInterval = healthAuditInterval
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialBackoff = max(0, initialBackoff)
        self.backoffMultiplier = max(1, backoffMultiplier)
        self.maximumBackoff = max(0, maximumBackoff)
        self.stableHealthInterval = max(0, stableHealthInterval)
    }

    public func backoff(afterFailedAttempt attempt: Int) -> TimeInterval {
        min(
            maximumBackoff,
            initialBackoff * pow(backoffMultiplier, Double(max(0, attempt - 1)))
        )
    }
}

public protocol RecoverySleeping: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemRecoverySleeper: RecoverySleeping {
    public init() {}

    public func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, interval)))
    }
}

public protocol ProcessExitMonitoring: Sendable {
    func events(for processIdentifier: Int32) -> AsyncStream<Void>
}

public struct DarwinProcessExitMonitor: ProcessExitMonitoring {
    public init() {}

    public func events(for processIdentifier: Int32) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier,
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                continuation.yield(())
                continuation.finish()
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
