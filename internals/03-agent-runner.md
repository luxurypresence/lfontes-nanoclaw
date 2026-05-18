# NanoClaw v2 Agent Runner: Container-Side Architecture

A comprehensive study of `/home/exedev/nanoclaw/container/agent-runner/src/` — the Bun process that runs inside every per-session container, polling inbound messages, calling the Claude agent, and writing responses to outbound messages.

---

## 1. Container Boot

**Entry point:** `bun run /app/src/index.ts` (via `entrypoint.sh`).

**Entrypoint flow** (`entrypoint.sh`):
- Captures stdin (initial session params from host) to `/tmp/input.json` for post-mortem inspection.
- Exec's bun as child of tini (PID 1) so signals propagate cleanly.
- All further IO flows through session DBs — no stdin/stdout markers.

**Mount structure** (`index.ts:10-21`):
- `/workspace/inbound.db` — host-owned session DB (container reads only).
- `/workspace/outbound.db` — container-owned session DB (container writes).
- `/workspace/.heartbeat` — file touched on every poll iteration for liveness detection.
- `/workspace/outbox/` — outbound files (send_file).
- `/workspace/agent/container.json` — per-group config (RO nested mount).
- `/app/src/` — shared agent-runner source (RO mount).
- `/app/skills/` — shared skills (RO).
- `/home/node/.claude/` — Claude SDK state + skill symlinks (RW).

**Config load** (`config.ts`):
- Reads `/workspace/agent/container.json` once at startup via `loadConfig()`.
- Provides: `provider`, `assistantName`, `groupName`, `mcpServers`, `model`, `effort`.
- Falls back to sensible defaults if file is missing.

**System context assembly** (`index.ts:48-54`):
- Builds system-prompt addendum: agent identity (name) + live destinations map from `buildSystemPromptAddendum()`.
- Destinations are queried live from inbound.db on every batch (not cached).
- Shared base CLAUDE.md loaded by Claude Code from `/app/CLAUDE.md`.
- Per-group memory in `/workspace/agent/CLAUDE.local.md` (auto-loaded).

**MCP server wiring** (`index.ts:71-87`):
- Built-in nanoclaw server: `bun run /app/src/mcp-tools/index.ts`.
- Additional servers from `container.json#mcpServers` appended.
- No build step — bun runs TS directly.

**Provider instantiation** (`index.ts:89-96`):
- Creates provider instance via `createProvider()` (Claude by default).
- Passes `mcpServers` config, environment vars (OneCLI networking), `model`, `effort`.

---

## 2. Poll Loop

**Main loop** (`poll-loop.ts:53-220`; pseudocode):

```
1. Fetch pending messages from inbound.db via getPendingMessages()
   - Filtered by status='pending', process_after datetime
   - on_wake column gates wake-from-cold on first poll
   - Capped at maxMessagesPerPrompt (default 10)
   
2. Skip system messages (MCP tool responses)

3. Gate: if batch contains only trigger=0 rows (accumulated context),
         skip processing — wait for a trigger=1 row to join the batch

4. Mark batch as 'processing' in processing_ack (outbound.db)

5. Extract routing (platformId, channelType, threadId, inReplyTo)

6. Command handling:
   - /clear: reset session (inline, container handles)
   - /admin + /passthrough: bail out, let outer loop reopen query

7. Pre-task script gate (scheduling module):
   - Run per-message scripts, skip gated rows

8. Format messages into prompt via formatMessages()

9. Call provider.query({ prompt, continuation, cwd, systemContext })

10. While query active, concurrent polling loop runs every 500ms:
    - If new messages pending: push via query.push()
    - If slash command pending: end stream, let outer loop reprocess
    - Skip system messages (MCP responses)

11. For each event from provider:
    - 'init': persist continuation immediately (mid-turn crash recovery)
    - 'result': dispatch text to destinations, mark batch completed
    - 'error': write error response, detect stale session
    
12. Mark batch completed in processing_ack

13. Loop
```

**Polling timings** (`poll-loop.ts:18-19`):
- Idle poll: 1000ms (waiting for messages).
- Active poll: 500ms (during a query, watching for follow-ups).

**Heartbeat** (`poll-loop.ts:78-79; connection.ts:156-168`):
- Every 30 poll iterations: `touchHeartbeat()` updates `/workspace/.heartbeat` mtime.
- Host watches this file via host-sweep to detect container hangs.
- Cheaper than cross-boundary DB writes.

**Concurrent polling** (`poll-loop.ts:279-356`):
- Query stays open while poll loop runs.
- New messages are pushed mid-stream without re-spawning SDK subprocess.
- Avoids re-loading .jsonl transcript (~seconds latency).
- Server-side prompt cache is 5-min TTL by prefix hash — stream lifecycle does NOT affect cache hits.

