# Host responsibilities

The Node host process is the framework. It's small, it's per-VM,
and it's deliberately not extensible into more than what's listed
here.

Target: ~1000–1500 LOC of TypeScript. Holdable in head. That's the
test.

## What the host does

| Subsystem | Approx LOC | Notes |
|-----------|------------|-------|
| Channel adapters | ~300 (Slack adapter alone) | One adapter per platform. Slack first; Discord, dashboard chat next. Adapters live behind a registry interface. |
| Webhook receiver | ~100 | HTTP server that receives platform webhooks and posts to the internal queue. |
| Subprocess management | ~150 | Spawn the harness, manage stdin/stdout streams, restart on exit, kill on shutdown. Sets uid=`agent`, injects env from in-memory secrets. |
| NDJSON parser per harness | ~50 each | Reads the harness's streaming output, dispatches `record_message`, `audit`, etc. |
| Logging proxy | ~50 | HTTP forward proxy that logs metadata to SQLite. |
| Dashboard server | ~200 | Server-rendered HTML, htmx for interactivity, auth-gated. |
| Auth | ~50 | Argon2id password hash check, session cookie. Basic but real. |
| SQLite layer | ~150 | Schema migrations, audit log, channel-message log, scheduled tasks. |
| Cron / scheduler | ~50 (if SQLite-only) to ~150 (if Honker) | See `investigations/01-honker-after-simplification.md`. |
| Subprocess lifecycle / cycle | ~80 | Kill-and-respawn the harness on `/cycle` or unhealthy heartbeat. |
| Config loader | ~50 | Reads `agent.config.toml`, validates with Zod, holds in memory. |
| Boot / shutdown | ~50 | Read env, validate config, mount OverlayFS check, start server, install signal handlers. |

Sum: ~1300 LOC for the v1 surface with Slack + dashboard adapters.
Discord and a second harness adapter would each add ~300.

## What the host does NOT do

- **Implement an agent loop.** The harness does that. The host is a
  channel adapter wrapping a subprocess.
- **Translate or rewrite the harness's config.** The user's `.claude/`
  is the format.
- **Maintain a vault, a CA, or any credential proxy beyond the
  metadata-logging proxy.** Subprocess env injection is enough.
- **Coordinate across VMs.** Each host is self-contained. Cross-VM
  aggregation is a future add-on (`investigations/04-cross-vm-aggregation.md`).
- **Run an LLM inference path itself.** The harness owns all model
  calls; the host doesn't even see them (only metadata via the
  logging proxy).
- **Implement per-tool capability checks.** The harness's existing
  allowlist (Claude Code `permissions.allow`/`deny`) is what gates
  tools. The host doesn't try to second-guess it.

## Module sketch

```
host/
├── src/
│   ├── index.ts                  ← entrypoint: load config, start everything
│   ├── config.ts                 ← parse + validate agent.config.toml
│   ├── env.ts                    ← read /etc/agent/env, hold in-memory
│   ├── db.ts                     ← SQLite open, migrations, prepared statements
│   ├── channels/
│   │   ├── registry.ts           ← adapter lookup
│   │   ├── slack.ts              ← webhook + send + message-format conversion
│   │   ├── dashboard-chat.ts     ← in-app chat through the dashboard
│   │   └── types.ts              ← ChannelAdapter interface
│   ├── harness/
│   │   ├── registry.ts           ← harness lookup by `kind`
│   │   ├── claude.ts             ← Claude Code subprocess adapter
│   │   ├── codex.ts              ← (future) Codex subprocess adapter
│   │   ├── subprocess.ts         ← shared spawn/stream/kill logic
│   │   └── types.ts              ← HarnessAdapter interface
│   ├── proxy/
│   │   └── logging-proxy.ts      ← HTTP forward proxy
│   ├── scheduler/
│   │   └── cron.ts               ← scheduled-message dispatch (SQLite + interval poll)
│   ├── audit/
│   │   └── events.ts             ← write to audit_events table
│   ├── dashboard/
│   │   ├── server.ts             ← HTTP server, auth middleware
│   │   ├── views/                ← server-rendered HTML
│   │   └── auth.ts               ← password check, session cookies
│   └── lifecycle/
│       ├── shutdown.ts           ← signal handlers, graceful drain
│       └── cycle.ts              ← /cycle command handling
└── package.json
```

Most files are 50-150 lines. Anything bigger is a smell.

## The Channel ↔ Harness pipeline

The hot path for a Slack DM:

