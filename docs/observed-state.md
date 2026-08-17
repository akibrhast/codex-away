# Observed-state discovery

This document records the runtime signals used by Milestone 3. It is based on
the locally installed standalone Codex CLI version `0.147.0`.

## Codex Remote

`codex remote-control` exposes `start`, `stop`, and `pair`. It does not expose a
documented `status` command.

Codex keeps a persistent updater daemon running whether Remote Control is on or
off. Its `settings.json`, `app-server-updater.pid`, and `pid-update-loop`
process therefore must not be used as health signals.

When Remote Control is actually running, Codex creates:

```text
~/.codex/app-server-daemon/app-server.pid
~/.codex/app-server-control/app-server-control.sock
```

The PID file is JSON containing the live Remote Control app-server PID and a
human-readable process start time. The socket is a corroborating lifecycle
signal observed during discovery. `remote-control stop` removes the process,
PID file, and control socket while leaving the updater daemon running.

The PID record is not trusted alone. The controller reports Codex Remote
healthy only when all of these checks pass:

- the PID metadata is valid
- the PID currently exists
- the kernel-reported executable resolves to the configured standalone Codex
  executable
- the kernel-reported arguments are exactly `app-server --remote-control
  --listen unix://`
- the kernel-reported process start time matches the Codex PID record

This excludes interactive Codex sessions, editor integrations, and PID reuse.

The artifact names and Remote Control arguments are implementation details of
Codex 0.147.0 and may change. A future Codex upgrade that changes them should
produce an unhealthy/invalid observation rather than a false healthy result.

## Ownership

Observed health and controller ownership are separate.

The controller stores versioned ownership metadata at:

```text
~/Library/Application Support/CodexAway/service-ownership.json
```

The earlier plain `state` file is migrated once. A legacy value of `on` means
only that this controller previously completed a start command; it does not
prove that Remote Control is currently running.

An unowned but valid Codex Remote daemon can satisfy desired-on state, but the
controller will not stop it when desired state becomes off. The controller
uses `codex remote-control stop` only when ownership is recorded and current
runtime identity is valid. If an owned daemon has been replaced by a different
process instance, stale ownership is cleared without stopping the replacement.
It never signals a Codex PID directly.

## caffeinate

When launching `/usr/bin/caffeinate -s`, the controller records:

- PID
- resolved executable
- exact arguments
- process start seconds and microseconds

After controller restart, all fields must match kernel observations before the
process is adopted or signaled. A missing, stale, reused, or mismatched PID is
cleared without signaling it. Other `caffeinate` processes are ignored.

There is an unavoidable narrow race between final identity validation and
signaling an adopted PID because macOS does not provide a Linux-style pidfd.
Exact start-time validation immediately before signaling minimizes that risk.

## Deliberate limitations

Milestone 3 performs inspection only when reconciliation is triggered by an
existing event. It does not yet add periodic checks, process-exit monitoring,
retry backoff, or recovery loops. Those belong to the async and self-healing
milestones.
