# NanoClaw v2: Architecture from Docs

## 1. What NanoClaw is

NanoClaw is a self-hosted AI agent orchestrator that connects Claude to multiple messaging platforms (Discord, Slack, Telegram, WhatsApp, GitHub) through a containerized runtime. The core design prioritizes understanding over complexity: the entire host codebase is under 10k lines of Node.js; agents run in isolated Docker containers using the Claude Agent SDK; channels and providers install as git branches (skills), not bundled features.

The system is built around **single-writer databases** to eliminate cross-mount write contention. Host process runs the router, delivery, session manager, and a periodic sweep. Each agent session spawns its own container that polls inbound work, executes Claude queries, and writes results. Communication happens only via SQLite files on shared mounts—no IPC, no shared modules, no stdin piping.

See: `README.md` (philosophy), `docs/architecture.md` (core design), `docs/build-and-runtime.md` (split stack rationale)

---

## 2. The entity model

NanoClaw uses a three-table many-to-many design that replaces v1's flat `registered_groups` table:

- **`agent_groups`** — named agent instances, each with a folder (`groups/<name>/`), provider (Claude/Codex/OpenCode), container config.
- **`messaging_groups`** — chat locations (Discord server, Slack workspace, Telegram chat, etc.) with `channel_type` and `platform_id`.
- **`messaging_group_agents`** — junction table linking agents to chats, with routing rules (`engage_mode`, `engage_pattern`), `session_mode` (agent-shared / per-thread / separate), response scope, priority.

One agent can answer on many chats; one chat can fan out to many agents. Privilege is explicit via `user_roles` (owner/admin, global or group-scoped). `unknown_sender_policy` controls whether unregistered users can trigger the agent (strict / request_approval / public).

See: `docs/db-central.md:§1.1-1.3` (schema), `docs/architecture.md:§1-2` (routing), `docs/isolation-model.md` (session modes)

---

## 3. The three-DB model

**Central DB** (`data/v2.db`) — Host-owned, everything that isn't per-session: agent groups, messaging groups, users, roles, wirings, pending approvals, schema migrations.

**Inbound DB** (`inbound.db` per session) — Host writes, container reads. `messages_in` (user/task/webhook input), `delivered` (outbound delivery status), `destinations` (per-session routing projection), `session_routing` (default destination).

**Outbound DB** (`outbound.db` per session) — Container writes, host reads. `messages_out` (chat replies, edits, reactions, tasks), `processing_ack` (container status for inbound messages), `session_state` (persistent KV store for Chat SDK resume).

**Single-writer rule:** Each file has exactly one writer. Host writes central + inbound; container writes outbound. Host reads outbound; container reads inbound. No locks, no cross-mount contention. Both session DBs use journal mode DELETE (not WAL) for cross-mount visibility.

**Sequence numbering (parity):** Host assigns even seq to `messages_in` (2, 4, 6…); container assigns odd seq to `messages_out` (1, 3, 5…). Global ordering is preserved. Parity alone disambiguates when routing edits/reactions (`seq % 2` determines which table to look in).

See: `docs/db.md` (architecture overview), `docs/db-session.md` (inbound/outbound schema), `docs/db-central.md` (central schema)

---

## 4. Host process

The host is a Node.js orchestrator spawning one container per active session. Key responsibilities:

- **Router** — Receives messages from all channel adapters, extracts sender/platform/channel identity, looks up wired agents, filters by `engage_mode`/`engage_pattern`, applies `sender_scope` and `unknown_sender_policy`, writes to `messages_in`.
- **Session manager** — Creates / destroys session folders and container instances. Provisions inbound/outbound DBs with `ensureSchema()`. Dispatches container wake (immediate or delayed via `process_after`).
- **Delivery poller** — Reads `messages_out`, dispatches to channel adapters by kind/operation. Writes `delivered` table with platform message ID (for edits/reactions). Handles retries with exponential backoff.
- **Container runner** — Spawns Docker with fixed mounts (`/workspace/inbound.db`, `/workspace/outbound.db`), environment variables, entry point.
- **Host sweep** — Periodic background task. Wakes containers whose scheduled tasks are due (process_after ≤ now). Syncs `processing_ack` from outbound back to `messages_in` status.