---

## 3. on_wake Column

**What it is** (`messages-in.ts:13-24`):
- Nullable int column on messages_in (added v2.0.48).
- `on_wake = 1` (default): wake-eligible, triggers container wake.
- `on_wake = 0`: accumulated context only, collected but don't wake.

**Why it exists**:
- Router stores filtered/ignored messages as `on_wake=0` when `ignored_message_policy='accumulate'`.
- Container must ride these along with the next trigger=1 message so agent sees prior context.
- Without the gate, a warm container processes every accumulate-only batch, defeating the "store as context, don't engage" contract.

**Race with container death**:
- Container queries `on_wake` with `AND (on_wake = 0 OR ?1 = 1)` parameter.
- First poll (`isFirstPoll=true`): parameter = 1 → fetch all pending.
- Subsequent polls: parameter = 0 → skip on_wake=0 rows unless paired with trigger=1.
- Host-side `countDueMessages()` gates the same way for wake-from-cold.
- If container dies mid-batch, new container's first poll re-fetches all pending rows (fresh start).

---

## 4. Formatter

**Entry point** (`formatter.ts:129-155`):
- `formatMessages(messages: MessageInRow[])` → string.
- Prepends `<context timezone="IANA" />` header (v1 behavior; agent interprets all timestamps as local).
- Groups messages by kind: chat, task, webhook, system.
- Returns XML-tagged prompt.

**Chat messages** (`formatter.ts:157-184`):
- Single message: bare `<message>...</message>`.
- Multiple: wrapped in `<messages>` container.
- Attributes: `id="seq"` (for reply_to cross-references), `from="destination_name"`, `sender`, `time` (localized).
- Body: text, quoted_message (if reply_to), attachments.
- Routing fields stripped — agent never sees platform_id, channel_type, thread_id.

**Task messages** (`formatter.ts:200-210`):
- `<task from="..." time="...">` with `scriptOutput` (JSON) + `prompt` (instructions).

**Webhook messages** (`formatter.ts:212-218`):
- `<webhook from="..." source="..." event="...">` with JSON payload.

**Timezone** (`formatter.ts:130; timezone.ts:59`):
- `TIMEZONE` resolved once at module load from `process.env.TZ` (host sets from its own TIMEZONE constant).
- Invalid values fall back to UTC.
- Used to format all timestamps and for scheduling.

**Routing origin** (`formatter.ts:191-198`):
- `findByRouting(channelType, platformId)` → destination name.
- Renders as `from="destination_name"` in XML.
- Enables explicit addressing ("tell Laura that…").

**Thread context** (`formatter.ts:272-286`):
- Slack bridges seed `threadContext` on first engagement (prior thread history).
- Rendered as `<thread_context><m sender="..." time="...">...</m></thread_context>` block above the current message.

**Attachments** (`formatter.ts:245-263`):
- Downloaded files: `[file: name — saved to /workspace/path]`.
- URLs: `[file: name (url)]`.
- Download errors surfaced: `[file: name — could not download (error)]`.

**System prompt assembly** (`destinations.ts:82-131`):
- `buildSystemPromptAddendum(assistantName?)` → appended to prompt.
- Identity: "# You are {name}. Your name is **{name}**."
- Destinations section: lists `send_message` targets, wrapping rules (`<message to="name">...</message>`).
- Recomputed on every batch (destinations table queried live).

**Compact-instructions hook** (`compact-instructions.ts`):
- PreCompact hook outputs custom compaction guidance to stdout.
- Instructs: preserve XML structure (attributes), chronological sequence, wrap reminder.
- Destinations list injected dynamically.
- Invoked by Claude Code before session archive.

---

## 5. Providers

**Registry pattern** (`providers/index.ts`):
- Barrel imports each provider module for side-effect `registerProvider()` call.
- No central provider list — each module self-registers.
- Skills add providers by appending imports.

**Provider interface** (`providers/types.ts`):
- `AgentProvider`: `query(input)`, `isSessionInvalid(err)`, `supportsNativeSlashCommands`.
- `AgentQuery`: `{ push(msg), end(), events (async iterable), abort() }`.
- `ProviderEvent`: 'init', 'result', 'error', 'progress', 'activity'.

**Claude provider** (`providers/claude.ts`):
- Implements `AgentProvider` via `@anthropic-ai/claude-agent-sdk` (Claude Agent SDK).
- Wraps SDK's `sdkQuery()` in a `MessageStream` — async iterable for push-based message feeding.
- Resume: `continuation` is session ID (opaque to poll-loop); persisted per-provider in session_state.
- Stale-session detection: regex on error message for "no conversation found" / "ENOENT.*\.jsonl".

