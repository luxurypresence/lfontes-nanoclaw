# Host responsibilities

The Node host process. One process on the VM. Orchestrates N
containers. Target ~1500 LOC of TypeScript including the CLI.

## What the host does

| Subsystem | Approx LOC | Notes |
|-----------|------------|-------|
| CLI (`agent-host` subcommands) | ~250 | start, bootstrap, new-agent, migrate, cycle, status, doctor, stop. |
| Config loader | ~80 | Parse `host.config.toml`, every `agent.config.toml`, validate with Zod. |
| Env loader | ~50 | Read `/etc/agent/env`, hold in memory, filter per agent at spawn. |
| Container orchestrator | ~200 | `docker run` to start containers, `docker exec` for I/O, `docker stop`/`kill` for lifecycle. |
| NDJSON I/O multiplexer | ~150 | One process per container exec session; read/write NDJSON; dispatch by `type`. |
| Channel adapters | ~300 (Slack alone) | One adapter per platform. Slack first. Each handles its own webhook signature verification and outbound send. |
| Webhook receiver | ~80 | HTTP server, routes by URL path to right adapter, verifies signatures, posts to internal dispatch. |
| Router | ~80 | `(channel, sender) → agent` resolution. Reads `agent.config.toml`'s `allow_senders`. |
| Logging proxy | ~50 | HTTP forward proxy, logs metadata. |
| Dashboard server | ~200 | Server-rendered HTML, htmx for interactivity, auth-gated. |
| Auth | ~50 | Argon2id check, session cookie. |
| SQLite layer | ~150 | Open `data/agent.db`, run migrations on boot, prepared statements. |
| Scheduler / cron | ~80 | Interval-based; reads `scheduled_messages`, dispatches due ones. |
| Watchdog | ~50 | Per-container heartbeat check; auto-cycle on stale heartbeat. |
| Boot / shutdown | ~50 | Signal handlers, graceful drain. |

Sum: ~1700 LOC, slightly over the ~1500 target. Worth knowing; budget
to revisit at first refactor.

## What the host does NOT do

- **Implement an agent loop.** Harness does that, inside each
  container.
- **Translate or rewrite the user's dotfolder.** Deploy-time merge,
  read-only mount.
- **Maintain a vault.** Env injection at spawn time.
- **Coordinate across VMs.** v3-hybrid is one VM. If you have two,
  they're independent installs (see v2-flat aggregation notes).
- **Run an LLM inference path itself.** Harnesses do all model
  calls; host doesn't see them (only metadata via the proxy).
- **Implement per-tool capability checks.** The harness's allowlist
  is the gate.

## Module sketch

```
@yourname/agent-host/
└── src/
    ├── index.ts                    ← `agent-host` CLI entry
    ├── cli/                         ← subcommands
    │   ├── start.ts
    │   ├── bootstrap.ts
    │   ├── new-agent.ts
    │   ├── migrate.ts
    │   ├── cycle.ts
    │   ├── status.ts
    │   ├── doctor.ts
    │   └── stop.ts
    ├── config/
    │   ├── host.ts                  ← parse host.config.toml
    │   ├── agent.ts                 ← parse agent.config.toml (per agent)
    │   └── schema.ts                ← Zod schemas, shared types
    ├── env/
    │   └── loader.ts                ← read /etc/agent/env, filter per agent
    ├── containers/
    │   ├── orchestrator.ts          ← docker run / exec / stop / kill
    │   ├── ndjson.ts                ← reads/writes NDJSON over exec streams
    │   ├── watchdog.ts              ← heartbeat tracking
    │   └── lifecycle.ts             ← startup, cycle, shutdown sequencing
    ├── channels/
    │   ├── registry.ts              ← adapter lookup
    │   ├── slack.ts                 ← Slack adapter
    │   ├── dashboard.ts             ← in-app chat adapter
    │   └── types.ts                 ← ChannelAdapter interface
    ├── router/
    │   └── router.ts                ← (channel, sender) → agent
    ├── proxy/
    │   └── logging-proxy.ts         ← HTTP forward proxy
    ├── scheduler/
    │   └── cron.ts                  ← scheduled message dispatch
    ├── audit/
    │   └── events.ts                ← write to audit_events table
    ├── db/
    │   ├── connection.ts            ← open SQLite, pragmas
    │   ├── migrations.ts            ← runner
    │   └── statements.ts            ← prepared statements
    ├── dashboard/
    │   ├── server.ts                ← HTTP server
    │   ├── auth.ts                  ← password + session
    │   └── views/                   ← server-rendered HTML pages
    └── lifecycle/
        └── shutdown.ts              ← signal handlers, graceful drain
```

Most files 50-150 lines. Anything bigger is a smell.

## The hot path: a Slack DM round-trip

For an inbound Slack DM to `personal-dm`:

```
Slack webhook arrives at https://my-agents.exe.dev/slack/events
   ↓
host's HTTP server
   ↓
channels/slack.ts verifies signature, parses event
   ↓
extracts (channel="slack-dm", sender="U_luis", content="hello")
   ↓
router/router.ts: (slack-dm, U_luis) → agent "personal-dm"
   ↓
write to messages_in (audit + persistence)
   ↓
write to audit_events: { kind: "message.in", ... }
   ↓
containers/orchestrator.ts looks up the personal-dm exec stream
   ↓
write to that stream's stdin:
   {"type":"message","content":"hello","thread":"slack:T0LP:D123:1700.5","channel":"slack-dm","sender":"user:luis"}
   ↓
(inside container) shim forwards to harness stdin
   ↓
(inside container) harness reads, processes, emits stream-json events to stdout
   ↓
(inside container) shim wraps each line: {"type":"harness.event","event":...}
   ↓
host reads that NDJSON from the exec stream
   ↓
containers/ndjson.ts dispatches by event.type:
   ├─ text event → channels/slack.ts.send(channel, content)
   ├─ tool_use event → audit_events row, dashboard live update
   └─ tool_result event → audit_events row
   ↓
Slack adapter sends, captures Slack's message_id, records in messages_out + audit
```

