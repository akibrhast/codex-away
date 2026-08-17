import AppKit
import Foundation
import IOKit.ps
import RemoteDevCore
import RemoteDevServices

@MainActor
final class Controller {
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let mode = ControllerMode.automatic
    private let policy = RemoteDevPolicy()
    private var machineState: MachineState
    private var stateRevision: UInt64 = 0

    private var codex: String { homeDirectory.appendingPathComponent(".codex/packages/standalone/current/codex").path }
    private var stateDirectory: URL { homeDirectory.appendingPathComponent("Library/Application Support/CodexRemoteOnLock") }
    private var logFile: URL { stateDirectory.appendingPathComponent("controller.log") }
    private let commandRunner: any CommandRunning = ProcessCommandRunner()
    private lazy var reconciliationCoordinator: ReconciliationCoordinator = {
        let serviceLogger: ServiceLogger = { [weak self] message in
            self?.log(message)
        }
        let processInspector = DarwinProcessInspector()
        let ownershipStore = FileServiceOwnershipStore(
            fileURL: stateDirectory.appendingPathComponent("service-ownership.json"),
            legacyCodexStateURL: stateDirectory.appendingPathComponent("state")
        )
        let codexDaemonDirectory = homeDirectory.appendingPathComponent(".codex/app-server-daemon")
        let codexRemote = CodexRemoteService(
            executable: codex,
            commandRunner: commandRunner,
            runtimeInspector: FileCodexRuntimeInspector(
                pidURL: codexDaemonDirectory.appendingPathComponent("app-server.pid"),
                expectedExecutable: codex,
                processInspector: processInspector
            ),
            ownershipStore: ownershipStore,
            logger: serviceLogger
        )
        let caffeinate = CaffeinateService(
            processFactory: FoundationLongRunningProcessFactory(),
            processInspector: processInspector,
            processSignaler: DarwinProcessSignaler(),
            ownershipStore: ownershipStore,
            logger: serviceLogger
        )
        return ReconciliationCoordinator(
            reconciler: ServiceReconciler(services: [codexRemote, caffeinate])
        )
    }()

    init() {
        machineState = MachineState(
            isLocked: false,
            isOnACPower: Self.isOnACPower()
        )
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLockedEvent(source: "distributed screen-lock notification")
            }
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUnlockedEvent(source: "distributed screen-unlock notification")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionResigned()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUnlockedEvent(source: "user session became active")
            }
        }

        log("event listener active; reading initial lock state asynchronously; AC power: \(machineState.isOnACPower)")
        let revision = stateRevision
        Task { [weak self] in
            await self?.finishInitialStateRead(expectedRevision: revision)
        }
    }

    func powerSourceChanged() {
        stateRevision &+= 1
        machineState.isOnACPower = Self.isOnACPower()
        log("power-source event; AC power: \(machineState.isOnACPower)")
        reconcile(reason: "power source changed")
    }

    private func handleLockedEvent(source: String) {
        stateRevision &+= 1
        machineState.isLocked = true
        log("lock event received from \(source)")
        reconcile(reason: source)
    }

    private func handleUnlockedEvent(source: String) {
        stateRevision &+= 1
        machineState.isLocked = false
        log("unlock event received from \(source)")
        reconcile(reason: source)
    }

    private func handleSessionResigned() {
        log("session-resigned event received; waiting for lock-state update")
        let revision = stateRevision
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.verifySessionResigned(expectedRevision: revision)
        }
    }

    private func reconcile(reason: String) {
        let desiredRemoteState = shouldEnableRemoteDev(
            mode: mode,
            machine: machineState,
            policy: policy
        )
        reconciliationCoordinator.submit(
            desiredRemoteState: desiredRemoteState,
            reason: reason
        )
    }

    private func finishInitialStateRead(expectedRevision: UInt64) async {
        guard let isLocked = await readLockState() else {
            guard expectedRevision == stateRevision else { return }
            log("initial lock-state query failed; defaulting to unlocked")
            reconcile(reason: "listener started with unknown lock state")
            return
        }
        guard expectedRevision == stateRevision else {
            log("initial lock-state result ignored because a newer event arrived")
            return
        }
        machineState.isLocked = isLocked
        log("initial lock state: \(isLocked); AC power: \(machineState.isOnACPower)")
        reconcile(reason: "listener started")
    }

    private func verifySessionResigned(expectedRevision: UInt64) async {
        guard expectedRevision == stateRevision else { return }
        guard let isLocked = await readLockState() else {
            log("session-resigned lock-state verification failed")
            return
        }
        guard expectedRevision == stateRevision else {
            log("session-resigned lock-state result ignored because a newer event arrived")
            return
        }
        log("session-resigned verification; IOConsoleLocked: \(isLocked)")
        if isLocked {
            handleLockedEvent(source: "verified session-resigned notification")
        }
    }

    private func readLockState() async -> Bool? {
        do {
            let result = try await commandRunner.run(
                executable: "/usr/sbin/ioreg",
                arguments: ["-n", "Root", "-d", "1"],
                timeout: 5
            )
            guard result.exitStatus == 0 else { return nil }
            return result.stdout.contains("\"IOConsoleLocked\" = Yes")
        } catch {
            log("lock-state command failed: \(error)")
            return nil
        }
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
            _ = try? handle.close()
        }
    }

    private static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return false }
        return source as String == kIOPSACPowerValue as String
    }

}

let controller = Controller()
_ = NSApplication.shared
controller.start()

let powerCallback: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    MainActor.assumeIsolated {
        Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
    }
}

let context = Unmanaged.passUnretained(controller).toOpaque()
if let source = IOPSNotificationCreateRunLoopSource(powerCallback, context)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}

RunLoop.main.run()
