import XCTest
@testable import RemoteDevCore

final class PolicyEvaluatorTests: XCTestCase {
    private let automaticPolicy = RemoteDevPolicy()

    func testAutomaticModeEnablesWhenLockedAndOnACPower() {
        let machine = MachineState(isLocked: true, isOnACPower: true)

        XCTAssertTrue(
            shouldEnableRemoteDev(mode: .automatic, machine: machine, policy: automaticPolicy)
        )
    }

    func testAutomaticModeDisablesWhenLockedAndOnBattery() {
        let machine = MachineState(isLocked: true, isOnACPower: false)

        XCTAssertFalse(
            shouldEnableRemoteDev(mode: .automatic, machine: machine, policy: automaticPolicy)
        )
    }

    func testAutomaticModeDisablesWhenUnlockedAndOnACPower() {
        let machine = MachineState(isLocked: false, isOnACPower: true)

        XCTAssertFalse(
            shouldEnableRemoteDev(mode: .automatic, machine: machine, policy: automaticPolicy)
        )
    }

    func testAutomaticModeDisablesWhenUnlockedAndOnBattery() {
        let machine = MachineState(isLocked: false, isOnACPower: false)

        XCTAssertFalse(
            shouldEnableRemoteDev(mode: .automatic, machine: machine, policy: automaticPolicy)
        )
    }

    func testAutomaticModeIgnoresLockWhenLockIsNotRequired() {
        let machine = MachineState(isLocked: false, isOnACPower: true)
        let policy = RemoteDevPolicy(requireLocked: false)

        XCTAssertTrue(
            shouldEnableRemoteDev(mode: .automatic, machine: machine, policy: policy)
        )
    }

    func testAutomaticModeIgnoresPowerWhenACPowerIsNotRequired() {
        let machine = MachineState(isLocked: true, isOnACPower: false)
        let policy = RemoteDevPolicy(requireACPower: false)

        XCTAssertTrue(
            shouldEnableRemoteDev(mode: .automatic, machine: machine, policy: policy)
        )
    }

    func testForceOnOverridesAutomaticPolicy() {
        let machine = MachineState(isLocked: false, isOnACPower: false)

        XCTAssertTrue(
            shouldEnableRemoteDev(mode: .forceOn, machine: machine, policy: automaticPolicy)
        )
    }

    func testForceOffOverridesAutomaticPolicy() {
        let machine = MachineState(isLocked: true, isOnACPower: true)

        XCTAssertFalse(
            shouldEnableRemoteDev(mode: .forceOff, machine: machine, policy: automaticPolicy)
        )
    }

    func testCoreModelsHaveValueEquality() {
        XCTAssertEqual(
            MachineState(isLocked: true, isOnACPower: false),
            MachineState(isLocked: true, isOnACPower: false)
        )
        XCTAssertEqual(RemoteDevPolicy(), RemoteDevPolicy())
        XCTAssertEqual(ControllerMode.automatic, ControllerMode.automatic)
    }

    func testPolicyDefaultsPreserveCurrentRequirements() {
        let policy = RemoteDevPolicy()

        XCTAssertTrue(policy.requireLocked)
        XCTAssertTrue(policy.requireACPower)
    }
}
