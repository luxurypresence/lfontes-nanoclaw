# NanoClaw v2 Host Code Study

## 1. Boot Sequence

Ordered steps from process start to "ready" (src/index.ts:66-181):

1. **Circuit breaker** (line 70): Backoff on rapid restarts via `enforceStartupBackoff()`.
2. **Central DB init** (lines 73-75): Open v2.db, run migrations. WAL mode via pragma in connection.ts:17.
3. **Legacy backfill** (line 80): Scan `groups/*/container.json`, upsert missing rows into `container_configs`.
4. **Filesystem migration** (line 83): One-time cutover from `groups/global/CLAUDE.md` to per-group `CLAUDE.local.md`.
5. **Container runtime** (lines 86-87): Ensure Docker/container is reachable; kill orphaned containers from previous runs.
6. **Channel adapters** (lines 90-142): For each registered channel (Slack, Discord, etc.), instantiate the adapter. Wire `onInbound`, `onInboundEvent`, `onMetadata`, `onAction` callbacks into `routeInbound()` and `dispatchResponse()`.
7. **Delivery adapter bridge** (lines 144-166): Create a transport adapter that dispatches outbound messages to channel adapters.
8. **Start delivery polls** (lines 169-170): Launch two timer loops: active poll (1s for running sessions), sweep poll (60s for all active sessions).
9. **Start host sweep** (line 174): Launch 60s loop for stale detection, recurrence fanout, and inbox TTL pruning.
10. **CLI socket server** (line 178): Start `data/ncl.sock` listener for admin CLI commands.
11. **Graceful shutdown** (lines 184-205): Register SIGTERM/SIGINT handlers; reverse steps 8-10.

## 2. Inbound Path

Channel adapter → `routeInbound()` → session DB → container wake.

### Call chain with file:line refs:

1. **Adapter event arrives**: `router.ts:158` `routeInbound(event)`.
2. **Thread policy enforcement** (line 164-168): If adapter doesn't support threads, collapse `threadId` to null.
3. **Messaging group resolution** (line 176): `getMessagingGroupWithAgentCount()` queries both the group row and wired agent count in one read.
   - If not found and not a mention, silent return (plain chatter, no wake).
   - If not found but is mention, auto-create group (line 185-201).
4. **Agent wiring check** (line 210): If `agentCount === 0` and is mention, escalate via `channelRequestGate()` (permissions module) or drop as audit (line 221-246).
5. **Sender resolution** (line 252): Optional hook `senderResolver()` upserts the user row (permissions module).
6. **Agent fan-out** (line 256-329):
   - Fetch all wired agents via `getMessagingGroupAgents()`.
   - For each agent, evaluate `engage_mode` (pattern/mention/mention-sticky) via `evaluateEngage()` (line 364-395).
   - Check access gate: `accessGate(event, userId, mg, agentGroupId)` (line 283).
   - Check sender scope gate: `senderScopeGate(event, userId, mg, agent)` (line 284).
   - If engaged + gates pass: call `deliverToAgent()` with `wake=true`.
   - If engagement didn't fire and `ignored_message_policy='accumulate'`, call `deliverToAgent()` with `wake=false`.
   - Otherwise drop silently.
7. **Session resolution** (line 415): `resolveSession(agentGroupId, messagingGroupId, threadId, sessionMode)` returns existing session or creates new one (session-manager.ts:92-133). Session modes:
   - `'shared'`: one session per messaging group (ignores thread).
   - `'per-thread'`: one session per (agent, messaging group, thread).
   - `'agent-shared'`: one session per agent group across all messaging groups.
8. **Command gate** (line 431-447): Slash commands are classified before container wake; filtered commands drop silently, denied admin commands write denial directly to outbound.db.
9. **Write inbound message** (line 450-459): `writeSessionMessage()` (session-manager.ts:193-250):
   - Extract base64 attachments from content, stage to inbox/.
   - Open inbound.db, insert message with `trigger=1` (wake) or `0` (accumulate).
   - Close DB immediately (cross-mount visibility invariant).
10. **Wake container** (line 472-483): Call `wakeContainer(session)` if `wake=true`. Start typing indicator, return false on transient spawn failure (host-sweep retries).

### Key mechanisms:

- **Message dedup**: `messageIdForAgent()` (line 493-496) namespaces by agent_group_id to keep PKs unique across fan-out.
- **Wake flag**: `trigger` column gates `countDueMessages()` in sweep; host never wakes on `trigger=0` messages (context only).
- **On-wake messages**: `onWake=1` column marks rows to be skipped on container restart (second poll onward). Used by restart-with-message pattern (container-restart.ts:28-41).
- **Access gate audit**: Refusals write to `dropped_messages` table (line 332-340).

