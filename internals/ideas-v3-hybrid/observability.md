# Observability

Single dashboard. Single SQLite. Single auth. Cross-agent views are
free because everything lives in one place. This is the principle 8
restoration that v2-flat had to give up.

## What's visible

For every agent on this VM, accessible at `https://<vm>.exe.dev/`:

| View | Source |
|------|--------|
| Overview (all agents at a glance) | Live `agents` map + SQLite |
| Per-agent status (up/down/cycling, last activity, container ID) | Live `agents` map + Docker inspect |
| Audit log (paginated, filterable across all agents) | `audit_events` table |
| Recent sessions (per agent, list + per-session detail) | `data/sessions/<name>/projects/*.jsonl` summarized into a SQLite view + `audit_events` |
| Inbound messages (recent) | `messages_in` table |
| Outbound messages (recent + delivery status) | `messages_out` table |
| Scheduled messages | `scheduled_messages` table |
| HTTP traffic (what each agent is calling) | `http_log` table (from logging proxy) |
| Dashboard chat (talk to any agent here) | Routes via the dashboard channel adapter through the router |
| Settings (read-only) | `host.config.toml` + each `agent.config.toml` |

Auth-gated. Argon2id password. Session cookie. Login form.

## The logging proxy

A ~50-LOC HTTP forward proxy on the host. Each container's injected
env sets `HTTP_PROXY` / `HTTPS_PROXY` to point at the proxy's
listen address (reachable from inside the container via Docker's
host-network or `host.docker.internal`).

The proxy:
- Identifies the source agent (by source IP on the Docker bridge,
  or by a custom `X-Agent-ID` header injected at proxy receive — TBD).
- Forwards the request to the destination unmodified.
- Logs metadata to `http_log`:

```sql
CREATE TABLE http_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          TEXT    NOT NULL DEFAULT (datetime('now')),
  agent       TEXT    NOT NULL,          -- which agent made the call
  method      TEXT    NOT NULL,
  host        TEXT    NOT NULL,
  path        TEXT    NOT NULL,
  status      INTEGER,
  duration_ms INTEGER,
  bytes_in    INTEGER,
  bytes_out   INTEGER
  -- explicitly NOT recorded: bodies, request headers, response headers
);
CREATE INDEX idx_http_log_agent_ts ON http_log(agent, ts DESC);
CREATE INDEX idx_http_log_host_ts ON http_log(host, ts DESC);
CREATE INDEX idx_http_log_ts ON http_log(ts DESC);
```

Enough to power "what services is `personal-dm` calling and how
often" and "is `public-bot` hammering the GitHub API." Not enough
to recover sensitive content.

## Audit event schema

Taxonomy carried over from `../ideas/investigations/06-audit-events.md`
with v3-hybrid adjustments.

