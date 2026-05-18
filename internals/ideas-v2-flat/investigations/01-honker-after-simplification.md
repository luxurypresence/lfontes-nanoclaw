# Investigation: do we still need Honker?

## Question

v1's queue-based design pinned Honker as the storage substrate — its
NOTIFY/LISTEN, durable queue, and cron scheduler were load-bearing
because the host had to wake N container-per-zone workers from idle.
v2-flat collapses to **one host process and one harness subprocess per
VM**. The host *is* the queue consumer; the host *is* the channel
adapter; the host *is* the scheduler runner. The "cross-process wake"
problem largely evaporates.

Does Honker still earn its place in the v2-flat architecture, or do we
go SQLite-only with a simple polling cron worker inside the host
process?

## What we needed Honker for in v1

| Honker feature | v1 use case | v2-flat use case |
|----------------|-------------|------------------|
| NOTIFY/LISTEN | Host → containers wake on new messages | **Gone.** Host *is* the consumer. No cross-process wake needed. |
| `claim_work` with lease + visibility timeout | Multiple container workers competing for jobs from a shared queue | **Gone.** One subprocess. No competition. |
| Durable streams with per-consumer offsets | Cross-container pub/sub for events | **Gone.** No cross-process pub/sub needed. |
| Transactional outbox | Atomic "write business state + enqueue side-effect" | **Survives if any queueing.** When the host receives a Slack webhook and needs to "record + enqueue for scheduling," the outbox pattern is nice. But trivial to implement directly in SQLite. |
| Cron scheduler | Scheduled messages, periodic agent wake | **Survives.** Real use case. |
| Retry with backoff | Failed message delivery, failed tool calls | **Survives.** Real use case. |
| Distributed locks (`tryLock`) | Coordinating across containers | **Gone.** Single host. |
| Rate limiting | Per-zone rate limits on RPC | **Maybe.** Could rate-limit outbound channel sends, but it's optional. |
| Task result storage | Async tool results | **Gone or trivial.** Host owns the subprocess; results are stdout. |

The headline NOTIFY/LISTEN reason is gone. What remains is **cron** and
**retry**, both well-served by simpler primitives.

## Options

### A. Full Honker (v1's plan)

Keep the dependency, use the queue, scheduler, retry, outbox features.

**Pros:** Battle-tested patterns. Outbox is genuinely useful. If the
host process ever grows to multiple workers (it shouldn't but might),
the queue is ready.

**Cons:** Alpha software dependency we don't need. Adds ~3 MB to the
image. One more thing to keep up with at the version-bump level.
"Pinned alpha dep for features we don't use" is a smell.

### B. Honker for scheduler only

Use the Honker `Scheduler` for cron, ignore the queue and pub/sub.

**Pros:** Get the well-designed cron primitives without rolling our
own. Stays in the Honker ecosystem if we ever want more.

**Cons:** Most of Honker's surface area is the queue. Using it just
for cron is paying the dependency cost for ~10% of the value.

### C. SQLite-only, hand-rolled cron + retry

Plain SQLite. Cron worker is an interval poll over a `scheduled_tasks`
table. Retry is a `tries` column with exponential backoff computed in
the worker.

**Pros:** Simplest. No alpha dep. Schema is fully under our control.
~80 LOC for cron + retry, total.

**Cons:** Roll our own cron. The 5-field cron parser is ~50 LOC if we
want full POSIX-cron compatibility, or ~10 LOC if we restrict to
`@every Nm`-style intervals.

### D. SQLite + a tiny purpose-built cron lib

Use `node-cron` or similar (~5 KB, well-maintained, no alpha tag) for
the schedule parser. Hand-roll the rest.

**Pros:** Cron parsing is solved. Everything else is plain SQLite.

**Cons:** One more dep, but a small and stable one.

## Sketch: option C (SQLite-only)

```sql
CREATE TABLE scheduled_tasks (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  kind          TEXT    NOT NULL,        -- 'send_message' | 'cycle' | 'custom'
  payload_json  TEXT    NOT NULL DEFAULT '{}',
  schedule      TEXT    NOT NULL,         -- '@every 5m' | '2026-06-01T09:00Z' | cron expression
  next_run_at   TEXT    NOT NULL,         -- ISO-8601
  last_run_at   TEXT,
  tries         INTEGER NOT NULL DEFAULT 0,
  max_tries     INTEGER NOT NULL DEFAULT 5,
  state         TEXT    NOT NULL DEFAULT 'pending', -- 'pending' | 'running' | 'failed' | 'done'
  created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_sched_next_pending ON scheduled_tasks(next_run_at) WHERE state = 'pending';
```

Worker loop in the host:

```ts
async function tickScheduler() {
  while (running) {
    const now = new Date().toISOString();
    const due = db.prepare(
      `SELECT * FROM scheduled_tasks
       WHERE state = 'pending' AND next_run_at <= ?
       ORDER BY next_run_at LIMIT 50`
    ).all(now);

    for (const task of due) {
      claimAndRun(task);  // updates state to 'running', runs handler, marks done/failed
    }

    await sleep(5_000);   // 5s tick
  }
}
```

That's the entire cron worker. 30-50 LOC including retry-with-backoff
logic.

## Recommendation

**Option C (SQLite-only).** Drop Honker as a dependency.

The decisive factor: the NOTIFY/LISTEN value was the load-bearing
reason to take on alpha software. Without it, we're paying alpha-risk
for cron and retry that we can implement in 80 LOC of plain SQLite.

This also simplifies the migration story. v1 had hedging around
"wrap Honker behind a Storage interface so a pg-boss migration is
1-file"; v2-flat doesn't need either layer because the SQL is trivial.

Outbox pattern: still useful for "Slack webhook arrived, record it
*and* enqueue a scheduled retry if delivery fails." Implementable
in a single SQLite transaction, no library needed.

## Reversal triggers

When would we add Honker back?

- The host process splits into multiple workers (e.g., a separate
  process for the dashboard vs. the channel adapter). Then NOTIFY/LISTEN
  earns its place.
- The number of scheduled tasks per VM grows past ~1000 and the
  interval-poll cost becomes noticeable. (Unlikely at personal scale.)
- A real use case for durable pub/sub appears that SQLite-as-table
  can't satisfy.

None of these are projected for v1. If they appear, Honker (now or
its successor) is one PR away.

## Open sub-questions

- **Cron expression vs. interval-only.** Do we need
  `0 9 * * 1-5` (weekday 9am) support, or is `@every 24h` enough?
  Lean: support cron expressions via a small lib; the cost is tiny.
- **Time-zone awareness.** Cron expressions should respect a TZ field
  on the task. Trivial; don't forget.
- **Task handler registry.** New `kind` values shouldn't require a
  framework release. A `kind => handler` registry the framework
  ships with, extensible only inside the framework. User-defined
  scheduled tasks land via `send_message` kind for now.
- **What about queued retries on outbound message delivery?** Same
  table, same worker, different `kind`. Reasonable.
- **Persistence of Honker docs in `../ideas/`.** The Honker
  investigation in v1 stays valid as a reference for the "if we ever
  add it back" path. No need to delete it.
