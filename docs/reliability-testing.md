# Reliability acceptance record

Milestone 10 was accepted on 2026-08-17 against Codex `0.147.0` on the
author's daily-use Mac.

## Results

| Area | Result | Evidence |
| --- | --- | --- |
| Automated suite | Passed | 73 tests, 0 failures |
| Remote Control process exit | Passed | An exact controller-owned process exited; the lifecycle moved `READY → RECOVERING → READY` and a replacement started successfully. |
| AC disconnect and reconnect | Passed | The lifecycle moved `READY → OFF → STARTING → READY`; both managed services stopped and restarted with new identities. |
| Repeated lock and unlock | Passed | Two unlock/lock cycles produced the correct final `READY` state with one Remote Control process and one `caffeinate -s` process. |
| Controller restart reconstruction | Passed from existing evidence | A newly installed controller started after the already-running managed services, reconstructed locked + AC state, retained exact ownership, and converged to `READY` without duplicates. Automated coverage also verifies `caffeinate` re-adoption. |
| Manual Mac → phone → Mac handoff | Passed | The terminal session was released with `Ctrl+C`, the same conversation continued from the phone while the Mac was locked, and local use resumed after unlock. |
| Automatic per-thread handoff | Blocked upstream | Codex exposes authoritative activity state but no safe immediate per-thread release mechanism. See [Live desktop thread handoff](live-thread-handoff.md). |
| Sleep/wake recovery | Deferred | Managed `caffeinate -s` prevents sleep in the primary locked + AC workflow. |
| Network recovery | Deferred | Revisit only after a repeatable real-world reconnection failure. |

## Process-exit observation

The recovery test sent `SIGTERM` only after matching the ownership record's
PID, resolved executable, arguments, and process identity. The process took
slightly longer than the initial 40-second observation window to exit. The
controller then detected the exit at `15:21:32Z`, restarted Remote Control, and
reported recovery at `15:21:36Z`.

The delayed graceful exit is not a controller failure. Future manual observers
should allow at least 60 seconds before declaring this test failed. An unrelated
Codex app-server process remained alive throughout the test.

## AC transition observation

With the Mac locked and its lid open:

- AC loss at `15:27:00Z` produced `READY → OFF` and stopped the exact owned
  Remote Control and `caffeinate` processes.
- AC restoration at `15:27:40Z` produced `OFF → STARTING → READY` by
  `15:27:43Z`.
- The phone reconnected to Remote Control after AC restoration.

## Lock/unlock observation

The controlled sequence `unlock → lock → unlock → lock` completed without
duplicate services or a restart storm. Each unlock converged to `OFF`; each lock
converged through `STARTING` to `READY`. The final ownership records matched the
single live Remote Control and `caffeinate` processes.

## Acceptance boundary

This record establishes reliability for the primary workflow:

```text
locked + AC power → Remote Control and sleep prevention are READY
unlocked or battery power → controller-owned services are OFF
exact managed-process failure → bounded self-healing recovery
```

It does not claim sleep/wake recovery, dedicated network recovery, captive
portal reauthentication, or automatic release of a live desktop thread writer.