```
Slack webhook
   ↓
slack.ts receives it
   ↓
verify signature, extract sender + content
   ↓
write to messages_in (SQLite)
   ↓
write to audit_events (SQLite)
   ↓
poke the harness subprocess (stdin write, or signal)
   ↓
harness streams NDJSON to stdout
   ↓
harness.claude.ts parser
   ↓
on `tool_use` / `text` events: write to messages_out + audit
   ↓
on `text` complete: slack.ts.send(channel, content)
   ↓
on Slack API response: write to messages_log + audit
```

Three SQLite tables touched (`messages_in`, `messages_out`,
`audit_events`); two adapters in play (Slack in, harness in/out);
zero IPC dances. The "single SQLite + single subprocess" topology
makes this dramatically simpler than v1's container-per-zone version.

## Authoritative state

Held in SQLite. Tables (rough sketch):

- `messages_in` — inbound messages from channels, with sender +
  channel + content + ts.
- `messages_out` — outbound messages to channels, with delivery status.
- `audit_events` — the taxonomy from `../ideas/investigations/06-audit-events.md`
  (which survives the architecture pivot intact, just with smaller
  scope).
- `scheduled_messages` — cron + one-shot scheduled sends.
- `dashboard_users` — operator login(s), Argon2id hash.
- `dashboard_sessions` — active dashboard sessions.
- `http_log` — what the logging proxy captured.

The `messages_*` and `http_log` tables are size-bounded by retention
policy; `audit_events` is keep-forever (~10MB/year at personal scale).

Held in memory:

- The bootstrap env (so it never gets written to a log).
- The harness subprocess handle.
- The active channel-adapter instances.
- The dashboard session cache.

Held on disk **outside** SQLite:

- `~agent/.claude/projects/` — harness session JSONL files. The host
  reads these only for the dashboard's "session list" view; the host
  never writes to them.

## Dashboard

Server-rendered HTML, htmx for interactivity. Pages:

- **Status** — agent up/down, harness version, framework version,
  last activity, last error.
- **Audit log** — paginated, filterable by event type, time range,
  thread, tool.
- **Sessions** — list of active and recent harness sessions with
  message counts.
- **Channels** — wired channels, send/receive counts, last activity.
- **Scheduled** — upcoming scheduled messages, create new, cancel.
- **Chat** — a built-in chat surface; talking here is identical to
  DMing the agent on Slack except it routes through the dashboard
  channel adapter.
- **Settings** — read-only display of `agent.config.toml` and
  `framework_version`. No editing in v1 (edits go through the repo).

Auth is non-optional: an Argon2id-hashed password, login form, session
cookie. The dashboard is internet-reachable via exe.dev HTTPS; without
auth it's a free agent for anyone who finds the URL.

## Lifecycle

Boot:

1. Read `/etc/agent/env`.
2. Read `agent.config.toml`.
3. Open SQLite, run migrations.
4. Start logging proxy.
5. Spawn the harness with uid=`agent`, env injected.
6. Mount channel adapters from config.
7. Start dashboard server.
8. Start cron tick (or Honker scheduler).

Shutdown (`SIGTERM`):

1. Stop accepting new webhooks.
2. Mark all in-flight conversations as `paused` in audit log.
3. SIGTERM the harness, wait up to 10s.
4. SIGKILL if still alive.
5. Close SQLite cleanly.
6. Exit.

Cycle (`/cycle` command):

1. SIGTERM the harness, wait up to 10s.
2. SIGKILL if still alive.
3. Optionally wipe `~agent/.claude/projects/<workspace>/*.jsonl` for
   a "fresh context" cycle.
4. Spawn a new harness.
5. Emit audit event `process.cycle`.

The old v1 supervisor-pattern (tini → bun supervisor → agent-runner)
is gone. The host process IS the supervisor; it spawns the harness
directly.

## Open sub-questions

- **Watchdog: how does the host know the harness is stuck?** A
  heartbeat: harness writes a timestamp to a known path every N
  seconds (or emits a periodic NDJSON heartbeat event). Stale
  heartbeat → host issues a `/cycle`.
- **Multiple concurrent conversations.** Slack DMs and dashboard
  chat could land in the same harness simultaneously. Does the
  harness handle interleaving, or do we serialize? Default: serialize
  through a single in-flight queue. Revisit if it gets in the way.
- **Plugin pattern for new channel adapters.** Right now adapters
  live in the framework image. Could user-side adapters be added via
  `agents/<name>/adapters/`? Defer until there's a real reason.
- **Dashboard websocket / SSE for live updates.** v1 can just be
  htmx `hx-trigger="every 5s"` polling. Real-time can come later.
