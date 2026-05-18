# Investigation: idle wake mechanism

## Question

With ~2 long-lived containers (one per trust zone) sitting idle between
messages, how does the host get a container's agent runtime from "blocked,
near-zero CPU" to "calling the Claude SDK" with the lowest reasonable
latency and the simplest code? And: when a new message lands *mid-stream*
for the same zone, how do we push it into the current Claude query the way
NanoClaw does with `query.push()`?

## Constraints (recap, brief)

- ~2 long-lived containers, one per trust zone.
- Host owns the queue (single SQLite + Honker). Containers never read the
  DB directly — only RPC verbs.
- Container ↔ host is Unix-socket RPC only. No shared mounts beyond the
  socket.
- Idle CPU should be near zero. Memory irrelevant at this scale.
- Wake-to-Claude-call latency: single-digit ms ideal, sub-100ms acceptable.
- Mid-response push must work — a new message lands while Claude is
  streaming, it should be injected into the in-flight query.
- RPC stays intent-shaped (`claim_work`, etc.), not SQL.

## Options

| Option | Idle→active latency | Idle CPU | Code complexity (host + container) | Reliability |
|--------|--------------------|----------| ----------------------------------|-------------|
| 1. Long-polling `claim_work` | ~1ms (already a held connection) | ~0% (one blocked syscall) | Low / Low | High — TCP-like semantics, retries are trivial |
| 2. SSE stream from host | ~1ms | ~0% | Medium / Medium | High, but text-framing adds parsing |
| 3. WebSocket over Unix socket | ~1ms | ~0% | High / High | High — but ws lib + framing + lifecycle is a lot for personal scale |
| 4. Honker NOTIFY/LISTEN | depends on Honker (likely 1–10ms) | ~0% | Medium / Medium — couples container to Honker | Depends on alpha software being right |
| 5. File-watch notify file | 1–50ms (inotify) | ~0% | Low / Low | Medium — needs a shared mount we said we wouldn't have |
| 6. SIGUSR1 from host to container PID | <1ms | ~0% | Medium / Low — host needs PID lookup, signal handler is fiddly inside Bun | Medium — signal coalesces, no payload, race-prone |
| 7. Short-interval polling | 50–500ms (interval/2 avg) | non-zero (wakes on every tick) | Trivial / Trivial | High — boring and works |

**1. Long-polling `claim_work`.** Container opens an HTTP POST to the host
RPC: `claim_work(zone_id, wait_ms=30000)`. Host blocks until Honker
yields work, then returns. Container immediately re-opens after each
response. This is just `claim_work` with a `wait` parameter — fits the
existing intent-shaped API perfectly, no new transport. The held
connection *is* the wake channel. Zero idle CPU on the container (it's
parked in a `read()` syscall) and near-zero on the host (Honker `subscribe`
+ a pending response).

**2. Server-Sent Events.** Host runs an SSE endpoint per zone; container
opens it once and streams events. Works, but adds an event-framing layer
on top of "you should call `claim_work` now," which is just long-polling
with extra steps. The one advantage — pushing arbitrary side-band events —
isn't needed yet.

**3. WebSocket over Unix socket.** True bidirectional. Overkill: nothing
needs full duplex right now. RPC is request/response shaped; the only
"push" direction is "wake up," which long-polling already covers. Adds
a ws library, ping/pong, reconnect logic, and a framing protocol.

**4. Honker NOTIFY/LISTEN.** Tempting because the queue would talk
directly to the worker. But it couples the container to Honker as a
client, which violates principle 4 (RPC exposes intents, not queries —
NOTIFY/LISTEN *is* a query primitive). It also makes Honker alpha-status
a hard dependency of the wake mechanism, not just the queue.

**5. File-watch.** Container `inotify`s `/var/run/<zone>.notify`; host
touches it. Crude, works, but requires a shared mount between host and
each container — exactly what the queue-based-rewrite design eliminated.
Resurrecting a mount for one bit of signalling is a regression.

**6. SIGUSR1.** Host calls `docker kill --signal=SIGUSR1 <name>` (or
sends to the resolved PID); container's agent runtime installs a handler
that triggers a `claim_work` call. Latency is excellent but: signals
carry no payload, coalesce under load (two signals before the handler
runs = one wake), and Bun's signal handling for SIGUSR1 inside containers
is not something I want to debug. Also: `docker kill` adds a process
spawn on the host every wake.

**7. Short-interval polling.** Fallback only. 100ms ticks average 50ms
latency and never sleep deeply. Worth keeping as a fallback for "long
poll connection died, retry in 1s" but not as the primary wake.

## Mid-response push: same mechanism or different?

**Same mechanism, with one wrinkle.**

Cold-idle wake: container is parked in `claim_work(wait=30000)`. Host
publishes to Honker; long-poll returns; container starts Claude SDK call.

Mid-response wake: container is *in the middle of* a Claude streaming
call, holding a `query` handle (NanoClaw uses `query.push()` for exactly
this). It's not parked in `claim_work` — that connection is closed.

So the container needs **two** ways to learn about new work:

1. While idle: `claim_work` long-poll returns → start a new query.
2. While streaming: a *separate* held connection — `subscribe_pushes` —
   that returns one message at a time, intended to be drained
   concurrently with the active query and fed into `query.push()`.

Both endpoints sit on the same Unix socket, both block in Honker. The
mid-response endpoint only ever yields messages whose `zone_id` matches
and whose `session_id` matches the currently-active query (the container
tells the host "I'm currently running session X" when it opens the
push subscription).

