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

## Capability discovery — 2026-08-17

Phase A was evaluated against Codex CLI and app-server `0.147.0`. The installed
stable and experimental app-server schemas were generated and compared with
the official app-server documentation and source.

### What Codex exposes authoritatively

- `thread/read` returns the exact thread ID and its runtime status without
  resuming or subscribing to the thread.
- Runtime thread status is one of `notLoaded`, `idle`, `systemError`, or
  `active`. Active status includes flags such as `waitingOnApproval`.
- Turn status is one of `completed`, `interrupted`, `failed`, or `inProgress`.
- `thread/loaded/list` reports the exact thread IDs loaded in one app-server
  process.
- `thread/status/changed`, `turn/started`, and `turn/completed` provide
  authoritative lifecycle transitions for threads owned by that app-server.

These interfaces are sufficient to reject active, errored, or unknown state
and to identify an idle thread inside one app-server process. They do not
provide a cross-process command that asks another app-server to release its
writer.

### Release mechanisms and their scope

The only stable per-thread detach operation is `thread/unsubscribe`. It removes
the calling connection's event subscription; it does not immediately unload
the thread. After the last subscriber leaves, app-server deliberately retains
the thread until it has had no subscribers and no activity for 30 minutes.
Only then does it transition to `notLoaded` and emit `thread/closed`.

Codex does provide a broader graceful release mechanism: normal shutdown of
the process that owns the writer. For a terminal session, pressing `Ctrl+C`
exits the Codex TUI cleanly and leaves the session resumable by exact ID. The
managed Remote Control daemon likewise releases its owned writers when it is
stopped normally after Mac unlock or AC-policy deactivation.

This manual round-trip handoff is verified:

```text
Mac terminal owns thread
    ↓ Ctrl+C (normal TUI shutdown)
lock Mac
    ↓ managed Remote Control starts
phone resumes the same thread
    ↓ unlock Mac; managed Remote Control stops normally
codex resume <session-id>
    ↓
Mac terminal resumes the same thread
```

This process-level release is not equivalent to an automatic per-thread
release. One app-server process can own multiple loaded threads, and stopping
it may affect unrelated conversations or active work.

### Manual round-trip acceptance result

The user verified the complete workflow with a real conversation:

1. The conversation was active in a Mac terminal.
2. `Ctrl+C` shut down the terminal owner normally.
3. After the Mac was locked, the phone opened and continued the exact same
   conversation.
4. After Mac unlock stopped managed Remote Control, the same conversation was
   resumed from the Mac by session ID.

This satisfies the manual terminal → phone → terminal acceptance path. It does
not satisfy automatic handoff while an owning desktop or terminal process is
left running.

No stable or experimental method in the `0.147.0` generated protocol provides
an immediate graceful per-thread unload, writer release, ownership transfer,
or configurable reduction of that grace period. `turn/interrupt` is not a
substitute: it cancels active work and does not release an idle thread writer.

Official reference:
[Codex App Server](https://developers.openai.com/codex/app-server).

### Controlled CLI experiment

A disposable persisted session was created, then resumed by exact UUID from
two terminal clients at the same time.

Observed behavior:

1. Terminal A resumed the idle session successfully.
2. Terminal B also resumed the same session successfully; no writer conflict
   occurred merely by attaching twice.
3. Terminal A started a deliberately long-running turn.
4. Terminal B displayed the same live turn and offered to queue input instead
   of acquiring an independent writer or reporting a store conflict.
5. Both clients exited normally and reported the same resumable session ID.

This disproves the narrower hypothesis that two `codex resume <session-id>`
invocations necessarily reproduce the desktop-to-Remote conflict. Both CLI
clients joined the same managed app-server runtime and behaved as cooperative
subscribers.

### Process boundary

The controlled test showed two distinct Codex app-server processes:

- the managed Remote Control daemon, running the standalone Codex `0.147.0`
  app-server with Remote Control enabled
- a separate desktop-client app-server process

The observed writer conflict occurs across those independent app-server
processes. Multiple clients attached to one managed daemon do not reproduce
it. Therefore, a safe handoff needs one of the following upstream capabilities:

- an immediate, graceful unload of one exact idle thread in the desktop
  app-server; or
- a supported way for desktop and Remote Control clients to attach to the same
  app-server owner.

### Phase A decision

Authoritative idle-state evidence and a supported manual process-lifecycle
release both exist. A supported immediate release of one exact thread does not.
Therefore:

- the manual terminal → phone → terminal workflow is verified
- fully automatic per-thread handoff does not yet satisfy Phase B's isolation
  gate on Codex `0.147.0`

Do not automate signals, forced process termination, app-wide shutdown,
archive, delete, inactivity guesses, or the 30-minute unsubscribe delay as a
substitute. Re-evaluate automatic handoff after Codex adds a per-thread unload
or shared-owner attachment mechanism. Normal user-requested `Ctrl+C` and the
controller's existing graceful shutdown of its own managed Remote Control
daemon remain supported lifecycle actions.