Kept:
- `session.start` / `session.end`
- `message.in` / `message.out`
- `tool.attempt` / `tool.complete` / `tool.fail`
- `skill.loaded`
- `process.cycle` (the shim's harness-respawn event)
- `anomaly`

Adjusted:
- `zone_id` column renamed to `agent` (it's the agent name now, not
  a separate zone concept).
- `container.start` / `container.stop` — meaningful again in
  v3-hybrid (per-agent containers exist).
- `host.start` / `host.stop` — host-level lifecycle.
- `credential.request` / `credential.response` — removed (no
  per-credential RPC; if the logging proxy upgrades to do
  substitution + approval, these come back).

Schema:

```sql
CREATE TABLE audit_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  agent           TEXT    NOT NULL,         -- which agent (or 'host' for host events)
  event_type      TEXT    NOT NULL,
  thread_id       TEXT,                     -- nullable
  channel_id      TEXT,                     -- nullable
  sender_id       TEXT,                     -- canonical user id; nullable
  tool_name       TEXT,                     -- nullable
  payload_json    TEXT    NOT NULL DEFAULT '{}',
  emitted_at      TEXT    NOT NULL,         -- container clock
  created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
                                            -- host receipt time
);
CREATE INDEX idx_audit_agent_time     ON audit_events(agent, created_at DESC);
CREATE INDEX idx_audit_type_time      ON audit_events(event_type, created_at DESC);
CREATE INDEX idx_audit_sender_time    ON audit_events(sender_id, created_at DESC)
  WHERE sender_id IS NOT NULL;
CREATE INDEX idx_audit_thread         ON audit_events(thread_id)
  WHERE thread_id IS NOT NULL;
```

Indexing, retention policy ("keep forever, prune if it earns its
place"), and discipline rules from v1's investigation 06 carry over
unchanged. See that doc for full detail.

## Cross-agent queries (the v3-hybrid restoration)

The whole reason this design exists. Examples that are one SQL
query in v3-hybrid and require N-VM aggregation in v2-flat:

```sql
-- "What did all my agents do yesterday?"
SELECT created_at, agent, event_type, thread_id, tool_name,
       json_extract(payload_json, '$.summary') AS summary
FROM audit_events
WHERE created_at >= date('now', '-1 day')
  AND created_at <  date('now')
ORDER BY created_at;

-- "Which agents used GitHub today?"
SELECT agent, COUNT(*) AS calls
FROM http_log
WHERE host = 'api.github.com'
  AND ts >= date('now')
GROUP BY agent
ORDER BY calls DESC;

-- "Any tool failures across any agent in the last hour?"
SELECT created_at, agent, tool_name,
       json_extract(payload_json, '$.error_class') AS error_class
FROM audit_events
WHERE event_type = 'tool.fail'
  AND created_at >= datetime('now', '-1 hour')
ORDER BY created_at DESC;

-- "Show me all activity for thread X across whichever agent handled it."
SELECT created_at, agent, event_type, payload_json
FROM audit_events
WHERE thread_id = ?
ORDER BY created_at;
```

The dashboard exposes pre-baked versions of these as views, and a
`/audit` page with filters.

## What I'd actually use the dashboard for

Six use cases, same as v2-flat but with cross-agent views added:

1. **"Did the agent respond to that message?"** → Outbound messages
   view, filter to last hour, all agents.
2. **"What did each agent do for me yesterday?"** → Audit log,
   grouped by agent, filtered to `message.in` / `message.out` /
   `tool.complete`.
3. **"This tool keeps failing — where?"** → `tool.fail` events
   grouped by tool name, across agents.
4. **"Are all my agents alive?"** → Overview, status per agent.
5. **"Cancel that 9am scheduled message."** → Scheduled view (across
   agents) + cancel button.
6. **"Just want to chat without opening Slack."** → Dashboard chat
   to whichever agent.

The dashboard should be optimized for these and nothing else.

## Dashboard live updates

htmx `hx-trigger="every 5s"` polling. Each pane refreshes its
content from a small server endpoint that returns rendered HTML
fragments. ~50 lines of server code per pane, no client-side state.

If real-time becomes worth it later, swap a single pane for SSE.
The polling-first approach keeps the v1 dashboard genuinely
boring.

## Auth

Single password for the operator. Argon2id-hashed, stored in
`dashboard_users`. Login form sets a session cookie; sessions live
in `dashboard_sessions` with an expiry.

The bootstrap script seeds the initial password (prompted during
bootstrap or read from `host.config.toml`'s `[dashboard]` block,
which gets the hashed password from a prompted plain-text).

Password reset: `agent-host reset-dashboard-password` SSHs to the
VM and updates the row.

## What doesn't fit on the dashboard

- **Live tail of host stdout.** `journalctl -u agent-host -f` on
  the VM.
- **Live tail of a container's output.** `docker logs -f
  agent-<name>` on the VM.
- **DB introspection.** `sqlite3 data/agent.db` on the VM.
- **OS-level diagnostics.** Disk usage, memory — out of scope.

The discipline: dashboard is for *agent-shaped* observability.
"The host is having a bad day" goes through platform tools.

## Retention

Default: keep forever (rows are small, query volume is human-scale,
SQLite scales fine).

When pruning earns its place (~250MB DB or slow queries):

- `agent-host prune --before YYYY-MM-DD --keep audit,credentials`.
  Operator-invoked, never automatic at first.
- Soft TTL via cron later if operator pruning becomes a chore.
- 18-month default if/when soft TTL is enabled.

For `http_log` specifically: 30-day rolling window by default
(it's chattier than audit). Configurable in `host.config.toml`.

## Operator API: `GET /api/audit`

Even at v1, the dashboard exposes a JSON API endpoint for the audit
log:

```
GET /api/audit?agent=personal-dm&type=tool.fail&since=2026-05-01&limit=100
Authorization: Bearer <api-token>
```

This is the seed for any future cross-VM aggregation tool (if I
ever spin off `public-bot` to its own VM, the aggregator's job
becomes "poll this endpoint from each VM"). At v1 it's just a
convenient way to write custom queries.

API tokens are separate from the password — long-lived, hex-string,
stored hashed, scoped read-only to audit. Generated via
`agent-host issue-api-token`.

## Open sub-questions

- **Pretty session viewer.** Click a session in the dashboard, see
  the transcript. Requires parsing the JSONL into something
  readable. Optional v1.
- **Search.** SQLite FTS5 over audit summaries. Worth doing once
  the corpus is large.
- **Alerting.** Dashboard tells you what happened; doesn't push. A
  scheduled task that pings me in Slack on `tool.fail` would be a
  10-LOC addition.
- **Per-VM TLS certs.** exe.dev handles; on other platforms (Hetzner),
  Caddy + ACME. Not a framework concern.
- **Audit event volume budget.** ~10k–100k events/month at personal
  scale. Negligible. Worth measuring once live.