**SDK disallowed tools** (`claude.ts:25-35`):
- CronCreate, CronDelete, CronList, ScheduleWakeup: nanoclaw's scheduling is durable.
- AskUserQuestion: nanoclaw's ask_user_question persists the question + blocks on real reply.
- EnterPlanMode, ExitPlanMode, EnterWorktree, ExitWorktree: Claude Code UI affordances (headless container would hang).
- Blocked by PreToolUse hook; defense-in-depth.

**Tool allowlist** (`claude.ts:42-61`):
- Built-in: Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch, Task, TaskOutput, etc.
- MCP servers: dynamically added via `mcpAllowPattern()` (sanitizes server name, forms `mcp__*__*` prefix).

**Hooks** (`claude.ts:160-232`):
- **PreToolUse**: record tool name + declared timeout (Bash) in container_state; block disallowed tools.
- **PostToolUse / PostToolUseFailure**: clear container_state.
- **PreCompact**: archive transcript to `/workspace/agent/conversations/` as markdown; fetch session summary from sessions-index.json.

**Context compaction** (`claude.ts:244`):
- CLAUDE_CODE_AUTO_COMPACT_WINDOW = 165000 tokens (default; env override via CLAUDE_CODE_AUTO_COMPACT_WINDOW).

**Event translation** (`claude.ts:318-346`):
- SDK emits messages; provider translates to nanoclaw events.
- 'system' + 'init' → 'init' event (continuation).
- 'result' → 'result' event (text).
- 'system' + 'api_retry' → 'error' (retryable).
- 'system' + 'rate_limit_event' → 'error' (quota, not retryable).
- 'system' + 'compact_boundary' → 'result' (compaction confirmation with token count).
- 'system' + 'task_notification' → 'progress'.

---

## 6. MCP Tools

**Tool registration** (`mcp-tools/server.ts`):
- Each tool module calls `registerTools([...])` at module scope.
- `index.ts` imports all modules, then calls `startMcpServer()` to wire them up.

**Core tools** (`mcp-tools/core.ts`):
- `send_message(to?, text)`: write to messages_out; resolve destination, stamp in_reply_to.
- `send_file(to?, path, text?, filename?)`: copy file to /workspace/outbox/{id}/, write message_out.
- `edit_message(messageId, text)`: look up seq in delivered table (platform message ID), write operation='edit'.
- `add_reaction(messageId, emoji)`: look up seq, write operation='reaction'.
- All resolve destination via `resolveRouting()` (defaults to session routing if `to` omitted).

**Scheduling tools** (`mcp-tools/scheduling.ts`):
- `schedule_task(prompt, processAfter, recurrence?, script?)`: write system action to messages_out; host inserts into inbound.db.
- `list_tasks(status?)`: query messages_in grouped by series_id, return live occurrences.
- `update_task(taskId, prompt?, processAfter?, recurrence?, script?)`: write system action.
- `cancel_task(taskId)`, `pause_task(taskId)`, `resume_task(taskId)`: write system actions.
- Timezone-aware: `parseZonedToUtc()` interprets naive timestamps in user's timezone.

**Self-modification tools** (`mcp-tools/self-mod.ts`):
- `install_packages(apt?, npm?, reason?)`: validate package names (regex APT_RE, NPM_RE), write system action.
- `add_mcp_server(name, command, args?, env?)`: write system action to request MCP server wiring.
- Both fire-and-forget; host processes and notifies agent via chat message when approved/rejected.
- Sanitized names, regex validation at boundary + host-side re-validation (defense in depth).

**Interactive tools** (`mcp-tools/interactive.ts`):
- `ask_user_question(question, questionId)`: write system action, blocks on response via findQuestionResponse().

**Agents tools** (`mcp-tools/agents.ts`):
- Create child agents, call inter-agent methods (a2a).

---

## 7. Scheduling

**Two-DB split** (`scheduling/task-script.ts` module hook):
- Container cannot write to inbound.db (host-owned).
- Scheduling operations sent as system actions via messages_out.
- Host reads during delivery and applies changes to inbound.db.

**Pre-task scripts** (`poll-loop.ts:146-157`):
- MODULE-HOOK:scheduling-pre-task triggered before initial batch.
- Returns `{ keep, skipped }` — skipped rows marked completed, not sent to agent.
- Script can gate the task via wakeAgent=false.

**Follow-up pre-task scripts** (`poll-loop.ts:320-331`):
- MODULE-HOOK:scheduling-pre-task-followup triggered on follow-up messages.
- Same gating — a task arriving during an active query still passes through its script.

