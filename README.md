# Codex Remote on Lock

Codex Remote on Lock is a small, event-driven macOS LaunchAgent for making a Mac available through Codex Remote only when it is unattended and connected to power.

When the screen locks while the Mac is using AC power, it starts:

- `codex remote-control start`
- `caffeinate -s`, preventing system sleep while AC power remains connected

When the screen unlocks or AC power is disconnected, it stops both. The listener uses macOS session notifications and IOKit power-source events; it does not poll on a timer.

## What it is useful for

Use this when you want to reach Codex running on your Mac from another authorized device, such as the ChatGPT iOS app, without leaving Remote Control enabled while you are actively using the Mac.

It is particularly useful for a MacBook that acts as an occasional remote development machine while docked or charging.

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

To reinstall after changing the source, run `./install.sh` again. It recompiles the listener, replaces the installed binary, and reloads the LaunchAgent.
