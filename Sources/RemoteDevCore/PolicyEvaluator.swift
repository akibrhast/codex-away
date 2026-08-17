public func shouldEnableRemoteDev(
    mode: ControllerMode,
    machine: MachineState,
    policy: RemoteDevPolicy
) -> Bool {
    switch mode {
    case .forceOn:
        return true
    case .forceOff:
        return false
    case .automatic:
        if policy.requireLocked && !machine.isLocked {
            return false
        }

        if policy.requireACPower && !machine.isOnACPower {
            return false
        }

        return true
    }
}
