public struct RemoteDevPolicy: Equatable, Sendable {
    public var requireLocked: Bool
    public var requireACPower: Bool

    public init(requireLocked: Bool = true, requireACPower: Bool = true) {
        self.requireLocked = requireLocked
        self.requireACPower = requireACPower
    }
}
