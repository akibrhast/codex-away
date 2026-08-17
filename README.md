# Codex Remote on Lock

Codex Remote on Lock is a small, event-driven macOS LaunchAgent for making a Mac available through Codex Remote only when it is unattended and connected to power.

See [ROADMAP.md](ROADMAP.md) for the canonical project scope, completed
milestones, and approved implementation order.

The primary workflow's automated and manual acceptance evidence is recorded in
[Reliability acceptance testing](docs/reliability-testing.md).

When the screen locks while the Mac is using AC power, it starts:

- `codex remote-control start`
- `caffeinate -s`, preventing system sleep while AC power remains connected

When the screen unlocks or AC power is disconnected, it stops both. The listener uses macOS session notifications and IOKit power-source events; it does not poll on a timer.

## What it is useful for

Use this when you want to reach Codex running on your Mac from another authorized device, such as the ChatGPT iOS app, without leaving Remote Control enabled while you are actively using the Mac.

It is particularly useful for a MacBook that acts as an occasional remote development machine while docked or charging.

Remote availability does not currently guarantee takeover of a conversation
that is still owned by a live desktop Codex worker. See
[Live desktop thread handoff](docs/live-thread-handoff.md) for the reproduced
active-writer conflict, workaround, and candidate idle-worker release design.

## Requirements

- macOS
- Xcode or Xcode Command Line Tools, including `swiftc`
- The standalone Codex installation managed by the official installer
- Codex Remote Control configured and tested at least once

The standalone Codex executable must exist at:

```text
~/.codex/packages/standalone/current/codex
```

If needed, install it with:

```sh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Then verify Remote Control manually:

```sh
codex remote-control start
codex remote-control stop
```

## Install

Clone the repository and run:

```sh
./install.sh
```

The installer compiles the Swift listener and installs:

```text
~/Library/Application Support/CodexRemoteOnLock/codex-remote-on-lock
~/Library/LaunchAgents/com.openai.codex.remote-on-lock.plist
```

The LaunchAgent starts automatically for the current user at login.

## Verify operation

Check that the listener is loaded:

```sh
launchctl print "gui/$(id -u)/com.openai.codex.remote-on-lock"
```

Follow its activity log:

```sh
tail -f "$HOME/Library/Application Support/CodexRemoteOnLock/controller.log"
```

While connected to AC power, lock and unlock the Mac. The log should show a sequence similar to:

```text
lock event received
remote control started
caffeinate started
unlock event received
remote control stopped
caffeinate stopped
```

You can inspect active power assertions with:

```sh
pmset -g assertions
```

## Uninstall

Run:

```sh
./uninstall.sh
```

This unloads the LaunchAgent, stops Codex Remote Control, and removes the installed executable and plist. Logs and state are intentionally retained under `~/Library/Application Support/CodexRemoteOnLock` for troubleshooting.

## How it works

The listener subscribes to:

- macOS screen-lock and screen-unlock notifications
- `NSWorkspace` session activation changes
- IOKit's power-source change callback

At startup it reads the current lock and AC-power state once, then waits for events. There is no periodic timer.

The listener tracks whether it enabled Codex Remote Control. It keeps the display free to turn off; `caffeinate -s` prevents system sleep only while running on AC power.

## Security considerations

- Codex Remote Control makes the Mac available to devices authorized through your Codex account. Review your authorized devices and account security before enabling it.
- This project does not store Codex credentials, passwords, or API keys.
- The automation runs only for the user who installs it.
- Locking the screen does not replace full-disk encryption, a strong login password, or secure account configuration.
- Codex currently labels `remote-control` experimental, so command behavior may change in future releases.

## Troubleshooting

If the listener does not start, inspect:

```sh
cat "$HOME/Library/Application Support/CodexRemoteOnLock/launchd-error.log"
```

### A live desktop conversation fails to load remotely

If iOS displays `Error loading messages: Codex server returned an error`, but
the controller log says Remote Control started successfully, inspect:

```sh
tail "$HOME/.codex/app-server-daemon/app-server.stderr.log"
```

An `already has an active writer` error means a live desktop Codex worker still
owns that conversation. The Mac is reachable; only that thread's handoff is
blocked. Start a new remote thread or let the desktop worker release the thread
before locking. Do not kill arbitrary Codex processes. See
[docs/live-thread-handoff.md](docs/live-thread-handoff.md).

### Remote commands hang in Desktop or Downloads threads

macOS protects folders such as `Desktop` and `Downloads` with Files and
Folders privacy controls. The first time the background Codex process resumes
a thread whose working directory is one of these locations, macOS may request
permission to access that folder.

If the Mac is locked, the permission dialog is not visible on the remote
device. The iOS app can still display and continue the thread, but even simple
commands such as `pwd` or `date` may appear to hang. Interrupted commands can
then report exit code `130`. This is separate from Codex command approval and
does not indicate a problem with the file being accessed.

To fix it:

1. Unlock the Mac and approve the macOS prompts for Desktop and Downloads
   access.
2. Open **System Settings → Privacy & Security → Files and Folders** and verify
   that the relevant folder access is enabled for Codex.
3. Lock the Mac again. This LaunchAgent will restart Remote Control with the
   newly granted permissions.
4. Send a fresh read-only command, such as `pwd`, from an existing Desktop or
   Downloads thread in the iOS app.

Ordinary commands should then complete normally. A command that changes or
deletes files may still require a separate Codex approval. Full Disk Access is
broader than necessary and should not be granted unless Files and Folders
permissions prove insufficient.

To reinstall after changing the source, run `./install.sh` again. It recompiles the listener, replaces the installed binary, and reloads the LaunchAgent.

## Development

The project is organized as a Swift package:

```text
Sources/
├── RemoteDevCore/       State, policy, and policy evaluation
├── RemoteDevServices/   Managed-service lifecycle and system boundaries
└── RemoteDevDaemon/     macOS events and service control

Tests/
├── RemoteDevCoreTests/      Unit tests for core policy behavior
└── RemoteDevServicesTests/  Service and reconciliation unit tests
```

Run the test suite:

```sh
swift test
```

Build the release executable without installing or reloading the LaunchAgent:

```sh
swift build --configuration release --product codex-remote-on-lock
```

The daemon currently runs with an automatic policy requiring both a locked
screen and AC power. The core also defines force-on and force-off modes for a
future CLI, but they are not exposed to users yet.

Codex Remote and `caffeinate` implement a common managed-service lifecycle.
External commands run asynchronously with bounded output, cancellation, and
timeouts. Reconciliation is serialized and coalesces pending machine-state
changes so the newest lock and power policy wins.
The coordinator also derives an internal `OFF`, `STARTING`, `READY`,
`RECOVERING`, or `ERROR` lifecycle from desired policy and observed required
service health, recording transition reasons and failures in the controller log.
While remote mode remains desired, exact validated service PIDs are monitored
for exit and checked by a bounded health audit. Required-service failures use
three serialized recovery attempts with bounded exponential backoff; unlock or
AC disconnection cancels all monitoring and pending recovery immediately.
Health checks validate actual process identity and keep observed state separate
from controller ownership. Legacy state is migrated to versioned ownership
metadata, and controller-owned `caffeinate` can be safely re-adopted after a
daemon restart. See [docs/observed-state.md](docs/observed-state.md) for the
Codex runtime signals, ownership rules, and version assumptions.
