# Live desktop thread handoff

## Observed limitation

Remote Control can be healthy and the Mac can be reachable while a particular
desktop conversation still fails to open on iOS.

This was reproduced with standalone Codex `0.147.0` on 2026-08-17. The lock
controller started Remote Control successfully at 02:37:23 EDT. When iOS tried
to open a conversation at 02:41, the Remote Control app-server logged:

```text
failed to initialize thread persistence: thread-store conflict: thread <id>
already has an active writer
```

The iOS UI reported:

```text
Error loading messages: Codex server returned an error.
```

This is not a Remote Control startup or connectivity failure. A desktop Codex
worker still owns the thread's persistence writer, and the separate Remote
Control app-server cannot acquire a second writer for that thread.

Current practical consequences:

- Remote Control can start normally while the desired live thread remains
  unavailable.
- New remote threads may still work.
- A visible conversation is not necessarily resumable from iOS while its
  desktop worker remains live.
- Remote-service health alone is insufficient to prove live-thread handoff is
  ready.

## Workaround

Start a new remote thread, or allow the desktop worker to release the thread
before locking the Mac. Do not broadly kill Codex processes: unrelated turns,
editor integrations, and other conversations may be active.

## Candidate enhancement: idle-worker release

Before or during lock-to-remote activation, inspect Codex desktop workers that
hold conversation writers. If a worker is verifiably idle, request a graceful
shutdown or release so the Remote Control daemon can acquire that thread.

Conceptually:

```text
lock + AC
    ↓
inspect live desktop thread writers
    ↓
writer executing a turn? ── yes ──→ preserve it
    │
    no, and safe idle state is authoritative
    ↓
gracefully release that writer
    ↓
start/verify Remote Control
    ↓
verify the thread can be resumed remotely
```

This must not be implemented using process-name matching, elapsed inactivity,
or the absence of recent output. A worker may appear quiet while it is waiting
for a tool, approval, subtask, or external command.

Minimum safety requirements:

- use an authoritative Codex-provided task/turn state, if available
- identify the exact worker and thread writer, not every Codex process
- preserve workers with a running, queued, waiting, or uncertain turn state
- prefer a supported graceful release/shutdown API over signals
- never terminate a worker merely because the Mac locked
- record why a worker was considered idle and what action was taken
- re-check thread availability after release
- fail closed when state or ownership cannot be proven

If Codex exposes no authoritative idle and graceful-release interfaces, keep
this as a product limitation rather than guessing and risking active work.
