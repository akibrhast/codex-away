# Troubleshooting Codex Away

## Verify operation

Check that the listener is loaded:

```sh
launchctl print "gui/$(id -u)/com.akibrhast.codex-away"
```

Follow its activity log:

```sh
tail -f "$HOME/Library/Application Support/CodexAway/controller.log"
```

While connected to AC power, lock and unlock the Mac. The log should show:

```text
lock event received
remote control started
caffeinate started
unlock event received
remote control stopped
caffeinate stopped
```

Inspect active power assertions with:

```sh
pmset -g assertions
```

## The listener does not start

Inspect the LaunchAgent error log:

```sh
cat "$HOME/Library/Application Support/CodexAway/launchd-error.log"
```

Reinstall the latest published release:

```sh
curl -fsSL https://raw.githubusercontent.com/akibrhast/codex-away/main/install.sh | sh
```

The installer replaces the installed binary and reloads the LaunchAgent.

Installed paths are:

```text
~/Library/Application Support/CodexAway/codex-away
~/Library/LaunchAgents/com.akibrhast.codex-away.plist
```

## A live desktop conversation fails to load remotely

If iOS displays `Error loading messages: Codex server returned an error`, but
the controller log says Remote Control started successfully, inspect:

```sh
tail "$HOME/.codex/app-server-daemon/app-server.stderr.log"
```

An `already has an active writer` error means the Mac is reachable but a live
desktop worker still owns that conversation. Start a new remote thread or
release the desktop session before locking. Do not kill arbitrary Codex
processes.

See [Live desktop thread handoff](live-thread-handoff.md) for more detail.

## Remote commands hang in Desktop or Downloads threads

macOS protects folders such as `Desktop` and `Downloads` with Files and Folders
privacy controls. A background Codex process may need permission before it can
resume a thread whose working directory is in one of those locations.

If the Mac is locked, the permission dialog is not visible remotely. Unlock the
Mac, approve the prompt, and verify the relevant access under **System Settings
→ Privacy & Security → Files and Folders**. Lock the Mac again and retry with a
fresh read-only command such as `pwd`.

Full Disk Access is broader than necessary and should not be granted unless the
narrower Files and Folders permission proves insufficient.