This means: same transport (long-polling), same intent shape, two named
endpoints. Not a different mechanism — just one more held connection
during active streaming, torn down when the stream completes.

## Recommendation

**Long-polling `claim_work` for cold-idle wake. A parallel long-polling
`subscribe_pushes` for mid-response push. Short-interval polling (1s) as
a fallback when a long-poll connection dies.**

Pseudocode for the container side:

```typescript
// Container main loop — runs forever for the life of the container.
async function runWorker(zoneId: string, rpcToken: string) {
  while (true) {
    let job;
    try {
      job = await rpc.claimWork({ zoneId, waitMs: 30_000 }); // long-poll
    } catch (err) {
      // socket dropped, host restarted, etc. — back off and retry.
      await sleep(1000);
      continue;
    }
    if (!job) continue; // long-poll timed out empty, just re-arm.

    await runSession(job);
  }
}

async function runSession(job: Job) {
  const query = claude.startQuery({
    systemPrompt: job.system_prompt,
    history: job.history,
    initialUserMessage: job.content,
  });

  // While the stream is running, hold a *second* long-poll for pushes
  // scoped to this session. Cancel it when the stream completes.
  const pushController = new AbortController();
  const pushPump = (async () => {
    while (!pushController.signal.aborted) {
      const push = await rpc.subscribePushes({
        zoneId: job.zone_id,
        sessionId: job.session_id,
        waitMs: 30_000,
        signal: pushController.signal,
      }).catch(() => null);
      if (push) query.push(push.content);
    }
  })();

  for await (const event of query.stream()) {
    if (event.type === "message") await rpc.recordMessage(event.message);
    if (event.type === "audit") await rpc.emitAudit(event.payload);
  }

  pushController.abort();
  await pushPump;
}
```

Host side (sketch):

```typescript
// claim_work handler
async function claimWork({ zoneId, waitMs }) {
  // Honker visibility-timeout-aware pop.
  const job = await honker.claim({ queue: `zone:${zoneId}`, waitMs });
  return job; // may be null on timeout — that's fine, container re-arms
}

// subscribe_pushes handler — only yields messages tagged for mid-stream
// injection (router decides which ones are eligible vs which start a new
// session). Same Honker queue, different consumer group, or a separate
// `zone:${zoneId}:push` queue.
async function subscribePushes({ zoneId, sessionId, waitMs }) {
  return honker.claim({
    queue: `zone:${zoneId}:push:${sessionId}`,
    waitMs,
  });
}
```

Why this wins:
- Reuses the RPC layer that already has to exist. No new transport.
- Idle container is one blocked `read()` per zone — measured CPU ≈ 0.
- Latency is dominated by Honker's notify path; for in-process SQLite +
  Honker, that's well under 1ms.
- Mid-response push is the same shape, just a second held connection.
- Visibility timeouts on Honker handle "container crashed mid-claim"
  without ceremony.

## Failure modes

**Lost wake (host enqueues, container never gets the signal).** Two
defenses: Honker visibility timeout (lease expires → message goes back
on the queue) and a 30-second long-poll ceiling (after which the
container re-arms and Honker re-checks). Worst case: 30s of delay, never
a permanent loss.

**Double-wake (two containers claim the same message).** Can't happen
across zones — each zone has its own queue. Within a zone there's only
one container by design (principle 1). If we ever scale a zone to
multiple workers, Honker's `claim` is a single-row UPDATE with
`OWNER IS NULL` — atomic.

**Container dies mid-claim.** Visibility timeout expires, message
re-queues. The "two-mailbox dual-DB seq parity" nightmare of NanoClaw
doesn't exist here because the host owns the queue state.

**Push subscription leak.** If the container crashes during a stream,
the `subscribe_pushes` connection drops, host's pending Honker claim
gets cancelled when the socket closes, message goes back on the queue,
host's next `claim_work` returns it as a fresh session. The router must
make this idempotent — see `investigations/07-rpc-catalog.md`.

**Push arrives milliseconds after stream completes.** The container
aborts the push pump *before* the final `record_message`, so a late push
becomes a new `claim_work` job. There's a tiny window where a push could
be claimed-then-orphaned; visibility timeout handles it.

**Honker queue corruption / Honker dies.** Process-level — host
crashes, both containers' long-polls drop, the systemd/launchd restart
brings the host back, containers reconnect on the back-off path. No data
loss because the queue is in the durable SQLite file.

## Open sub-questions

- Does Honker actually expose a blocking `claim` with a `wait_ms`
  parameter, or does the host have to implement long-poll on top of a
  busy-wait + Honker `subscribe` event? See
  `investigations/01-honker-reality.md`.
- Should `subscribe_pushes` be a separate Honker queue per session, or
  one queue per zone with a session-filter predicate? Per-session is
  cleaner but creates queue churn.
- How is the "this push is eligible for mid-stream injection vs starts
  a new session" decision made? Router-level rule or always inject if
  the session is still active? Probably the latter — simpler.
- What's the max payload size for a single push? Claude SDK
  `query.push()` is just text; if someone sends a file mid-stream we
  probably surface "user sent a file" as text and let the agent decide
  to tool-call to fetch it.
- If a zone has two active sessions concurrently (e.g., two channels
  both wired to dm-trust), does the container run two queries in
  parallel? If so, each query needs its own push subscription. See
  `investigations/05-process-cycle.md`.
