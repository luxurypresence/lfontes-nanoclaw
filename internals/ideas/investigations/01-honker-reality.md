# Investigation: Honker reality check

Date: 2026-05-18
Status: first pass, sources cited

## Question

`design-principles.md` and `queue-based-rewrite.md` both pin the storage
substrate to "single SQLite file + Honker on top." Honker is alpha. Is it
real enough to build on, what's the API actually look like compared to
pg-boss, and what's the fallback if it goes sideways?

## What Honker is

Honker is a Rust-implemented SQLite loadable extension plus a set of
language bindings ([README on GitHub](https://github.com/russellromney/honker)).
It ports the Postgres NOTIFY/LISTEN model into SQLite and bundles work
queues, durable streams, ephemeral pub/sub, a cron-like scheduler, named
locks, rate limiting, and task-result storage on top.

Author: Russell Romney (`russellromney` / `russellthehippo`). One main
contributor — 263 commits to his name, the only other contributor has 1
([contributors API](https://api.github.com/repos/russellromney/honker/contributors)).

Distribution shape:

- `honker-core` — Rust library, on crates.io.
- `honker-extension` — SQLite loadable `.cdylib`, on
  [crates.io](https://crates.io/crates/honker-extension). Works with any
  SQLite 3.9+ client.
- Per-language bindings under `packages/` for Node, Bun, Python, Ruby, Go,
  Elixir, C++, .NET, Java/JVM, Kotlin. Each is a thin wrapper over the
  Rust core (some via native node-addon, some load the extension).
- **Node binding**: `@russellthehippo/honker-node` on npm
  ([npm](https://www.npmjs.com/package/@russellthehippo/honker-node)).
  Current published version **0.3.3**, published 2026-05-04.

So the answer to "is it an npm package, an extension, or a wrapper" is:
all three. For us it's the npm package, which bundles a native binding
that pulls in the Rust core. No separate SQLite extension to install
manually if we use the Node binding.

Self-described stability: as of commit `12ca21d` (2026-05-07) the README
banner reads "Alpha software. Better than experimental but not
beta-quality yet" — the commit message is literally `experimental -> alpha`.

Sources:
- [GitHub repo](https://github.com/russellromney/honker)
- [README](https://github.com/russellromney/honker/blob/main/README.md)
- [honker.dev marketing site](https://honker.dev/)
- [Simon Willison writeup, "russellromney/honker"](https://simonwillison.net/2026/Apr/24/honker/) — calls the design "very solid", flags the transactional-outbox pattern as the headline win.
- [Show HN](https://news.ycombinator.com/item?id=47874647) and the [follow-up "durable queues, streams, pub/sub, scheduler" thread](https://news.ycombinator.com/item?id=47963316).

## API surface

Pulled from `packages/honker-node/api.js` and `wrapper.d.ts`
([api.js](https://github.com/russellromney/honker/blob/main/packages/honker-node/api.js),
[wrapper.d.ts](https://github.com/russellromney/honker/blob/main/packages/honker-node/wrapper.d.ts)).

Top-level: `open(path, maxReaders?, watcherBackend?)` → `Database`.

| Class | Methods | Purpose |
|-------|---------|---------|
| `Database` | `transaction()`, `query(sql, params)`, `updateEvents()`, `close()`, `notify(channel, payload)`, `notifyTx(tx, …)`, `queue(name, opts)`, `outbox(name, delivery, opts)`, `stream(name)`, `listen(channel, opts)`, `scheduler()`, `tryLock(name, owner, ttlS)`, `tryRateLimit(name, limit, per)`, `pruneNotifications()`, `sweepRateLimits()`, `saveResult(jobId, value, ttlS)`, `getResult(jobId)`, `sweepResults()` | The handle. Everything hangs off it. |
| `Transaction` | `execute`, `query`, `notify`, `commit`, `rollback` | Atomic business-write + queue-enqueue (the outbox win Simon called out). |
| `Queue` | `enqueue(payload, opts)`, `enqueueTx(tx, …)`, `claimOne(workerId)`, `claimBatch(workerId, n)`, `claim(workerId, opts)` (async iterator), `ackBatch(ids, workerId)`, `sweepExpired()`, `cancel(jobId)`, `getJob(jobId)`, `claimWaker(opts)` | Work queue. Opts: `visibilityTimeoutS`, `maxAttempts`. |
| `Job` | `ack()`, `retry(delayS, error)`, `fail(error)`, `heartbeat(extendS)`. Fields: `id`, `queue`, `payload`, `workerId`, `attempts`, `claimExpiresAt` | What `claim` returns. |
| `Outbox` | `enqueue`, `enqueueTx`, `runWorker(workerId, opts)` | Transactional outbox helper. Opts: `maxAttempts`, `baseBackoffS`, `visibilityTimeoutS`. |
| `Stream` | `publish(payload)`, `publishWithKey`, `publishTx`, `readSince(offset, limit)`, `readFromConsumer(consumer, limit)`, `saveOffset(consumer, offset)`, `getOffset(consumer)`, `subscribe(consumer, opts)` | Durable per-consumer-offset pub/sub. |
| `Listener` | async-iterable, `close()` | Ephemeral pub/sub on `notify()` channels. |
| `Scheduler` | `add(opts)`, `remove(name)`, `pause(name)`, `resume(name)`, `list()`, `update(name, opts)`, `tick(now)`, `soonest()`, `run(owner, signal)` | Cron + interval scheduler. Schedule format: 5-field cron, 6-field cron, or `@every <n><unit>`. |
| `Lock` | `release()`, `heartbeat(ttlS)` | Named distributed locks. |
| `UpdateEvents` | `next()` (await), `close()` | Low-level wake signal — what the higher-level claim/listen wrappers use. |

Enqueue options: `{ tx, runAt, delay, priority, expires }` — so delayed
jobs, priorities, and TTLs are all first-class. Queue options:
`{ visibilityTimeoutS, maxAttempts }`.

Wake mechanism: by default a `PRAGMA data_version` poll every 1ms; the
extension exposes `watcherBackend: "polling" | "kernel" | "shm"` to swap
in inotify/kqueue or shared-memory variants. The HN discussion has the
author confirming kernel + shm backends are in flight and the polling
default is a punt to avoid per-platform code at launch
([HN thread](https://news.ycombinator.com/item?id=47963316)).

## Feature parity vs pg-boss

Comparing to pg-boss's documented feature set
([pg-boss docs](https://timgit.github.io/pg-boss/), [npm page](https://www.npmjs.com/package/pg-boss)).

| Dimension | pg-boss | Honker (0.3.3 Node) | Verdict |
|-----------|---------|---------------------|---------|
| Enqueue / claim / ack | yes | `enqueue` / `claim*` / `ack` | parity |
| Visibility timeout | yes (lock-based) | yes, `visibilityTimeoutS` per queue | parity |
| Retries with backoff | yes, exponential + jitter | `maxAttempts`, `Job.retry(delayS)`, Outbox has `baseBackoffS` | partial — backoff is manual/per-call, not declarative exponential-with-jitter. uncertain — needs verification on whether `Outbox` does jitter. |
| Heartbeat / lease extension | yes | `Job.heartbeat(extendS)` | parity |
| Cron schedules | yes (standard cron) | yes, 5-field cron, 6-field cron, `@every Ns` interval | parity |
| Delayed jobs | yes (`startAfter`) | yes (`runAt`, `delay`) | parity |
| Priorities | yes | yes (`priority` on enqueue) | parity |
| TTL / expiry | yes | yes (`expires`) | parity |
| Dead-letter queues | yes | **not shipped** — listed as Phase Gehrig in [ROADMAP.md](https://github.com/russellromney/honker/blob/main/ROADMAP.md): `_honker_dead` + DLQ enqueue planned but not implemented | gap |
| Throttling / rate limiting | first-class queue policies | `tryRateLimit(name, limit, per)` exists as a primitive but Phase Ranger's non-goals explicitly say "do not extract rate limiting here" | partial — primitive present, no queue-level integration |
| Batching | yes (batch fetch) | `claimBatch(workerId, n)`, `ackBatch(ids, …)` | parity at the claim/ack level. No batch-enqueue verb. uncertain — could just call `enqueue` in a `Transaction`. |
| Pub/sub (NOTIFY/LISTEN) | yes (pg `pg_notify`) | yes (`notify`/`listen`) plus durable `Stream` with per-consumer offsets — strictly more than pg-boss | parity+ |
| Singletons / deduplication | yes (singleton keys) | not visible in API. uncertain — needs verification | gap |
| Worker concurrency control | yes (`teamSize`, `teamConcurrency`) | not declared at API level — caller runs N `claim()` loops | gap (architectural — solvable in user code) |
| Web UI / inspection | none built-in either side | none | parity |
| Postgres-only? | yes | SQLite-only | this is the whole point |

Net: for our actual use case (single host, low-volume, human-scale chat
queue + scheduled messages + a fan-out pub/sub for "wake the right
container") **the gaps are mostly things we don't need**. Dead-letter is
the one I'd actually miss; everything else is either present or easy to
synthesize.

## Stability assessment

Repo health snapshot (via GitHub API, 2026-05-18):

- Stars: 1,179. Forks: 30. Subscribers: 6. Created 2026-04-18, so this
  is a one-month-old hype project at the time of writing.
- Open issues: **3**. (Numbers #12, #49, #50 — testing gap, Python
  transaction API, ship precompiled ext with python module.) None of
  them are "data corruption" or "queue loses jobs."
- Recent issues closed (#48, #45, #44, #34) are all infra/CI/test
  stability, not correctness bugs.
- Commit cadence: 264 commits on `main` in ~30 days. Last commit
  2026-05-07. Steady daily activity through the window.
- 10 tagged releases across the binding matrix. Node went
  `0.1.0 → 0.2.0 → 0.3.1 → 0.3.2 → 0.3.3` between 2026-04-21 and
  2026-05-04 — five Node releases in two weeks. That's a fast-moving
  API surface; expect to need to re-pin and re-test on any update.
- npm downloads (last 30 days): 652 total, peak day 179. So:
  approximately nobody is using this in production yet. We would be an
  early adopter.
- License: dual-licensed Apache 2.0 + MIT (the GitHub `NOASSERTION` is
  just because of the multi-license layout). Safe for personal use, safe
  to fork.
- Breaking-change cadence: changelog mentions a `honk()` → `notify()`
  rename, schema restructurings, "API simplification on batching." So
  yes, breakage between minor versions is normal at 0.x. Confirms the
  "pin and read source" advice.
- Bus factor: **1** (russellromney has 263/264 commits). One author,
  one maintainer, no co-maintainer. The author's own HN comment
  ([thread](https://news.ycombinator.com/item?id=47963316)): "definitely
  a for fun project that blew up unintentionally."

Production users: none I can find. Simon Willison's blog post is the
most prominent third-party mention, and that's design admiration, not
deployment. uncertain — needs verification if anyone's actually shipped
this beyond the author's own apps.

## Failure-mode / migration path

Two failure modes worth distinguishing:

1. **Honker gets a fatal bug we can't work around** (e.g. queue
   drops/dupes jobs under crash, or kernel-watcher backend breaks on
   Linux). Mitigation tiers:
   - Pin to a known-good version. Fork if needed — small repo, single
     author, MIT/Apache, low fork friction. Honker is mostly Rust + a
     thin Node wrapper, so a patched fork is feasible.
   - We have NanoClaw's own session-DB pattern as a worked example —
     the queue-based-rewrite intentionally *eliminates* that complexity,
     but a forced fallback to "host owns one SQLite, hand-rolled queue"
     is concrete and tractable. ~1-2 days of work to write the minimum
     queue + cron worker ourselves; we already understand the model.

2. **Honker goes unmaintained at alpha and we want something
   battle-tested.** Migration path: back to **pg-boss on Postgres**.
   - Conceptually low-cost: the RPC verbs in `queue-based-rewrite.md`
     (`claim_work`, `record_message`, `schedule_message`, etc.) are
     storage-agnostic. Only the verb implementations change.
   - Operationally medium-cost: now we run a Postgres process on the VM,
     manage its config, back it up. The `design-principles.md` "single
     SQLite file" simplicity goes away. Reasonable but a real
     downgrade-in-elegance.
   - Schema port: messages/audit/scheduled tables are vanilla SQL —
     trivial. Honker-specific bits we'd lose: the durable `Stream` with
     per-consumer offsets (pg-boss doesn't have an equivalent; we'd
     emulate with a fan-out queue and a per-consumer table). The named
     `tryLock` (use `pg_advisory_lock`). The `tryRateLimit` (use a
     rolling-window table).
   - This is the path the design doc already calls out as the fallback,
     and it's the right one.

Disruption rating if we have to migrate: **medium-low**, *if* we keep
the RPC verbs as the public contract and treat Honker as an
implementation detail. **high** if we leak Honker types into RPC
handlers or skill code. Implication for the rewrite: keep an internal
`Storage` interface that wraps Honker; never `import` from
`@russellthehippo/honker-node` outside `src/storage/`.

## Recommendation

**Use it. Pin to `@russellthehippo/honker-node@0.3.3`.** Treat it as a
load-bearing alpha dependency with an explicit eviction plan.

Hedging protocol:

1. Wrap Honker behind an internal `Storage` interface. RPC handlers
   import the interface; only `src/storage/honker.ts` imports
   `@russellthehippo/honker-node` directly. This is the single most
   important hedge — it makes migrate-to-pg-boss a 1-file change at the
   storage layer instead of a rewrite. (Mirrors the existing NanoClaw
   `src/db/` boundary; nothing exotic.)
2. Pin the exact Node version in `package.json` (`0.3.3`, not `^0.3.3`).
   Honker has had 5 Node releases in 2 weeks; assume any minor version
   bump may break us until 1.0.
3. Don't use features marked roadmap-only. In particular: don't try to
   rely on dead-letter behavior — handle exhausted retries in our own
   code (write to a `dead_messages` table, alert me out-of-band). When
   Honker ships Phase Gehrig DLQ, we can adopt.
4. Watch for upstream changes:
   - Subscribe to releases:
     `gh api repos/russellromney/honker/subscription -X PUT -f subscribed=true -f ignored=false`
     (or just `gh repo watch` the repo with "Releases only").
   - Check `CHANGELOG.md` before every version bump.
   - Run the Node `test/parity.test.js` suite against our pinned version
     in our own CI as a smoke test — catches the case where a transitive
     update or our wrapper assumes a method that moved.
5. If maintenance stalls (no commits to `main` for 90+ days, or open
   correctness issues with no response): fork the repo, freeze on the
   last known-good commit, plan the pg-boss migration as a quarter-scale
   project rather than a fire drill.
6. Don't run our own fork from day one — that's premature. Single
   maintainer with daily commits is fine for now.

The principle this preserves: "minimal moving parts" stays intact while
we're on Honker; the eviction path keeps it intact even if we have to
move (Postgres is one more daemon, not five).

## Open sub-questions

- Does `Job.retry(delayS, error)` implement exponential backoff
  internally, or is the caller expected to compute `delayS`? Read the
  source. (uncertain — likely caller-computed based on the API shape.)
- Is there a deduplication / singleton-key facility hidden in `enqueue`
  opts that I missed? pg-boss has it; Honker's `EnqueueOptions` doesn't
  expose one in `wrapper.d.ts`. Confirm by reading `api.js`.
- What happens on `crash mid-claim` in practice? The visibility timeout
  story says the lease expires and the job goes back on the queue — but
  I want to actually kill a node worker in a test and watch the job
  reappear before I trust it. Action: write a smoke test as part of
  whatever first prototype.
- Cross-binding gotchas: the BINDINGS.md doc claims Node has full
  parity, but the readme/examples are Python-heavy. Anything Node can't
  do that Python can? Action: skim
  [packages/honker-node/test/parity.test.js](https://github.com/russellromney/honker/blob/main/packages/honker-node/test/parity.test.js)
  when starting implementation.
- Bun binding (`@russellthehippo/honker-bun`) is also published and
  NanoClaw's container runtime is Bun. If we ever want a container-side
  Honker (we shouldn't — design says containers don't touch host
  storage), it exists. Note for awareness only.
- HN comment thread flags potential CPU cost of the 1ms polling
  default. For a 2-vCPU VM with 2 long-lived containers and a host
  process, this is "0.3% CPU per waiting thread" — fine. But if we ever
  scale watchers, switch `watcherBackend: "kernel"` and re-measure.