Channels install as skills (git branches), not native imports. All adapters are wired through a unified Chat SDK bridge that extracts platform-specific identity, reconstructs conversation history, and maps to a standard `ChannelAdapter` interface.

See: `src/index.ts` (main), `src/router.ts` (routing logic), `src/session-manager.ts` (session lifecycle), `src/delivery.ts` (outbound dispatch), `src/host-sweep.ts` (scheduled wake)

---

## 5. Agent container

Each session container is a Bun runtime instance running the agent-runner. One turn of work:

1. **Poll** `messages_in` WHERE status='pending' AND (process_after IS NULL OR process_after ≤ now)
2. **Format** by kind (chat → conversation XML, task → script output, webhook → JSON payload, system → action invocation)
3. **Query** the agent provider (Claude/Codex/OpenCode) with formatted prompt, allowed MCP tools, session resume point
4. **Process events** from the provider stream (init, result, error, progress, tool_use blocks)
5. **Write** results to `messages_out` with appropriate kind, routing (platform_id/channel_type/thread_id), and operations (edit, reaction, card, question, agent-to-agent send)
6. **Update** `processing_ack` with final status

**MCP tools available inside the container:**
- `send_message` — writes chat message to `messages_out`
- `send_card` / `ask_user_question` — blocking interactive cards stored in central `pending_questions` table
- `edit_message` / `add_reaction` — target prior message by seq (parity routes to correct table)
- `send_to_agent` — agent-to-agent message (channel_type='agent')
- `schedule_task` — inserts to `messages_in` with `process_after` and optional `recurrence` (cron)
- `send_file` — moves file to `outbox/{message_id}/`; host delivers to adapter

**Agent provider interface:** Abstraction over Claude Agent SDK / Codex / OpenCode. Each provider implements `query(QueryInput)` returning `AsyncIterable<ProviderEvent>`. Claude provider wraps `@anthropic-ai/claude-agent-sdk`, handles session resume via `resumeSessionAt`, streaming input to keep stdin open, Pre-agent hooks for task scripts.

See: `container/agent-runner/src/agent-runner.ts` (poll loop), `container/agent-runner/src/db/messages-out.ts` (write logic), `docs/agent-runner-details.md` (provider interface, tool docs, media handling)

---

## 6. Channels and providers

**Channels** (Discord, Slack, Telegram, WhatsApp, GitHub, Gmail, etc.) install via skills. Each channel:
- Implements `ChannelAdapter` interface: `setup()`, `teardown()`, `isConnected()`, `deliver()`, `setTyping()`, `syncConversations()`
- Registers auto-discovery of new chats/threads
- Runs on the host (except Chat SDK agent bridge which runs at session level)
- Is wrapped by a unified Chat SDK Bridge that handles identity extraction, conversation reconstruction, and subscription/polling

Channel setup happens in `src/channels/index.ts` (barrel import + Chat SDK bridge). New channels merge via skill branches and npm dependencies.

**Agent providers** implement `query()` interface:
- **Claude** — wraps `@anthropic-ai/claude-agent-sdk`, full agentic loop, streaming input, resume points
- **Codex** — wraps OpenAI Codex SDK (enterprise)
- **OpenCode** — wraps OpenCode SDK (open source alternative)

Provider selection is per-agent via `agent_groups.agent_provider`. Container startup reads the value and instantiates the correct provider. Different providers have different model selection, abort behavior, and cost/throughput characteristics.

See: `docs/api-details.md` (ChannelAdapter interface), `docs/agent-runner-details.md` (provider interface), `src/channels/index.ts` (barrel), `container/agent-runner/src/providers/` (implementations)

---

## 7. OneCLI / credentials

v1 used `.env` environment variables directly. v2 uses **OneCLI Agent Vault**, a separate local service (`http://127.0.0.1:10254`) that holds secrets in an encrypted store.

Agents are scoped to specific secrets. The vault injects credentials into approved API requests as they leave the container—agents never see raw secret values. This prevents prompt injection from exfiltrating credentials.

**Auto-created agents default to `selective` secret mode** (no secrets attached). To enable secrets, run:
```
onecli agents set-secret-mode --mode all
```