Round-trip in seconds. No per-message Docker invocation — same
container, same exec session, same shim and harness. Just NDJSON
flying back and forth.

## Per-agent state held in memory

For each running agent, the host keeps:

```ts
type AgentRuntimeState = {
  config: AgentConfig;                  // parsed agent.config.toml
  containerId: string;
  execStream: {
    stdin: WritableStream<string>;       // NDJSON commands to shim
    stdout: ReadableStream<string>;      // NDJSON events from shim
    stderr: ReadableStream<string>;      // raw stderr (for crashes)
  };
  lastHeartbeat: number;                 // timestamp from last heartbeat event
  pendingMessages: Set<string>;          // messages sent but no response yet
  injectedEnvKeys: string[];             // for audit (which keys, not values)
};

const agents = new Map<string, AgentRuntimeState>();
```

When a container cycles, the entry is replaced (new containerId,
new exec stream). The map is the host's mental model of "what's
running."

## Authoritative state in SQLite

Tables:

- `messages_in` — inbound from channels.
- `messages_out` — outbound to channels, with delivery status.
- `audit_events` — taxonomy from `../ideas/investigations/06-audit-events.md`
  with the v3-hybrid adjustments noted in `observability.md`.
- `scheduled_messages` — cron + one-shot.
- `dashboard_users` — Argon2id hash.
- `dashboard_sessions` — active dashboard logins.
- `http_log` — logging proxy.
- `schema_migrations` — applied schema versions.

Held in memory:
- The loaded env (`/etc/agent/env` contents).
- Channel adapter instances.
- The `agents` map above.
- The dashboard session cache.

On disk outside SQLite:
- `data/sessions/<name>/projects/` — harness session JSONLs. Host
  reads (for the dashboard's session list) but never writes.

## Dashboard

Single URL: `https://my-agents.exe.dev/`. Password-protected. Views:

- **Overview** — list of agents, status per agent (up/down/cycling),
  last activity, recent errors.
- **Audit** — paginated, filterable: by event type, time range,
  agent, thread, tool.
- **Sessions** — per-agent list of recent sessions with message
  counts.
- **Channels** — wired channels with send/receive counts.
- **Scheduled** — upcoming scheduled messages, create new, cancel.
- **Chat** — in-app chat through the dashboard adapter. Routes via
  the router like any other channel.
- **Settings** — read-only display of `agent.config.toml` per agent,
  `host.config.toml`, framework version. Editing goes through the
  repo.

Auth is non-optional. Argon2id-hashed password, session cookie,
login form. Internet-reachable via exe.dev HTTPS; without auth it's
a free agent.

## Container lifecycle (host's view)

```
agent-host start
   ↓
load host.config.toml + each agent.config.toml
   ↓
open SQLite, run migrations
   ↓
start logging proxy (port from host.config.toml)
   ↓
start webhook HTTP server (port from host.config.toml)
   ↓
start dashboard HTTP server (separate port)
   ↓
for each agent:
   ├─ check existing container: `docker ps -a -f name=agent-<name>`
   ├─ if exists and running: docker exec to attach
   ├─ if exists and stopped: docker start, then docker exec
   └─ if doesn't exist: docker run with full args
   ↓
spawn exec session, wait for shim.ready event
   ↓
mark agent as live in `agents` map
   ↓
start watchdog tick (every 5s; check heartbeats)
   ↓
start scheduler tick (every 5s; check scheduled messages)
   ↓
serve forever
```

Shutdown on SIGTERM:

```
SIGTERM
   ↓
stop accepting new webhooks
   ↓
mark in-flight conversations as paused in audit
   ↓
for each agent: write {"type":"shutdown"} to exec stream
   ↓
wait up to 10s for shim to ack via exit
   ↓
docker stop any remaining containers
   ↓
close SQLite
   ↓
exit
```

Cycle (`agent-host cycle <name>` from CLI or dashboard):

```
write {"type":"cycle","mode":"fresh"} to that agent's exec stream
   ↓
shim handles internally (kill harness, clear projects/, respawn)
   ↓
shim emits new {"type":"shim.ready"} when ready
   ↓
host marks agent live again
   ↓
emit audit event: process.cycle
```

No `docker restart` needed — the container stays up, the harness
inside cycles.

## Open sub-questions

- **Channel adapters per agent vs. shared.** A single Slack app
  with webhooks for multiple agents needs routing by Slack workspace
  or by channel-to-agent mapping in `agent.config.toml`. The
  router handles this; channels themselves aren't per-agent code.
- **Concurrent inbound messages.** Slack DM and dashboard chat
  arriving simultaneously to the same agent — does the shim
  serialize, or does the harness handle interleaving? Default:
  shim queues if a turn is in flight; harness sees them sequentially.
  Revisit if it's a problem.
- **Container respawn on host crash.** If the host crashes and
  systemd restarts it, existing containers are still running. Host
  reattaches via `docker exec`. The shim's last `shim.ready` may
  need a new emit; the protocol should tolerate the host
  disconnecting and reconnecting to an already-running shim.
- **Plugin pattern for new channel adapters.** Currently part of
  the framework npm package. Could user-side adapters be added via
  `agents/<name>/adapters/` directly? Defer until there's a real
  reason.
- **Dashboard live updates.** htmx `hx-trigger="every 5s"` polling
  is enough for v1. SSE or websocket can come later.
