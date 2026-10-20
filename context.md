# Loom — session context

Handoff notes for the next piece of work: letting a handler finish its work
on another thread and reply later, without blocking the event loop. Written
2026-10-20. Reverb's half is in `../reverb/context.md` §8; read both.

`README.md` documents the public API and `TESTING.md` the test method
(every regression test is proven to fail with its bug re-introduced). Keep
to both.

---

## 1. The problem

Loom's sockets are non-blocking, but `Handler.process` runs on the loop
thread and the loop waits for it to return (`Loom.zig` `run`, the
`loom.handler.process(client, msg)` call). A handler that waits on
something slow (a child process, an outbound HTTPS call) stalls every
connection on that loop for as long as it waits.

It is a real case, not a hypothetical one. assembler-backend
(`../assembler-backend`) runs `zig build` for its playground (about 5 s) and
calls the Claude API (seconds to minutes) inside reverb handlers; during
either, the server answers nothing else, not even `GET /`.

`Cluster` does not fix this. N workers turn "the server stalls" into "1/N of
the server stalls", and N concurrent slow requests stall all of it.

## 2. The design

Slow work runs on worker threads. When it finishes, the result travels back
to the loop thread, which alone touches sockets and writes the response.
Loom's part is the travel back, plus three small changes to how a client
behaves while it waits. The worker pool itself is not Loom's: it needs no
loop internals, and its size and policy are per application (see reverb
§8).

### 2.1 `post`: run a callback on the loop thread, from any thread

```zig
pub const Task = struct {
    run: *const fn (*Task) void,
    node: std.DoublyLinkedList.Node = .{}, // or a singly linked next pointer
};

/// Threadsafe. Queues `task` and wakes the loop; `task.run(task)` is
/// called on the loop thread, between event batches. The caller owns
/// `task` and must keep it alive until `run` is called.
pub fn post(loom: *Loom(Handler), task: *Task) void
```

- Intrusive list guarded by a `std.Io.Mutex`, then `loom.poller.wake()`.
  The wake is already threadsafe on both backends (`KQueue.wake` uses its
  own `kevent` call, `Epoll.wake` an eventfd), and `stop()` already relies
  on it.
- In `run`, the `.wake` arm currently `continue`s. It must instead drain
  the posted list: swap it out under the lock, release the lock, then run
  each task. Running tasks outside the lock lets a task post again.
- Drain once per iteration, before `drainCloseQueue`, so a task that closes
  a client is cleaned up in the same iteration.
- `deinit` must still run or free tasks posted after the loop stopped.
  Decide which and document it; reverb needs to free its replies either
  way, so "run them, with the loop marked stopped" is the simpler contract.
- `post` need not be signal-safe (`stop` is the only call that must be).

### 2.2 Client identity that survives reuse

A reply can arrive after its client disconnected and the slot (and the
pooled `Client` memory) went to a new connection. Writing to that would
send one user's response to another.

- Add `generation: u32` to `Client`, set from a per-Loom counter on accept.
- Add a slot table, `clients: []?*Client` indexed by `slot - slot_base`,
  set on accept and cleared in `drainCloseQueue`.
- `pub fn clientAt(loom, slot, generation) ?*Client` returns the client
  only if it is still that connection and not `closing`.

Comparing a stored `*Client` and generation would also work, but only
while `client_pool` never returns memory to the allocator; the reply
would be reading a field of a destroyed object. Looking up by slot keeps
the check inside live state.

### 2.3 Pausing reads while a reply is outstanding

While a request is being worked on, the connection must not be served
again, or pipelined responses come back out of order. Two options:

- **Reverb buffers** further bytes and does not serve them until the reply
  is sent. No Loom change, but the peer can keep sending until reverb's
  request buffer limit.
- **Loom stops reading** (`client.pauseReads()` / `resumeReads()`). The
  kernel buffer fills and TCP pushes back on the peer.

Recommended: Loom stops reading. Note that `continueWrite` calls
`poller.readMode(self)` when a write drains, which re-enables reads; a
paused client must stay paused through that. `readMode`/`writeMode` are in
`KQueue.zig` and `Epoll.zig`; both need the same rule.

### 2.4 The idle timeout

`touchClient` measures progress, and a client waiting on a reply makes
none, so `enforceTimeout` drops it after `idle_timeout_ms` (60 s default).
A Claude call can take longer.

- Add `client.awaiting: bool` (or a separate deadline). While set, the idle
  timeout does not apply; a separate cap does, e.g. `reply_timeout_ms`,
  default 5 min.
- Clear it when the reply is written, then `touchClient`.
- If the cap fires, close the client. The reply arrives later, `clientAt`
  returns null, and the reply is dropped.

### 2.5 Cluster

Each worker is its own `Loom`, so a reply must be posted to the loop that
owns its client. The reply carries that `*Loom`; nothing else changes.
`slot` is already unique server-wide.

## 3. Threads: plain or lock-free

Plain. A mutex-guarded queue is the right tool here.

- The work being moved off the loop takes milliseconds to minutes. A
  mutex costs tens of nanoseconds uncontended and a few microseconds
  contended; the `wake` syscall that follows every post costs more than
  the lock. A lock-free queue would save nothing measurable.
- Lock-free MPMC queues need careful memory ordering and memory
  reclamation (ABA, hazard pointers or epochs). That cost is paid in bugs.
  `src/engine/async/pool/ThreadRipper.zig` is the local example: 1,326
  lines of lock-free work-stealing pool that nothing imports and that no
  longer compiles on Zig 0.16 (`std.Thread.Futex` and `ResetEvent` are
  gone).
- Lock-free pays off when tasks are tiny and numerous: millions a second,
  such as running every request handler on a pool. That is not this
  design, which keeps fast handlers on the loop and moves only slow ones.

Zig 0.16 has the parts: `std.Io.Mutex`, `std.Io.Condition`, and
`std.Io.Queue(T)`, a bounded threadsafe queue with blocking `getOne`,
`put(..., min = 0)` for a non-blocking try-put, and `close()` to end
workers on shutdown.

Delete `ThreadRipper.zig` (and the `Scheduler`/`Fiber` code if it is
equally dead) or bring it back to life deliberately. Do not build this
on it.

## 4. Tests to add (`tests/`, each proven to fail)

| Test | Bug it catches |
| --- | --- |
| A task posted from another thread runs, on the loop thread | `.wake` still just `continue`s; task run on the poster's thread |
| Many threads posting concurrently, every task runs exactly once | unsynchronised list; lost wakeup between swap and wait |
| A task that posts another task | running tasks under the lock (deadlock) |
| `clientAt` returns null after the client closed and a new one took the slot | lookup by pointer, or generation not bumped |
| A paused client's pipelined bytes are not delivered until resumed | `continueWrite` re-arming reads |
| An awaiting client outlives `idle_timeout_ms` and is closed at `reply_timeout_ms` | idle timeout applied while awaiting; cap never enforced |
| Tasks posted after `stop` are run or freed by `deinit` (leak check) | posted list ignored on shutdown |
| The above on epoll as well as kqueue | backend-specific wake or pause bugs |

Run the Linux side as `reverb/context.md` §7 describes (cross-compile the
test binary, run it in Docker).

## 5. Order of work

1. `post` and the wake drain, with its tests.
2. Generation and `clientAt`.
3. Pause/resume reads and the awaiting timeout.
4. README: a "Replying later" section, and the new config field.
5. Then reverb (§8 there), then assembler-backend's build and chat
   handlers.
