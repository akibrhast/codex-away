import Foundation

public typealias ServiceLogger = @MainActor (String) -> Void

@MainActor
public protocol ManagedService: AnyObject {
    var id: String { get }
    var required: Bool { get }

    func inspect() -> ServiceHealth
    func start(reason: String) throws
    func stop(reason: String) throws
}

public struct ServiceOperationError: Error, Equatable, CustomStringConvertible {
    public enum Operation: String, Equatable, Sendable {
        case start
        case stop
    }

    public let serviceID: String
    public let operation: Operation
    public let message: String

    public init(serviceID: String, operation: Operation, message: String) {
        self.serviceID = serviceID
        self.operation = operation
        self.message = message
    }

    public var description: String {
        "\(serviceID) \(operation.rawValue) failed: \(message)"
    }
}
