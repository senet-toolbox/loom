# Testing

```
zig build test               # everything
zig build test-unit
zig build test-integration
```

CI runs all of it on Linux and macOS, in `Debug` and `ReleaseSafe`.

## How these tests were written

An event loop fails in ways unit tests structurally cannot reach: a
pointer freed while another event in the same batch still refers to it, a
listener that never re-arms, a loop that spins instead of parking, a
deadline that fires on a connection that is doing fine. None of that is a
function returning the wrong value. All of it needs a real socket, a real
peer, and a server that has been running long enough to get into the
state.

So the suite stands up real `Loom` servers on ephemeral ports, on their
own threads inside the test process, and drives them over real sockets —
including things a polite client would not do: hanging up mid-response,
sending `RST` instead of `FIN`, asking for a large response and then
refusing to read it. Running in-process is deliberate: a panic, an
unhandled signal, or a wedged loop takes the test binary down with it,
which is exactly the failure we want reported.

## Every regression test was proven to fail

A test that passes against broken code is worse than no test, because it
converts an absence of coverage into a false sense of it. So each
regression test here was validated the same way:

1. Write the test against the fixed code. Watch it pass.
2. Re-introduce the original bug.
3. Confirm the test now **fails**.
4. Restore, confirm it passes again.

If step 3 didn't fail, the test was wrong and got rewritten — that
happened several times, and the details are in *What went wrong* below.
On the flakier stress tests the check was run repeatedly to get a rate
rather than a single observation.

Reproducing it is mechanical: revert the named change, run the named
test, watch it go red.

### The matrix

| Injected bug | Test that catches it |
| --- | --- |
| `closeClient` frees the client inside the event batch (use-after-free) | graceful closes mid-response do not kill the server |
| Listener parked at capacity is never re-armed | server accepts again after connections free up |
| Accept loop spins instead of parking when full | saturation does not starve established connections |
| `SO_NOSIGPIPE` not set on accepted sockets | accepted sockets have SIGPIPE suppressed |
| Per-connection timeout node never freed | connection churn does not grow the allocation footprint |
| Event loop ignores the timeout deadline | idle connections are dropped once the deadline passes |
| Deadline never refreshed on activity | active connections are never dropped by the timeout |
| Deadline arithmetic mixes seconds and milliseconds | idle connections are dropped once the deadline passes |
| `idle_timeout_ms = 0` treated as "expire now" | a zero timeout disables expiry |
| Timed-out connection closed but its slot never returned | timed-out connections return their slot |
| `stop` sets the flag but never wakes the loop | stop wakes a loop parked with no work |
| Loop ignores the running flag | stop makes serve return |
| `deinit` leaves live connections open | stop tears down live connections |
| One read buffer shared by every connection | one connection's data is not disturbed by another's |
| Read buffer never grows | read buffers grow for connections that need them |
| Read buffers preallocated at worst case | a fresh server does not preallocate the worst-case read memory |
| Read buffer ceiling not enforced | read buffers stay within the configured ceiling |
| Cluster workers given overlapping slot ranges | workers never hand out overlapping slots |
| Only one worker registers the shared listener | cluster: load spreads across workers |
| Workers close a listener they only borrowed | cluster serves requests |
| `deinit` skips per-worker state | cluster: stop and deinit release everything |
| Wake eventfd never registered (epoll) | stop wakes a loop parked with no work |
| Listener never re-added after parking (epoll) | server accepts again after connections free up |
| `EPOLLOUT` dropped from write registration | responses larger than the socket buffer are resumed correctly |
| Read/write mode never flipped back after a parked write | keep-alive still works after a response that had to park |
| `write` borrows the caller's payload | a payload may be reused the moment write returns |
| `max_body_size` not enforced | writes beyond max_body_size are refused, not truncated |
| Large-write copy buffer leaked on close | large-write copy buffers are released with the connection |

Backend-specific rows were verified on the platform that owns them;
`write`-ownership and read/write-mode rows were verified on both.

## What went wrong

The interesting part, and the reason for the discipline above. Every one
of these was a case where the testing itself was lying.

**`zig build test-unit` ran zero tests.** Zig only collects `test` blocks
from the *root* file of a test binary. Every unit test in this repo had
therefore never executed. Two of them had rotted invisibly: a `Logger`
test calling a function with the wrong arity, and `wss_deflate.zig`,
which did not compile at all against Zig 0.16. Fixed by naming each file
explicitly in `src/root.zig`.

