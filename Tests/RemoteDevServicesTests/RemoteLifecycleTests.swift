import Foundation
import XCTest
@testable import RemoteDevServices

final class RemoteLifecycleTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 100)

    func testOffBeginsStartingWhenRemoteBecomesDesired() {
        let result = RemoteLifecycleEvaluator.begin(
            previous: snapshot(.off),
            desiredRemoteState: true,
            reason: "screen locked",
            revision: 2,
            at: date
        )

        XCTAssertEqual(result.phase, .starting)
        XCTAssertEqual(result.reason, "screen locked")
        XCTAssertEqual(result.revision, 2)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.transitionedAt, date)
    }

    func testReadyBeginsRecoveringWhenReconciledWhileStillDesired() {
        let result = RemoteLifecycleEvaluator.begin(
            previous: snapshot(.ready),
            desiredRemoteState: true,
            reason: "health audit",
            revision: 3,
            requiredServicesHealthy: false,
            at: date
        )

        XCTAssertEqual(result.phase, .recovering)
    }

    func testErrorRetriesThroughStarting() {
        let result = RemoteLifecycleEvaluator.begin(
            previous: snapshot(.error),
            desiredRemoteState: true,
            reason: "state changed",
            revision: 4,
            at: date
        )

        XCTAssertEqual(result.phase, .starting)
    }

    func testPolicyFalseTransitionsEveryPhaseToOff() {
        for phase in RemoteLifecyclePhase.allTestCases {
            let result = RemoteLifecycleEvaluator.begin(
                previous: snapshot(phase),
                desiredRemoteState: false,
                reason: "screen unlocked",
                revision: 5,
                at: date
            )
            XCTAssertEqual(result.phase, .off, "failed from \(phase)")
            XCTAssertNil(result.failure)
        }
    }

    func testHealthyRequiredServicesCompleteReadyDespiteOptionalFailure() {
        let report = makeReport(
            observations: [
                ServiceObservation(serviceID: "codex", required: true, health: .healthy),
                ServiceObservation(serviceID: "optional", required: false, health: .unhealthy("failed")),
            ]
        )

        let result = RemoteLifecycleEvaluator.complete(
            inProgress: snapshot(.starting),
            report: report,
            at: date
        )

        XCTAssertEqual(result.phase, .ready)
        XCTAssertNil(result.failure)
    }

    func testRequiredFailureCompletesErrorAndRecordsFailure() {
        let report = makeReport(
            observations: [
                ServiceObservation(serviceID: "codex", required: true, health: .unhealthy("not running")),
            ]
        )

        let result = RemoteLifecycleEvaluator.complete(
            inProgress: snapshot(.starting),
            report: report,
            at: date
        )

        XCTAssertEqual(result.phase, .error)
        XCTAssertEqual(result.failure, "codex is unhealthy: not running")
    }

    func testRecoverySuccessCompletesReady() {
        let result = RemoteLifecycleEvaluator.complete(
            inProgress: snapshot(.recovering),
            report: makeReport(
                observations: [
                    ServiceObservation(serviceID: "codex", required: true, health: .healthy),
                ]
            ),
            at: date
        )

        XCTAssertEqual(result.phase, .ready)
    }

    private func snapshot(_ phase: RemoteLifecyclePhase) -> RemoteLifecycleSnapshot {
        RemoteLifecycleSnapshot(
            phase: phase,
            reason: "previous",
            failure: phase == .error ? "old failure" : nil,
            revision: 1,
            transitionedAt: date
        )
    }

    private func makeReport(
        observations: [ServiceObservation]
    ) -> ReconciliationReport {
        ReconciliationReport(
            desiredRemoteState: true,
            reason: "test",
            observations: observations,
            operations: []
        )
    }
}

private extension RemoteLifecyclePhase {
    static let allTestCases: [RemoteLifecyclePhase] = [
        .off, .starting, .ready, .recovering, .error,
    ]
}