**Task-script module** (`scheduling/task-script.ts`):
- Reads `content.script` (if present), runs shell command.
- If script returns wakeAgent=false or errors, gates that single task row.
- Returns Promise<{ keep, skipped }>.

**Recurring task handling**:
- Host's recurring-task job wakes the agent at each cron firing.
- Container's scheduling tools write schedule_task system actions.
- Host applies the action to inbound.db before the agent sees the task.

---

## 8. Destinations

**Destination map** (`destinations.ts:44-72`):
- Queried live from inbound.db's `destinations` table on every batch.
- Host writes this table before every container wake AND on demand.
- Container never caches — admin changes take effect immediately (no restart).

**Destination types** (`destinations.ts:15-22`):
- `'channel'`: platform + channel (Slack, Discord, etc.).
- `'agent'`: agent group (a2a routing).

**Lookup by name** (`destinations.ts:49-52`):
- `findByName(name)` → DestinationEntry.
- Used by agent output parsing (`dispatchResultText()`).

**Lookup by routing** (`destinations.ts:58-73`):
- `findByRouting(channelType, platformId)` → destination name.
- Reverse lookup: what does this agent call the sender?
- Used to populate `from="..."` attributes in message XML.

**Agent-to-agent routing** (`poll-loop.ts:473-490`):
- `sendToDestination(dest, body, routing)`: resolves thread per-destination.
- Shared sessions: different destinations may have different thread contexts.
- `resolveDestinationThread()`: queries latest inbound message matching channel+platform, extracts thread_id.

**System prompt assembly** (`destinations.ts:82-131`):
- `buildSystemPromptAddendum()`: generates "## Sending messages" section.
- Lists destinations, wrapping rules, MCP `send_message` tool description.
- Single destination: "Your destination is `name`."
- Multiple: bulleted list, "Wrap each delivered message…"

---

## 9. DB Pragmas

**Cross-mount visibility** (`connection.ts:1-19`):

> Two-DB connection layer. The session uses two SQLite files to eliminate write contention across the host-container mount boundary:
>
>   inbound.db  — host writes new messages here; container opens READ-ONLY
>   outbound.db — container writes responses + acks here; host opens read-only
>
> Each file has exactly one writer, so no cross-process lock contention.
>
> ⚠ Cross-mount visibility: inbound.db MUST be journal_mode=DELETE (set by the host when the file is created). WAL's `-shm` is memory-mapped and VirtioFS does not propagate mmap coherency from host to guest, so a WAL-mode inbound.db would leave this reader frozen on an early snapshot and it would silently never see new host messages.

**Pragma setup** (`connection.ts:53-56, 68-69`):
- Inbound (read-only): `PRAGMA busy_timeout = 5000`, `PRAGMA mmap_size = 0` (disable memory-mapping for cross-mount visibility).
- `openInboundDb()`: fresh connection per query (not cached), max isolation.
- `getInboundDb()`: singleton for tables written once at spawn (destinations, session_routing).