**Benchmarks measuring nothing.** The first multi-worker numbers were
flat — 160k req/s regardless of worker count — which looked like the
cluster not working. The handler's synthetic work loop was
constant-foldable and LLVM had deleted it, so every worker was idle and
one won every accept race. Reseeding the work from the request made it
opaque, and the real curve appeared: 1.00× / 1.90× / 3.58× / 5.16× across
1, 2, 4 and 8 workers.

**A whole code path unexercised on one platform.** Probing by making
`writeMode` always fail showed macOS failing the suite and Linux passing
it *entirely* — the async write path was never reached there. Linux
autotunes socket send buffers to several megabytes, so a 1 MiB response
is accepted whole and `EAGAIN` never happens. The most intricate part of
the epoll backend had no coverage on its own platform. Fixed with a
response larger than any plausible send buffer plus a throttled reader.

**Mode-flipping untested on both platforms.** Disabling `readMode`
outright passed the entire suite. The keep-alive test's responses are too
small to ever park a write, so the connection never leaves read mode. A
large response followed by another request on the same connection — an
ordinary HTTP pattern — had no coverage anywhere.

**A test that hung instead of failing.** Removing the shutdown wake made
the parked-loop test block forever rather than fail. A hanging test
reports nothing in CI, so waits now run against a deadline and fail
loudly.

**A broken harness reporting confident results.** One bug-injection run
used `timeout`, which does not exist on macOS. Every invocation exited
127 and the script counted that as both "suite failing" and "bug caught".
The numbers were meaningless in both directions until it was rerun with a
real watchdog.

**Load generators as the bottleneck.** Throughput numbers from
connection-churn benchmarks did not correlate with the server's own
accept counts — roughly 2× apart — because the generator was doing as
much connection setup work as the server. Those numbers were discarded;
only the ratios measured *inside* the server were kept.

## Known gaps

Stated because a coverage claim is only worth the exceptions it admits.

- **The read-buffer ceiling is enforced twice**, in the growth flag and
  again in the grow function. Removing either alone leaves the buffer
  correctly capped, so that test only fails when both go. It guards the
  property, not any single line.
- **SIGPIPE suppression is asserted as an invariant, not a race.** The
  test reads back `SO_NOSIGPIPE` on an accepted socket rather than trying
  to schedule a disconnect into the window between two writes. That
  window is real — it is how the bug was found — but it is not
  reproducible on demand. On Linux, where the mechanism is `MSG_NOSIGNAL`
  per write and there is no socket option to read back, that test skips;
  a unit test on a `socketpair` covers the write path instead.
- **Cluster load distribution asserts participation, not proportions.**
  The split is up to the kernel's accept race, so the test requires every
  worker to take a share rather than pinning percentages.
- **Outbound websocket `permessage-deflate` is not covered** because it
  is not implemented on Zig 0.16; that test skips.

## Measurements

Facts established by experiment rather than assumption, each of which
changed a design decision.

**Darwin does not load-balance `SO_REUSEPORT`.** Four listeners bound to
one port, 40 connections: all 40 went to the last-bound socket, three
runs running. This is Linux-only behaviour. The planned per-worker
listener design would have left every worker but one idle, so the cluster
uses a shared listener instead.

**The accept race balances by availability.** With a shared listener,
distribution across four workers depends entirely on how busy they are:

| per-connection work | distribution |
| --- | --- |
| 0 µs | `{0, 9, 2, 189}` |
| 200 µs | `{35, 59, 49, 57}` |
| 2000 µs | `{24, 24, 24, 24}` |

A worker inside a handler is not parked in `kevent` ready to win, so
connections drift toward idle workers. That is load-proportional, which
is better than round-robin: a slow worker stops taking work.

**Thundering herd is real and irrelevant.** Sharing a listener means
several workers wake per connection and all but one lose. That reaches
42% of listener wakeups wasted at 8 workers under connection churn — but
it is ~1,500 wasted wakeups a second, two cheap syscalls each, well under
1% of a core. It is also per *connection*, so keep-alive amortises it
away. Measured before deciding whether to add an nginx-style accept
mutex; the measurement said not to bother.