## 3. Outbound Path

Poll outbound.db → apply system actions → deliver via adapter.

### Dual-DB design (delivery.ts):

Container writes to `session/outbound.db` (read-write). Host polls it read-only, tracks delivery in `inbound.db`'s `delivered` table (host-owned, never touched by container).

### Active poll (lines 108-134):

1. Every 1s, call `getRunningSessions()` (fetch rows where `container_status='running'`).
2. For each session, call `deliverSessionMessages()` (line 151-162).
3. Guard against concurrent polls on the same session via `inflightDeliveries` set (line 50, 154-160).

### Sweep poll (lines 115-149):

1. Every 60s, call `getActiveSessions()` (fetch rows where `status='active'`).
2. For each, call `deliverSessionMessages()` (same function as active poll).

### Per-session drain (lines 164-232, `drainSession`):

1. Open outbound.db read-only, inbound.db read-write.
2. Query `getDueOutboundMessages(outDb)`: all rows in messages_out that have no `seq` or `seq <= max_delivered_seq`. (Ordering gates on message enqueue order, not delivery order.)
3. Filter against `delivered` table: skip already-delivered rows.
4. For each undelivered row, call `deliverMessage()` (line 234-375).

### System actions (lines 255-425):

If `msg.kind === 'system'`:
- Extract `content.action` string.
- Look up registered handler via `actionHandlers.get(action)` (line 418-421).
- If found, call handler with (content, session, inDb).
- Handler is responsible for side effects (e.g., approvals module schedules a message in inbound.db, scheduling module updates recurrence state).
- If not found, log warning and return (not an error — new modules may add actions this host doesn't know about yet).

### Agent-to-agent routing (lines 264-270):

If `msg.channel_type === 'agent'`:
- Guard via `hasTable(getDb(), 'agent_destinations')` (module optional).
- Call `routeAgentMessage(msg, session)` from agent-to-agent module.
- Sender must be authorized by `agent_destinations` row.

### Channel delivery (lines 273-374):

1. **Destination authorization** (line 290-310):
   - Resolve `messaging_group_id` from `(channel_type, platform_id)`.
   - If destination equals session's origin, always allow (line 294-295).
   - Else check `agent_destinations` table for explicit row (line 299-310).
   - Throw on unauthorized → falls into retry path → mark failed after MAX_DELIVERY_ATTEMPTS.

2. **Pending questions** (line 317-340):
   - If `content.type === 'ask_question'` and `pending_questions` table exists, persist the question row so response dispatcher can route replies.

3. **File attachments** (line 351-354):
   - Call `readOutboxFiles()` (session-manager.ts:478-530): scan outbox/<msgId>/ for declared files, validate against symlink/escape attacks, return buffers.

4. **Adapter delivery** (line 356-374):
   - Call `adapter.deliver(channelType, platformId, threadId, kind, content, files)`.
   - On success, call `markDelivered(inDb, msg.id, platformMsgId)` and `clearOutbox()` (session-manager.ts:538-562).
   - Typing indicator pause (line 203-204): only for non-system, non-agent messages so user sees response without gap.

### Failure handling (line 205-226):

- Increment `deliveryAttempts` counter.
- If < MAX_DELIVERY_ATTEMPTS (3), log warn and retry on next poll.
- If >= MAX_DELIVERY_ATTEMPTS, call `markDeliveryFailed()` and log error.

## 4. Container Lifecycle

### Spawn (container-runner.ts:108-190, `spawnContainer`):

1. **Routing setup** (line 122): Write default reply routing to inbound.db so container knows where to reply.
2. **Provider resolution** (line 132): Determine if session uses 'claude' or alternate provider; invoke provider-specific host setup (e.g., env injection).
3. **Mount construction** (line 134): Call `buildMounts()` (line 242-334):
   - Session folder → /workspace (RW).
   - Agent group folder → /workspace/agent (RW).
   - Nested RO mount of container.json.
   - Nested RO mount of composed CLAUDE.md.
   - Global memory → /workspace/global (RO).
   - Shared CLAUDE.md base → /app/CLAUDE.md (RO).
   - Per-group .claude state → /home/node/.claude (RW).
   - Agent-runner source → /app/src (RO).
   - Skills → /app/skills (RO).
   - Validated additional mounts from container.json.
   - Provider mounts.
4. **Container args** (line 139-147): Call `buildContainerArgs()` (line 411-477):
   - Basic docker run flags, labels.
   - Timezone env var.
   - Provider env vars.
   - **OneCLI gateway** (line 438-445): Call `onecli.ensureAgent()` to register, then `applyContainerConfig()` to inject HTTPS_PROXY and certs. Throws on transient failure (leave message pending, host-sweep retries).
   - Host gateway args (Linux only).
   - User mapping (preserve UID/GID if not root or node=1000).
   - Volume mounts.
   - Entrypoint: `bash -c 'exec bun run /app/src/index.ts'`.
   - Image tag (per-group custom image or base).
5. **Heartbeat cleanup** (line 155): Delete stale `.heartbeat` file so sweep's ceiling check knows it's fresh.
6. **Spawn** (line 157): Call `spawn(CONTAINER_RUNTIME_BIN, args)`. Add to `activeContainers` map keyed by session ID.
7. **Status** (line 160): Call `markContainerRunning()`.
8. **I/O** (line 163-170): Log stderr, ignore stdout.
9. **Exit handler** (line 177-189): On close or error, delete from `activeContainers`, call `markContainerStopped()`, stop typing indicator.

### Wake dedup (line 63, 85-106):

In-flight `wakePromises` map prevents concurrent spawns on the same session. Second `wakeContainer()` call mid-spawn joins existing promise, returns false on transient failure.

### Kill (line 193-207):

1. Look up entry in `activeContainers`.
2. Optionally set `onExit` callback to be fired when process closes.
3. Try to stop via `stopContainer()` (container-runtime.ts:29-34); fallback to SIGKILL.

### On-wake message + respawn (container-restart.ts:21-59, `restartAgentGroupContainers`):

1. For each active running session in the group:
2. Optionally write a message with `onWake=1` (picked up only on fresh container's first poll).
3. Kill container.
4. Register `onExit` callback to `wakeContainer()` the fresh session if wake message was provided.

## 5. Sweep Loop

Every 60s, process all active sessions (host-sweep.ts:144-157, `sweep`):

1. **Sync processing_ack → messages_in** (line 183): Call `syncProcessingAcks()` (session-db.ts:169-182).
   - Read completed/failed rows from outbound.db's processing_ack.
   - Update corresponding rows in inbound.db to 'completed'.
   - Allows host to detect when container has finished a message.

2. **Wake on due messages** (line 192-198):
   - Count pending messages with `trigger=1` and `process_after <= now`.
   - If count > 0 and container not running, wake it.
   - Host never wakes on trigger=0 (context-only) messages.

3. **SLA enforcement for running containers** (line 203-205):
   - Call `enforceRunningContainerSla()` (line 247-281).
   - Invoke `decideStuckAction()` (line 94-130, pure decision logic):
     - **Ceiling check** (line 111-117): If heartbeat file mtime > 30min (or declared bash timeout), kill container.
     - **Claim stuck check** (line 119-127): For each 'processing' claim, if claim age > 60s (or declared bash timeout) AND heartbeat mtime <= claim timestamp, kill container.
   - On kill, reset stuck messages with exponential backoff (section 4 below).

4. **Crashed container cleanup** (line 211-213):
   - If container not running and outbound.db exists, reset all 'processing' claims.
   - Respects existing retry scheduling (skips messages already scheduled for future retry).
   - Clears orphan processing_ack rows so fresh container can start clean.

5. **Recurrence fanout** (line 215-219):
   - Call `handleRecurrence()` from scheduling module (if installed).
   - Fan out completed recurring tasks into fresh messages_in rows.

6. **Inbox TTL prune** (line 223-226):
   - Call `pruneInboxOlderThan(agentGroupId, sessionId, 14 days)` (session-manager.ts:574-616).
   - Scan inbox/ dir, delete subdirs older than TTL.
   - Per-entry error handling so one bad dir doesn't abort sweep.

### Stuck message reset (host-sweep.ts:292-347, `resetStuckProcessingRows`):

- For each 'processing' claim in outbound.db:
  - Look up the message in inbound.db by id, status='pending'.
  - If already rescheduled (process_after > now), skip (don't bump tries again).
  - If tries >= MAX_TRIES (5), mark failed and log.
  - Otherwise, increment tries, set process_after = now + backoff (5s * 2^tries).
- Delete orphan processing_ack rows from outbound.db (optional writableOutDb param for testing).

## 6. Session Resolution

Function: `resolveSession(agentGroupId, messagingGroupId, threadId, sessionMode)` (session-manager.ts:92-133).

Maps (agent_group_id, messaging_group_id, thread_id) + sessionMode → session row + inbound/outbound DBs.

**Session modes**:
- `'shared'`: One session per messaging group. Lookup key: (agent_group_id, messaging_group_id, null).
- `'per-thread'`: One session per thread within a messaging group. Lookup key: (agent_group_id, messaging_group_id, threadId).
- `'agent-shared'`: Single session for the entire agent group across all messaging groups. Lookup key: agent_group_id only.

**Creation** (line 114-132):
- Generate session ID.
- Create row in central DB (`sessions` table).
- Call `initSessionFolder()` (line 136-143): Create directory, mkdir outbox/, apply both schemas to inbound.db and outbound.db.
- Use `journal_mode = DELETE` (not WAL) because WAL's mmapped -shm file doesn't refresh across host→container boundary; container would miss new messages (session-manager.ts header, line 1-11).

**Cross-mount invariants** (session-manager.ts:1-11):
1. journal_mode=DELETE (no mmapped state).
2. Host opens-writes-closes per operation (close invalidates container's page cache).
3. One writer per file (DELETE-mode journal isn't atomic across mounts).

Violation of these breaks message visibility between host and container.

## 7. Routing & Triggers

When a message arrives at a wired agent, `evaluateEngage()` (router.ts:364-395) decides if the agent should wake:

- **`'pattern'`**: Regex test on message text. Pattern `.` = always engage.
  - Bad regex → fail open (agent responds, admin sees the bad pattern and fixes it).
- **`'mention'`**: Engage only if `event.message.isMention === true` (platform-resolved, not NanoClaw display name).
- **`'mention-sticky'`**: Engage on mention OR if a session already exists for this (agent, messaging group, thread).
  - Reuses `findSessionForAgent()` to check prior engagement; if found, the thread is "subscribed" and follow-ups fire.

After evaluate, optional `adapter.subscribe(platformId, threadId)` (line 306-309) updates platform state (e.g., Slack watch thread) if the adapter supports it.

**Session mode override** (router.ts:410-413):
- If adapter supports threads, effective session mode is `'per-thread'` unless the wiring declares `'agent-shared'`.
- DMs always collapse threads (is_group=0 short-circuits).

## 8. Permissions & Access

### Access control hierarchy (modules/permissions/access.ts:21-28):

`canAccessAgentGroup(userId, agentGroupId)` checks:
1. Is user known? (exists in users table) → unknown_user.
2. Is user owner? (user_roles.role='owner') → owner (global).
3. Is user global admin? (user_roles.role='global_admin') → global_admin.
4. Is user admin of this group? (agent_group_members where role='admin') → admin_of_group.
5. Is user member of this group? (agent_group_members where role='member') → member.
6. Else → not_member.

### Inbound routing gates (router.ts:49-144):

1. **Sender resolver** (line 50-59): Permissions module registers hook to extract sender's namespaced user id (e.g., `slack:U1234`), upsert users row. Without module, userId is null.
2. **Access gate** (line 70-86): Permissions module registers hook that checks policy after agent resolution. Called per messaging group, not per agent. Returns `{allowed: true}` or `{allowed: false; reason}`. Refusals write to dropped_messages.
3. **Sender scope gate** (line 95-109): Per-wiring check for `sender_scope='known'` vs. `unknown_sender_policy`. Only runs if wiring is stricter than the messaging group default. Guards against accumulating untrusted messages.
4. **Channel request gate** (line 135-144): When a mention arrives at an unwired channel, escalate to owner via this hook (fire-and-forget). Permissions module handles the escalation card and schedules replay after approval.

### Approver picking (modules/approvals/primitive.ts:76-93, `pickApprover`):

Ordered list of user IDs eligible to approve an action:
1. Admins of the specific agent group.
2. Global admins.
3. Owners.

All duplicates removed while preserving order.

### Approval delivery (modules/approvals/primitive.ts:103-119, `pickApprovalDelivery`):

Walk approvers in order:
1. First pass: prefer approvers reachable on the same channel as the origin.
2. Second pass: take any reachable approver.
3. Return (userId, messagingGroup) or null if nobody reachable.

Calls `ensureUserDm()` (permissions module) which may open a new DM on the platform.

## 9. Approvals

Primitive API: `requestApproval(opts)` (modules/approvals/primitive.ts:164-220).

1. Pick approvers via `pickApprover()`, pick delivery via `pickApprovalDelivery()`.
2. If no reachable approver, notify agent and return.
3. Create pending_approvals row with:
   - approval_id (unique key).
   - action (e.g., 'install_package', 'cli_command').
   - payload (JSON, opaque).
   - title, question (card UI).
   - options_json (normalized button list).
4. Deliver card to approver's DM via `adapter.deliver()` with type='ask_question'.
5. Log approval requested.

When admin clicks button:
1. Response dispatcher invokes registered handler via `registerApprovalHandler(action, handler)` (line 59-64).
2. Handler receives (session, payload, userId, notify).
3. Handler is responsible for action (e.g., scheduling module writes the scheduled message to inbound.db).
4. Handler calls `notify(text)` to send chat message back to agent.

## 10. Admin CLI (ncl)

### Socket server (cli/socket-server.ts:20-46, `startCliServer`):

1. Listen on `data/ncl.sock` (exclusive, 0600 chmod).
2. Accept one frame per connection (JSON line).
3. Call `dispatch(req, {caller: 'host'})`.
4. Write response frame, close.

### Dispatch (cli/dispatch.ts:17-179, `dispatch`):

1. Look up command via `lookup(req.command)` from registry.
2. If not found, try trimming last dash-segment as fallback (e.g., `groups-get-abc123` → `groups-get` + id tail).
3. **CLI scope enforcement for agent callers** (line 42-101):
   - Check `container_configs.cli_scope` ('disabled', 'group', or 'global').
   - If 'disabled', reject.
   - If 'group', whitelist resources (groups, sessions, destinations, members), auto-fill agent_group_id, reject cross-group access, block cli_scope changes.
4. **Approval gating** (line 104-126):
   - If caller is 'agent' and cmd.access='approval', send approval card to admin instead of running inline.
   - Return approval-pending response.
5. **Parse and invoke** (line 128-179):
   - Call `cmd.parseArgs()` (type validation).
   - Call `cmd.handler()` (run the operation).
   - **Post-handler scope check** (line 150-172): For generic list/get handlers, filter rows by agent_group_id if caller is 'agent' in 'group' scope.

### Approval callback (cli/dispatch.ts:181-191):

Registered handler for 'cli_command' action:
1. Deserialize frame from approval payload.
2. Re-dispatch with `{caller: 'host'}` (bypasses approval, runs inline).
3. Notify agent with result.

## 11. Footguns & Invariants

**Message seq parity**: Host inserts with even seq (nextEvenSeq, session-db.ts:89-92); container inserts with odd. If violated, delivery ordering breaks. See scheduling module for replication (it also maintains this).

**Heartbeat cleanup on spawn** (container-runner.ts:155): Deleting stale file before spawn is critical. Without it, sweep's ceiling check sees old mtime and kills fresh container within seconds.

**on_wake flag** (session-db.ts:120-122, router.ts:223): If a message has `onWake=1`, it's only delivered on the container's first poll. If a container restarts mid-delivery, the message would be delivered twice (once to dying container, once to fresh). This prevents that by gating on first-poll-only.

**Cross-mount journal_mode** (session-manager.ts:5-11): WAL mode will silently freeze the container's view of inbound.db. Host writes appear to host, disappear from container. DELETE mode has unatomic journal-unlink across mounts but at least old pages do refresh.

**One-writer-per-file** (session-manager.ts:1-11): Host-writes-close pattern is essential. Concurrent writers corrupt DELETE-mode DBs. Container must never write to inbound.db; host must never write to outbound.db.

**Orphan cleanup before fresh wake** (host-sweep.ts:206-213): Sweep step 2 (wake on due messages) must run before step 4 (reset orphan claims). Otherwise, fresh container starts, tries to clear orphan processing_ack, sweep's next tick re-reads the old claim, decides fresh container is stuck, kills it.

**Access gate audit** (router.ts:231-245): Refusals from the access gate are security decisions (untrusted sender). Even if `ignored_message_policy='accumulate'`, silently storing their message is exactly what the gate prevents (and staging attachments to disk via writeSessionMessage creates a DoS vector).

**Agent-destination auth** (delivery.ts:273-310): Without an explicit agent_destinations row, agents can't reply to wired channels (except their origin chat). This is a permission boundary. Throwing on unauthorized falls into retry path correctly (marks message failed after retries).

**Typing indicator pause** (delivery.ts:202-204): Only pause after delivering real user-facing messages, not system actions or agent-to-agent traffic. Otherwise, user sees a gap in typing indicator between the agent's response and internal messages.

**OneCLI gateway required** (container-runner.ts:441-444): Refusing to spawn if gateway can't be applied prevents a container from running without credential injection. Transient failure throws, leaving message pending for host-sweep retry.

**Provider contribution threading** (container-runner.ts:130-132, 225-240): Provider is resolved once and threaded through buildMounts and buildContainerArgs so filesystem side effects (mkdir, env setup) fire once, not per-call.

