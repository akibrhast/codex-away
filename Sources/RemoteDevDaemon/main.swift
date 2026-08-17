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

    private var codex: String { homeDirectory.appendingPathComponent(".codex/packages/standalone/current/codex").path }
    private var stateDirectory: URL { homeDirectory.appendingPathComponent("Library/Application Support/CodexRemoteOnLock") }
    private var logFile: URL { stateDirectory.appendingPathComponent("controller.log") }
    private lazy var serviceReconciler: ServiceReconciler = {
        let serviceLogger: ServiceLogger = { [weak self] message in
            self?.log(message)
        }
        let commandRunner = ProcessCommandRunner(logger: serviceLogger)
        let codexRemote = CodexRemoteService(
            executable: codex,
            outputURL: logFile,
            commandRunner: commandRunner,
            stateStore: FileServiceStateStore(fileURL: stateDirectory.appendingPathComponent("state")),
            logger: serviceLogger
        )
        let caffeinate = CaffeinateService(
            processFactory: FoundationLongRunningProcessFactory(),
            logger: serviceLogger
        )
        return ServiceReconciler(services: [codexRemote, caffeinate])
    }()

    init() {
        machineState = MachineState(
            isLocked: Self.readInitialLockState(),
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

        log("event listener active; initial lock state: \(machineState.isLocked); AC power: \(machineState.isOnACPower)")
        reconcile(reason: "listener started")
    }

    func powerSourceChanged() {
        machineState.isOnACPower = Self.isOnACPower()
        log("power-source event; AC power: \(machineState.isOnACPower)")
        reconcile(reason: "power source changed")
    }

    private func handleLockedEvent(source: String) {
        machineState.isLocked = true
        log("lock event received from \(source)")
        reconcile(reason: source)
    }

    private func handleUnlockedEvent(source: String) {
        machineState.isLocked = false
        log("unlock event received from \(source)")
        reconcile(reason: source)
    }

    private func handleSessionResigned() {
        log("session-resigned event received; waiting for lock-state update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let isLocked = Self.readInitialLockState()
            self.log("session-resigned verification; IOConsoleLocked: \(isLocked)")
            if isLocked {
                self.handleLockedEvent(source: "verified session-resigned notification")
            }
        }
    }

    private func reconcile(reason: String) {
        let desiredRemoteState = shouldEnableRemoteDev(
            mode: mode,
            machine: machineState,
            policy: policy
        )
        serviceReconciler.reconcile(desiredRemoteState: desiredRemoteState, reason: reason)
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

    private static func readInitialLockState() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-n", "Root", "-d", "1"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return output.contains("\"IOConsoleLocked\" = Yes")
        } catch {
            return false
        }
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
