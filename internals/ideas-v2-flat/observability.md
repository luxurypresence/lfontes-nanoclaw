# Observability

Per-VM dashboard, per-VM audit log, per-VM logging proxy. Each agent
is self-observing. Cross-VM aggregation is documented as a future
add-on; not built at v1.

This is a deliberate step down from v1's "host owns visibility across
all agents" principle. The simplification of the deployment model is
worth the cost; the cost is N tabs at the operator end.

## What's visible at v1

For each VM, accessible at `https://<vm>.exe.dev/dashboard`:

| View | Source |
|------|--------|
| Agent status (up/down, last activity, framework version, harness version) | Live host process + SQLite |
| Audit log (paginated, filterable) | `audit_events` table |
| Recent sessions (list + per-session detail) | `~agent/.claude/projects/*.jsonl` summarized into a SQLite view |
| Inbound messages (recent) | `messages_in` table |
| Outbound messages (recent + delivery status) | `messages_out` table |
| Scheduled messages | `scheduled_messages` table |
| HTTP traffic (what the harness called) | `http_log` table (from logging proxy) |
| Dashboard chat (talk to this agent here) | Same path as Slack but through the dashboard adapter |
| Settings (read-only) | `agent.config.toml` |

Auth-gated. Argon2id password. Session cookie. Login form.

## The logging proxy

A ~50-line Node script that the harness's HTTP traffic flows through.
Sets `HTTP_PROXY` / `HTTPS_PROXY` in the harness's env to the local
proxy. The proxy forwards in plain reverse-proxy mode — **no HTTPS
interception, no CA cert management, no request-body inspection.**

What gets logged per request:

```sql
CREATE TABLE http_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          TEXT    NOT NULL DEFAULT (datetime('now')),
  method      TEXT    NOT NULL,
  host        TEXT    NOT NULL,
  path        TEXT    NOT NULL,
  status      INTEGER,
  duration_ms INTEGER,
  bytes_in    INTEGER,
  bytes_out   INTEGER,
  -- explicitly NOT recorded:
  --   request body
  --   response body
  --   request headers (credentials live here)
  --   response headers
  agent_id    TEXT    NOT NULL
);
CREATE INDEX idx_http_log_host_ts ON http_log(host, ts DESC);
CREATE INDEX idx_http_log_ts ON http_log(ts DESC);
```

Enough to power "what services is this agent talking to and how
often" and "is something failing repeatedly." Not enough to recover
sensitive content.

## Audit event schema

The taxonomy from `../ideas/investigations/06-audit-events.md` survives
the architecture pivot mostly intact. Key changes:

- `zone_id` column is removed (one DB per VM; the VM *is* the zone).
- `container.start` / `container.stop` events removed (no
  per-zone containers); replaced with `host.start` / `host.stop`.
- `process.cycle` retained (the host can still kill-and-respawn the
  harness subprocess; that's still a meaningful boundary).
- `credential.request` / `credential.response` removed (no
  per-credential RPC at v1; if we add it later via the logging proxy,
  events come back).

Kept verbatim:

- `session.start` / `session.end`
- `message.in` / `message.out`
- `tool.attempt` / `tool.complete` / `tool.fail`
- `skill.loaded`
- `anomaly`

The schema, indexing, retention policy ("keep forever, prune only
if it earns its place"), and discipline rules from v1 carry over
unchanged. See that doc for full detail — no point duplicating here.

## What I'd actually use the dashboard for

Honest list of what I open the dashboard *for*, post-v1:

1. **"Did the agent actually respond to that message?"** → Outbound
   messages view, filtered to the last hour.
2. **"What did the agent do for me yesterday?"** → Audit log filtered
   to `message.in` / `message.out` / `tool.complete`.
3. **"This tool keeps failing — what's going on?"** → `tool.fail`
   events grouped by tool name.
4. **"Is the agent dead?"** → Status page.
5. **"Cancel that 9am scheduled message."** → Scheduled view + cancel
   button.
6. **"Just want to chat without opening Slack."** → Dashboard chat.

That's it. Six use cases. The dashboard should be optimized for those
and nothing else.

## Per-VM URL and auth

Each VM exposes its dashboard at a per-VM URL:

```
https://personal-dm.exe.dev/dashboard
https://public-bot.exe.dev/dashboard
```

Each has its own Argon2id-hashed password (stored in that VM's
`dashboard_users` table, seeded during bootstrap). Auth is per-VM.

This is one of the friction points of "no cross-VM aggregation":
the operator needs N passwords, one per VM. Mitigations:

- Use a password manager and let it autofill.
- Or use the same password across personal VMs (trades convenience
  for some risk; tolerable at single-user scale).
- Magic-link login via a fixed email is an alternative; uses one
  inbox to log into N VMs.

## The cross-VM problem

I want to be honest about what v2-flat gives up:

- **One pane of glass** for all agents. v1 had this. v2-flat doesn't.
- **Aggregate queries** ("what did all my agents do yesterday"). Would
  require querying each VM and unioning results.
- **Cross-agent coordination**. If `personal-dm` wants to ping
  `public-bot`, it goes through the *channel* (Slack DM the bot, or
  invoke its dashboard chat), not through a shared host.

For N=2, this is annoying-but-fine. For N=5, it's annoying. For
N=10, it's prohibitive.

Pragmatic answer: stay at N≤3 if you can. If a meta-dashboard or
aggregation service becomes worth building, the path is documented
in `investigations/04-cross-vm-aggregation.md`. It's a separate
service, not a v2-flat principle change.

## What doesn't fit on a dashboard

Not everything observable lives in the dashboard. A few things
deliberately route elsewhere:

- **Live tail of agent stdout/stderr.** Use `ssh agent@vm` and
  `journalctl -u agent-host -f` or `docker logs -f`. Dashboard is for
  *summary*, not raw logs.
- **DB introspection.** `ssh` + `sqlite3 /var/agent/data.db`. The
  dashboard doesn't expose a SQL prompt.
- **Operating-system-level diagnostics.** Disk usage, memory, etc.
  Out of scope; that's the VM platform's job.

The discipline: the dashboard is for *agent-shaped* observability.
Anything that's "the VM is having a bad day" goes through
platform-level tools.

## Open sub-questions

- **Retention vs storage.** `http_log` could grow quickly if the
  agent's chatty. Default cap: 30 days, with a soft cron prune. Audit
  events stay forever.
- **Search.** SQLite FTS5 over audit summaries is worth doing once
  the corpus is large enough.
- **Alerting.** Dashboard tells you what happened; it doesn't push.
  If I want "tell me when X happens," that's a separate notifier (a
  scheduled task that pings me via the channel). Out of scope for
  observability proper.
- **Per-VM TLS certs.** exe.dev handles this; on other platforms
  (Hetzner), need Caddy + ACME. Not a framework concern.
