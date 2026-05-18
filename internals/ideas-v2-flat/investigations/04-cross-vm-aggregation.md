# Investigation: cross-VM aggregation (deferred)

## Question

v2-flat trades v1's "host owns visibility across all agents" for per-VM
dashboards. Each VM is observable on its own; aggregating across N VMs
("what did all my agents do yesterday?", "show me every credential
request this week") is not a v1 feature.

At what point does the cost of N tabs / N queries justify building an
aggregation layer? What does that layer look like when it exists?

## What's lost vs. v1

| Capability | v1 | v2-flat |
|------------|----|---------| 
| Single dashboard URL | One. | N. |
| "Show all audit events from yesterday" | One SQL query against the central DB. | N queries (one per VM), union, sort. |
| "Was agent X up at time Y?" | Single query. | One SSH/HTTP check per VM. |
| Aggregate metrics (total messages/day, etc.) | Trivial. | Manual sum across VMs. |
| Single auth surface | One password. | N passwords (or password manager autofill). |
| Cross-agent correlation | Possible. | Not possible without external aggregation. |

For N=2, all of these are mild annoyances. For N=5, the password
juggling and tab-flipping become real friction. For N=10, prohibitive.

## When to build aggregation

Three triggers, any of which justifies it:

1. **N reaches a number that hurts.** Subjective; for me probably
   around 4-5 VMs. Each operator's threshold differs.
2. **Cross-agent correlation becomes a real use case.** "I want to
   know if a credential I revoked is being attempted across any of
   my agents" is a concrete cross-agent query. Without aggregation,
   it's grep-N-VMs.
3. **Auth fatigue.** N passwords becomes intolerable, *even* with a
   password manager. Magic-link login partially helps but adds a
   different friction.

For v1, **none of these have triggered yet.** N=2, no correlation
needs, password manager solves auth. Build aggregation when it
earns its place.

## Design options for when we do build it

### Option A. Pull-based aggregator

A dedicated tiny VM (or laptop service) periodically pulls audit
events from each agent VM via HTTPS, stores them in one local
SQLite, exposes a unified dashboard.

**Pros:** Agents don't have to know about the aggregator. Pull is
recoverable (aggregator restarts pick up from last seen). Simple.

**Cons:** Polling lag (1-5 minute delay). Aggregator becomes a new
piece of infrastructure to maintain.

**Shape:**

```
┌─────────────────┐    GET /audit?since=<ts>    ┌────────────┐
│ agent-vm-1      │ ←─────────────────────────  │ aggregator │
│ /audit endpoint │                              │   VM       │
└─────────────────┘                              │            │
                                                 │  one       │
┌─────────────────┐    GET /audit?since=<ts>    │  SQLite    │
│ agent-vm-2      │ ←─────────────────────────  │  one       │
│ /audit endpoint │                              │  dashboard │
└─────────────────┘                              └────────────┘
```

Each agent exposes `GET /audit?since=<ts>` with the same auth as the
dashboard. Aggregator polls every minute (or whatever).

### Option B. Push-based aggregator

Each agent posts new audit events to a central aggregator endpoint as
they happen.

**Pros:** Near-real-time. No polling.

**Cons:** Each agent now depends on the aggregator being reachable.
Adds a failure mode ("aggregator down → agents log locally only" →
"forgot to backfill → gap"). Push auth is awkward (per-agent tokens).

### Option C. Log shipping (rsyslog / Loki / Vector)

Each agent ships its audit log + http_log + structured logs to a
log aggregation system. Dashboards are then queries against that
system.

**Pros:** Well-trodden ground. Real query language (LogQL, etc.).
Scales fine.

**Cons:** Now you're operating a logging service. Real complexity
budget. The "minimal moving parts" principle (10) is straining.

### Option D. SQLite syncing (Litestream / rqlite / Marmot)

Litestream / Marmot can replicate per-VM SQLite to a central store.
A central process can query the union.

**Pros:** Stays in the SQLite ecosystem we already have.

**Cons:** Litestream is good at backup-style replication, not
multi-master query. Querying across replicated databases means
treating each replica as a separate database in the central process.
Manageable but not elegant.

## Recommendation (when this becomes work)

**Option A (pull-based aggregator).** When the time comes:

- Each agent exposes `GET /audit?since=<ts>&kind=<...>` behind the
  dashboard auth.
- A small aggregator service runs on its own tiny VM (or even
  laptop), polls every 60s, stores into a local SQLite, exposes a
  unified dashboard.
- The aggregator is its own thing — versioned separately, deployed
  separately. It is NOT part of the framework image.

The shape mirrors v1's "host owns visibility" — except now the
"host" is its own VM, optional, and added when N justifies it.

## What this means for v2-flat now

For v1, do these things to keep the path open:

1. **Stable audit event schema.** Don't drift the schema between
   agents. The aggregator will assume schema parity.
2. **`GET /audit` endpoint already in the dashboard.** Even at v1,
   expose it (auth-gated). Future aggregator depends on it; no
   reason not to ship now.
3. **Auth that supports machine clients.** The dashboard's password
   auth needs a complement for "an aggregator service that polls."
   Probably a long-lived API token, scoped to read-only audit access,
   separate from the human-login password.

These three are cheap additions that buy us the future option without
committing to aggregation now.

## Anti-recommendation

Do **not** prematurely build:

- Cross-VM auth federation (SSO, OIDC).
- A central "all agents" config registry.
- Cross-VM RPC for any reason.
- A meta-host that orchestrates VMs.

Each of these reintroduces the v1 architecture under a different name.
The whole point of v2-flat is that the VMs are autonomous; aggregation
is read-only visibility on top, not coordination.

## Open sub-questions

- **Where does the aggregator live?** Another exe.dev VM is the
  obvious answer. A non-VM option (laptop service, or a Cloudflare
  Worker pulling on schedule) is also viable for read-only audit.
- **What aggregations are actually wanted?** I'd want:
  - Total audit events per agent per day.
  - Recent `tool.fail` across all agents.
  - "What's each agent doing right now" (last 5 events per VM).
  - Search across all audit logs for a string.
  That's it. Maybe four views.
- **Operator preferences.** Some operators may prefer a "panel" view
  (N agent statuses side by side, each in its own iframe pulling from
  its own VM) — no aggregator needed. Cheaper but visually cluttered.
  Compromise: ship a static HTML "panel" page as a stop-gap before
  building the real aggregator.
- **Slack as the aggregator.** Sending status updates to a Slack
  channel is a poor man's cross-VM dashboard. Already works without
  any new infra. Might cover 80% of the need.
