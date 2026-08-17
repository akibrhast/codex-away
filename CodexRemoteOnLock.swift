import AppKit
import Foundation
import IOKit.ps

final class Controller {
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var locked = false
    private var caffeinate: Process?

    private var codex: String { homeDirectory.appendingPathComponent(".codex/packages/standalone/current/codex").path }
    private var stateDirectory: URL { homeDirectory.appendingPathComponent("Library/Application Support/CodexRemoteOnLock") }
    private var stateFile: URL { stateDirectory.appendingPathComponent("state") }
    private var logFile: URL { stateDirectory.appendingPathComponent("controller.log") }

    init() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        locked = Self.readInitialLockState()
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleLockedEvent(source: "distributed screen-lock notification")
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleUnlockedEvent(source: "distributed screen-unlock notification")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSessionResigned()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleUnlockedEvent(source: "user session became active")
        }

        log("event listener active; initial lock state: \(locked); AC power: \(Self.isOnACPower())")
        reconcile(reason: "listener started")
    }

    func powerSourceChanged() {
        log("power-source event; AC power: \(Self.isOnACPower())")
        reconcile(reason: "power source changed")
    }

    private func handleLockedEvent(source: String) {
        locked = true
        log("lock event received from \(source)")
        reconcile(reason: source)
    }

    private func handleUnlockedEvent(source: String) {
        locked = false
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
        if locked && Self.isOnACPower() {
            startManagedServices(reason: reason)
        } else {
            stopManagedServices(reason: reason)
        }
    }

    private func startManagedServices(reason: String) {
        if readState() != "on" {
            let result = run(codex, ["remote-control", "start"])
            guard result == 0 else {
                log("remote-control start failed (exit \(result)); trigger: \(reason)")
                return
            }
            writeState("on")
            log("remote control started; trigger: \(reason)")
        }

        if caffeinate?.isRunning != true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-s"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                caffeinate = process
                log("caffeinate started (pid \(process.processIdentifier))")
            } catch {
                log("caffeinate start failed: \(error)")
            }
        }
    }

    private func stopManagedServices(reason: String) {
        if readState() == "on" {
            let result = run(codex, ["remote-control", "stop"])
            if result == 0 {
                writeState("off")
                log("remote control stopped; trigger: \(reason)")
            } else {
                log("remote-control stop failed (exit \(result)); trigger: \(reason)")
            }
        }

        if let process = caffeinate, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            log("caffeinate stopped (pid \(process.processIdentifier))")
        }
        caffeinate = nil
    }

    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            log("failed to run \(executable): \(error)")
            return 127
        }
    }

    private func readState() -> String {
        (try? String(contentsOf: stateFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    private func writeState(_ state: String) {
        try? state.write(to: stateFile, atomically: true, encoding: .utf8)
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
    Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
}

let context = Unmanaged.passUnretained(controller).toOpaque()
if let source = IOPSNotificationCreateRunLoopSource(powerCallback, context)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}

RunLoop.main.run()
