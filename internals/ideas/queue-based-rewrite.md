# Queue-based rewrite

Date: 2026-05-17 (revised after the design-principles + trust-zones docs landed)
Status: thinking out loud, no code yet

The storage and RPC architecture that supports the trust-zone container
model. Read `design-principles.md` and `trust-zones.md` first — this doc
assumes both.

## Premise

NanoClaw's "per-session SQLite files mounted into containers" design solves
a real problem (cross-mount lock contention, no shared writers) but pays
for it with a lot of complexity: dual-DB dance, seq parity, `on_wake`
column, `journal_mode=DELETE`, `processing_ack` sync,
heartbeat-as-file-touch, no automatic cleanup. Most of that complexity
exists to make file-as-IPC work safely across docker volume mounts.

If the host owns one DB and containers talk to it over RPC, all of that
goes away. Honker handles the queue and pub/sub. Containers become
long-lived workers scoped to one trust zone.

## Architecture

```
                ┌────────────────────────────────────────┐
                │           HOST process (Node)           │
                │                                         │
   Channel ─→ ─→│  Channel adapters → Router (zone pick) │
   adapter      │       │                                  │
                │       ▼                                  │
                │   ┌─────────────────────────────────┐   │
                │   │  Single SQLite (better-sqlite3) │   │
                │   │  Honker: queue, cron, pub/sub   │   │
                │   │  Tables: users, zones,          │   │
                │   │  messages, audit, scheduled, … │   │
                │   └─────────────────────────────────┘   │
                │       ▲                                  │
                │       │                                  │
                │  RPC handlers (intent-shaped verbs)     │
                │  scoped by per-zone RPC token           │
                └───────┬─────────────────────────────────┘
                        │ Unix domain socket, host-only
                        │
        ┌───────────────┴───────────────────┐
        │                                   │
        ▼                                   ▼
┌──────────────────────┐         ┌──────────────────────┐
│  dm-trust container  │         │ public-trust container│
│  (long-lived)        │         │ (long-lived)          │
│                      │         │                       │
│  Agent runtime       │         │  Agent runtime        │
│  Local SQLite        │         │  Local SQLite         │
│  (session state)     │         │  (session state)      │
│  Skills + tools w/   │         │  Skills + tools w/    │
│  rw credentials      │         │  ro credentials       │
│                      │         │                       │
│  RPC client → host   │         │  RPC client → host    │
└──────────────────────┘         └──────────────────────┘
```

Two containers, one DB file, one RPC surface. That's the whole topology.

## RPC API (intent-shaped)

The host exposes verbs, never queries. Each call carries the zone's RPC
token; host validates `token → zone_id` and rejects scope violations.

```
claim_work()                            → returns 0..N pending messages for this zone
                                           (sender_id, channel_id, content, history, system_prompt)
record_message(message)                 → write an outgoing message
                                           (channel_id, content, thread_id?, files?[])
schedule_message(at, message)           → enqueue a future message via Honker cron/timer
ask_user_question(channel_id, q, opts)  → host delivers, waits, returns answer
request_credential(name, reason)        → out-of-band credential request (host policy decides)
emit_audit(event_type, payload)         → audit log entry (see investigations/06-audit-events.md)
heartbeat()                             → liveness ping; visibility timeout reset
```

The catalog with full failure modes lives in `investigations/07-rpc-catalog.md`.

What you don't see and won't ever see: `select_from_messages`,
`update_session_state(sql=…)`, `get_user_record(id)`. If you can't name
the intent without leaking SQL, the endpoint isn't designed yet.

## Container API surface

The agent runtime inside each container is mostly Claude SDK + MCP tools
that are HTTP shims over the RPC verbs above:

```
MCP tool send_message     → POST claim, then record_message on host
MCP tool schedule_task    → schedule_message
MCP tool ask_question     → ask_user_question (blocks until answer)
MCP tool send_file        → record_message with multipart body
```

No SQLite client. No file mounts shared with the host. No filesystem
heartbeat. The container has its own local SQLite for session state and
that's a black box to the host (see `design-principles.md` §5).

## What goes away vs NanoClaw

- Dual-DB split (`inbound.db` + `outbound.db` per session)
- Cross-mount visibility hacks (`journal_mode=DELETE`)
- Seq parity (host=even, container=odd)
- `on_wake` column (race between dying container and fresh one)
- `processing_ack` sync between outbound → inbound
- File-touch heartbeat
- Manual session cleanup (a TTL cron is one SQL statement now)
- Per-session schema migrations (only one schema to migrate)
- The per-agent-group container spawn/kill dance
- Most of `session-manager.ts`, all of `container/agent-runner/src/db/`

## What we keep (in spirit)

- The **entity model is rebuilt, not reused.** No `agent_groups`,
  `messaging_groups`, `messaging_group_agents` with `session_mode`. The new
  entities are: `users`, `user_aliases`, `trust_zones`, `zone_assignments`,
  `channel_zone_overrides`, `messages`, `audit_events`, `scheduled_tasks`.
- Channel adapter pattern — orthogonal to storage. Slack/Discord/etc.
  adapters look almost identical to NanoClaw's.
- Boundary credential injection — same idea as OneCLI, but per-zone env
  instead of per-agent. May or may not need OneCLI itself.
- Intent of `ncl` admin CLI — small CLI that hits the host's admin RPC
  endpoints, never the DB directly.

## Things to remember

- **Mid-response push.** Claude's query streams. If a new message lands for
  the same zone mid-stream, we want it injected into the current query
  (NanoClaw's `query.push()` trick). With long-lived containers and RPC,
  this is a host-pushed event via the Unix socket — see
  `investigations/04-idle-wake.md`.
- **Visibility timeouts.** Honker has them; use them. If a container
  crashes mid-claim, the lease expires and the message goes back on the
  queue.
- **Out-of-band inspection.** Lose `sqlite3 inbound.db 'SELECT *'`. Replace
  with `ncl messages list --zone dm-trust --since 1h`. Same expressiveness,
  central source.
- **Audit, not session, is the host's window into containers.** Containers
  emit events at significant moments. See
  `investigations/06-audit-events.md`.

## SQLite + Honker vs Postgres + pg-boss

Default: **SQLite + Honker**. One process, one file, no daemons. Backup
is `cp data.db data.db.bak`. SQLite write throughput is plenty for human-
scale chat.

Trigger to revisit: I want Honcho (pgvector continual memory), or Honker
goes unmaintained at alpha. See `investigations/01-honker-reality.md`.

## Source-of-truth ranking, in this design

1. **The single host SQLite** (zones, queue state, identity, audit, messages).
2. **The host's RPC layer** (sole DB writer + access enforcement).
3. **Trust-zone containers** = long-lived compute with local ephemera. Can
   be torn down and respawned; only session memory is lost, never user-
   meaningful data.

That ranking is the inverse of NanoClaw's, where each container is the
sole authority on its outbound DB. The RPC version trades that distributed
ownership for centralized clarity.