**Outbound (write)** (`connection.ts:78-80`):
- `PRAGMA journal_mode = DELETE` (paired with host's inbound.db).
- `PRAGMA busy_timeout = 5000`.
- `PRAGMA foreign_keys = ON`.

---

## 10. Container-Side ncl

**Location** (`cli/ncl.ts`):
- Executable at `/app/src/cli/ncl.ts` (invoked via `ncl` wrapper in Dockerfile:142-143).
- DB transport instead of Unix socket (inside container, DBs are available).

**Request/Response frames** (`ncl.ts:18-26`):
- RequestFrame: `{ id, command, args }`.
- ResponseFrame: `{ id, ok, data | error }`.

**Write request** (`ncl.ts:49-85`):
- Acquires write lock: `BEGIN IMMEDIATE` on outbound.db.
- Reads max(seq) from both DBs, computes next odd seq.
- Inserts system action into messages_out.

**Poll response** (`ncl.ts:91-127`):
- Polls inbound.db every 500ms for 30s.
- Searches for pending message with matching requestId in content JSON.
- Mark matched row as completed via processing_ack (so agent-runner skips it).
- Extract response frame from content.frame field.

**Arg parsing** (`ncl.ts:133-173`):
- Mirrors host-side client.ts.
- Positional args joined with dashes; named args via `--key value`.
- Returns `{ command, args, json }`.

---

## 11. Image Surface

**Tools baked in** (`Dockerfile`):
- **Bun v1.3.12**: TypeScript runtime for agent-runner + MCP servers.
- **pnpm 10.33.0** + Node CLIs:
  - `claude-code` (v2.1.128): claude-agent-sdk entry point.
  - `agent-browser` (latest): browser automation.
  - `vercel` (v52.2.1): deployment.
  - `mcp-remote` (v0.1.38): MCP over HTTP.
  - `gh` (v2.92.0): GitHub CLI (OneCLI HTTPS proxy injects PAT).

**CJK fonts** (`Dockerfile:17-60`):
- Opt-in via `ARG INSTALL_CJK_FONTS=false`.
- If true: adds `fonts-noto-cjk` (~200MB).
- Default: base emoji + Liberation fonts only.

**Environment variables** (`Dockerfile:64-88`):
- `AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium`.
- `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium`.
- `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` (prevent postinstall re-download).
- `GH_TOKEN=placeholder` (OneCLI proxy overwrites Authorization header).
- `GH_PROMPT_DISABLED=1`.
- `REPOS_ROOT=/workspace/extra/shared` (LP repo clones).
- `WIKI_ROOT=/workspace/extra/wiki` (shared wiki mount).

**Entrypoint** (`Dockerfile:167`):
- `["/usr/bin/tini", "--", "/app/entrypoint.sh"]`.
- tini runs as PID 1, reaps zombies, forwards signals; entrypoint.sh execs bun.

**Source layout** (`Dockerfile:100-105`):
- agent-runner deps cached independently of CLI versions.
- Source NOT baked in — provided by RO mount at runtime.
- `COPY package.json bun.lock ./` + `bun install --frozen-lockfile`.

---

## 12. Bun-Specific Gotchas

**Named parameters** (`messages-out.ts:56-74`):
- bun:sqlite requires named parameters prefixed with `$` in JS object keys.
- Better-sqlite3 auto-stripped the prefix; bun:sqlite does not.
- Example: `$id`, `$seq`, `$content` in the JS object, not `id`, `seq`, `content`.

**No AUTOINCREMENT** (`connection.ts`):
- seq is manually assigned, not AUTOINCREMENT.
- Read max from both DBs, compute next odd (container) or even (host).
- Load-bearing for agent-facing message IDs.

**Database.close() behavior** (`connection.ts:49-52`):
- Test mode returns thin wrapper that no-ops `close()` so in-memory singleton survives.
- Callers do `try/finally { db.close() }` — the wrapper's no-op prevents destruction.

**No pnpm in source tree**:
- agent-runner is pure Bun (bun install → bun.lock).
- No pnpm in `/app` — pnpm is global (installed in Dockerfile for Claude Code).
- Separate lockfiles: host uses pnpm, container uses Bun.

**Fresh connection per poll** (`connection.ts:45-57`):
- `openInboundDb()` used for messages_in polling (where host writes continuously).
- Opens fresh connection each poll for mmap_size=0 (cross-mount visibility).
- Cost: microseconds per query, safe for universal use.

---

## Summary

The agent-runner is a **tightly-scoped Bun process** that:
1. Reads inbound.db (host-owned, RO).
2. Polls for pending messages every 1s (500ms during active query).
3. Formats messages into an XML prompt.
4. Calls Claude via the Agent SDK (with agent-runner MCP tools).
5. Parses agent output for `<message to="...">` blocks.
6. Writes responses to outbound.db (container-owned).
7. Marks batches completed in processing_ack.

**Key invariants:**
- One writer per DB (host ↔ container write contention eliminated).
- journal_mode=DELETE on inbound.db (VirtioFS mmap coherency).
- Destinations queried live (admin changes take effect immediately).
- Continuation persisted mid-turn (crash recovery).
- on_wake gates context-only accumulation (avoid spurious wakeups).
- seq spans both DBs (odd = container, even = host; agent-facing message IDs).
- Thread routing resolved per-destination (agent-shared sessions work correctly).

**File references:**
- `index.ts`: boot, MCP wiring, provider creation.
- `poll-loop.ts`: main loop, concurrent polling, output dispatch.
- `formatter.ts`: message → XML, timezone handling, destination resolution.
- `destinations.ts`: destination map, system-prompt assembly.
- `connection.ts`: DB setup, heartbeat, pragmas.
- `messages-in.ts`: on_wake column, pending fetch, processing_ack.
- `messages-out.ts`: write with odd seq, platform message ID lookup.
- `providers/claude.ts`: SDK integration, hooks, tool allowlist.
- `mcp-tools/`: core (send_message, send_file), scheduling, self-mod.
- `cli/ncl.ts`: container-side CLI via DB transport.
- `Dockerfile`: Bun, pnpm globals, CJK fonts, entrypoint.
- `entrypoint.sh`: stdin capture, exec bun.