During v1→v2 migration, `.env` keys are copied verbatim to v2 `.env`, and vault seeding happens via the `/init-onecli` skill. Channels that need auth (WhatsApp Baileys keystore, Matrix sync state, iMessage tokens) have per-channel registries in `setup/migrate-v2/shared.ts` for file migration.

See: `docs/v1-to-v2-changes.md:§Credentials`, `docs/build-and-runtime.md` (stack rationale), `.env` (example, not committed)

---

## 8. Isolation model

Three levels of channel isolation, controlled by `messaging_group_agents.session_mode`:

**Level 1: Shared session** (`session_mode='agent-shared'`) — Multiple channels feed the same conversation. One agent sees all of them together. Example: Discord + Slack + Telegram all talking to one session. Isolation boundary is agent_group_id only. Cross-channel context visible.

**Level 2: Same agent, separate sessions** (`session_mode='shared'` or `'per-thread'`) — Multiple channels use the same agent but own independent conversations. They share the agent's memory (`session_state`) and folder, but `messages_in`/`messages_out` rows are per-session. Example: Discord server 1 and Discord server 2, different threads.

**Level 3: Separate agents** (different `agent_group_id`) — Each channel has its own agent folder, memory, and provider config. Complete isolation. Example: Discord gets `discord-bot` agent, Slack gets `slack-bot` agent.

Decision matrix: shared session if participants should see each other's context; separate session if they need privacy; separate agents if they need different personalities/skills. Routing is configured in `messaging_group_agents` rows.

See: `docs/isolation-model.md`, `docs/architecture.md:§6` (PR Factory example showing all three levels)

---

## 9. Key invariants

1. **Single writer per file.** Host writes central + inbound; container writes outbound. Enforced by code, not constraints. Cross-mount safety.
2. **Sequence parity.** Host uses even seq, container uses odd. Global ordering. Parity disambiguates edit/reaction routing without a join.
3. **Everything is a message.** No IPC, no shared memory. Router writes `messages_in`; container polls and writes `messages_out`; host delivery reads. Status updates flow via `processing_ack` (container writes, host reads, host writes back to `messages_in`).
4. **Journal mode DELETE.** Both session DBs use DELETE journaling, not WAL. Required for cross-mount visibility (WAL breaks on NFS, shared mounts).
5. **Heartbeat out of band.** Container liveness is a file touch (`.heartbeat` mtime), not a DB write. Host sweep checks mtime to detect hangs.
6. **Lazy session-DB migrations.** Fresh sessions get current schema via `CREATE TABLE IF NOT EXISTS`. Existing folders patched on open (e.g., `migrateDeliveredTable()` adds columns if missing).
7. **ACL as row existence.** Destinations table is a projection of central `agent_destinations`. Container resolves `to="name"` against it; missing row = rejected send.
8. **Seq continuity across both tables.** When container writes `messages_out`, it reads MAX(seq) across *both* `messages_in` *and* `messages_out`, applies parity rule. Ensures no gaps even if either table is ahead.
9. **No compiled build step in container.** Agent-runner is pure TypeScript. Bun runs it directly. No `/app/dist`. Dockerfile has no build stage.
10. **Split package managers.** Host uses pnpm (Node 22, native deps like Baileys). Container uses Bun (1.3+, pure Bun-compatible packages). Supply chain: host holds 3 days, container has no hold.

See: `docs/db.md:§Single-writer rule§`, `docs/db-session.md:§3§` (seq parity), `docs/build-and-runtime.md` (stack, Dockerfile, CI)

---

## Doc discrepancies

**Minor:** `docs/SPEC.md` appears written from v1 perspective with v2 references added. References to "v1 features" (e.g., trigger word matching, command parsing) lack clear v2 equivalents. Not load-bearing for v2 understanding; primarily historical.

**No blocking contradictions found.** All core docs (architecture.md, db.md, db-central.md, db-session.md, agent-runner-details.md, build-and-runtime.md) are internally consistent. Schema definitions match field usage across routing, message formatting, and delivery dispatch.

---

**Document version:** Based on v2 HEAD docs (May 2026). Validated against v1-to-v2-changes.md migration guide for consistency.
