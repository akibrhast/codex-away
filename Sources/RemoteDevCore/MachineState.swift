public struct MachineState: Equatable, Sendable {
    public var isLocked: Bool
    public var isOnACPower: Bool

    public init(isLocked: Bool, isOnACPower: Bool) {
        self.isLocked = isLocked
        self.isOnACPower = isOnACPower
    }
}
