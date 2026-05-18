# Investigation: do we still need Honker?

Carried over from `../../ideas-v2-flat/investigations/01-honker-after-simplification.md`
with minor v3-hybrid adjustments. Conclusion unchanged: drop Honker,
use plain SQLite.

## Question (refresh)

v1's queue-based design pinned Honker (Russell Romney's SQLite
extension) as the storage substrate because the host needed
NOTIFY/LISTEN, durable queues, and pub/sub to coordinate N
container workers from cold idle.

v3-hybrid has **one host process** that orchestrates N containers
directly via `docker exec`. The host *is* the queue consumer; the
host *is* the channel adapter; the host *is* the scheduler. The
"cross-process wake" problem doesn't exist.

Does Honker still earn its place?

## v1 vs v3-hybrid for each Honker feature

| Honker feature | v1 use case | v3-hybrid use case |
|----------------|-------------|--------------------|
| NOTIFY/LISTEN | Host wakes N idle container workers | **Gone.** Host directly writes to a container's `docker exec` stdin. No wake-from-idle problem. |
| `claim_work` with lease | Multiple competing workers per queue | **Gone.** One host, one stream per container. |
| Durable per-consumer streams | Cross-container pub/sub | **Gone.** No cross-container communication. |
| Transactional outbox | "Write business state + enqueue side-effect" atomically | **Survives.** When a Slack webhook arrives, host wants to record it + maybe schedule a retry on failure. Trivial in raw SQLite transactions. |
| Cron scheduler | Scheduled messages, periodic wake | **Survives as a real use case.** Implementable in <100 LOC. |
| Retry with backoff | Failed delivery, failed tool calls | **Survives.** Same shape as cron. |
| Distributed locks | Cross-process coordination | **Gone.** Single process. |
| Rate limiting | Per-container RPC rate limits | **Maybe.** Could rate-limit outbound channel sends. Optional. |
| Task result storage | Async tool results | **Gone.** Host owns the subprocess streams; tool results are in the NDJSON flow. |

The headline value (NOTIFY/LISTEN, multi-worker queues, distributed
locks) is gone. What remains is cron + retry, well-served by simple
SQLite + an interval poll.

## Options

### A. Full Honker

Use the queue, scheduler, retry, outbox features.

Pros: Battle-tested patterns. Outbox is genuinely useful.
Cons: Alpha software dependency for ~10% of its value. ~3 MB image
bloat (now on the *host's* npm package since containers don't run
Honker). One more thing to keep pinned at minor versions.

### B. Honker for scheduler only

Use Honker's `Scheduler` class for cron; ignore the queue, pub/sub,
locks.

Pros: Cron primitives without rolling our own.
Cons: Tiny slice of Honker's surface area for the dependency cost.

### C. SQLite-only, hand-rolled cron + retry

Plain SQLite. Cron worker is a 5-second interval poll over
`scheduled_messages`. Retry is `tries` + computed backoff.

Pros: Simplest. No alpha dep. Full schema control. ~80 LOC total.
Cons: Roll our own cron parser. 5-field cron is ~50 LOC; interval-
only (`@every 5m`) is ~10 LOC.

### D. SQLite + a small purpose-built cron library

Use `node-cron` or similar (well-maintained, small, no alpha tag)
for the schedule parser. Roll the rest.

Pros: Cron parsing is solved.
Cons: One more dep, but stable and small.

## Sketch: option C

```sql
CREATE TABLE scheduled_messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  agent         TEXT    NOT NULL,
  kind          TEXT    NOT NULL,     -- 'send_message' | 'cycle' | 'custom'
  payload_json  TEXT    NOT NULL DEFAULT '{}',
  schedule      TEXT    NOT NULL,     -- '@every 5m' | '2026-06-01T09:00Z' | cron expression
  next_run_at   TEXT    NOT NULL,     -- ISO-8601
  last_run_at   TEXT,
  tries         INTEGER NOT NULL DEFAULT 0,
  max_tries     INTEGER NOT NULL DEFAULT 5,
  state         TEXT    NOT NULL DEFAULT 'pending',  -- 'pending' | 'running' | 'failed' | 'done'
  created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_sched_due ON scheduled_messages(next_run_at)
  WHERE state = 'pending';
```

Worker loop in the host:

```ts
async function tickScheduler() {
  while (running) {
    const now = new Date().toISOString();
    const due = db.prepare(
      `SELECT * FROM scheduled_messages
       WHERE state = 'pending' AND next_run_at <= ?
       ORDER BY next_run_at LIMIT 50`
    ).all(now);
    for (const task of due) {
      await runScheduledTask(task);
    }
    await sleep(5_000);
  }
}
```

30-50 LOC including retry-with-backoff and recurring-schedule
re-arming.

## Recommendation

**Option C (SQLite-only).** Drop Honker.

The decisive factor: with v3-hybrid's single-process orchestration,
the load-bearing reason for Honker (cross-process wake) is gone. We
should not pay alpha-software risk for cron + retry that we can
implement in <100 LOC.

This also simplifies distribution: the npm package has one fewer
native dependency. Smaller install, fewer build-script approvals to
manage.

If a real use case for durable pub/sub or multi-worker queues
appears, Honker (or pg-boss-on-Postgres) is one PR away. The host's
scheduler is behind a thin internal interface; replacing it later
is a localized change.

## Reversal triggers

When would Honker (or equivalent) come back?

- The host process splits into multiple workers. Possible if the
  dashboard ever becomes its own process. v1 doesn't need this.
- Scheduled tasks grow past ~1000 (interval-poll cost becomes
  noticeable). Won't happen at personal scale.
- A real durable pub/sub use case appears (e.g., cross-agent
  coordination via events). Currently out of scope.

None projected.

## Cron parser choice

`@every Nm` / `@every Nh` covers most personal-bot scheduling. Cron
expressions are nice-to-have for "every weekday at 9am" patterns.

Recommendation: support both via a tiny cron lib (`croner` or
similar, ~5KB, no native deps, no alpha tag). Operator UX wins
outweigh the dep cost.

## Open sub-questions

- **TZ-awareness.** Schedules should respect a `tz` field on the
  task. Trivial; don't forget.
- **Task handler registry.** New `kind` values shouldn't require a
  framework release. Frameworks ships handlers for `send_message`,
  `cycle`, `audit_summary`. User-defined kinds via skill +
  scheduled-message-pointing-at-skill pattern.
- **Outbox pattern for outbound message delivery.** When the host
  records a `messages_out` row and enqueues a Slack send, do we want
  these in one transaction? Yes — implementable with a status column
  (`pending` → `sent` → `failed`) and an in-process retry. ~50 LOC.
- **What about cross-agent coordination?** If `personal-dm` wants to
  schedule a message that `public-bot` should answer, the scheduled
  task names `public-bot` as the target agent. Single SQLite means
  cross-agent scheduling is just a query. Free win from the v3-hybrid
  consolidation.
- **Persistence of Honker docs.** v1's investigation 01 stays valid
  as a reference for the "if we ever add it back" path.
