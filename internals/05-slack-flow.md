# Slack Message Flow through NanoClaw v2

End-to-end trace from webhook POST to agent response in thread. Covers identity, routing, permission gates, session resolution, container wake, and delivery.

## 1. Slack Adapter Wiring

**File:** `/home/exedev/nanoclaw/src/channels/slack.ts`

The Slack adapter self-registers and uses the Chat SDK bridge pattern:

- **Registration:** `registerChannelAdapter('slack', { factory: ... })` at lines 16–82
- **Credentials:** Reads `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` from env at lines 18–22
- **Chat SDK Adapter:** Wraps `createSlackAdapter()` from `@chat-adapter/slack` (line 20)
- **Bridge Mode:** Uses `createChatSdkBridge()` with `supportsThreads: true` (lines 24–27)
- **Thread Rewriting:** `rewriteThreadId` hook at lines 36–45 patches DM thread IDs so top-level DM messages each get their own session (not collapsed into one shared thread)

**Webhook vs. Socket Mode Reality:**
- Slack is **webhook-based, not Socket Mode** (Chat SDK dispatches via Events API POSTs)
- The bridge registers on the shared webhook server (see `chat-sdk-bridge.ts:408`)
- Webhook endpoint: `/webhook/slack` (routed by `webhook-server.ts:88`)

## 2. Inbound Packets

**Files:**
- `/home/exedev/nanoclaw/src/webhook-server.ts:84–118` (HTTP server routes to adapter)
- `/home/exedev/nanoclaw/src/channels/chat-sdk-bridge.ts:286–311` (four dispatch paths)

**Slack Events API Shape:**
The Chat SDK's `@chat-adapter/slack` receives standard Slack Events API payloads. NanoClaw sees these projected through four Chat SDK dispatch paths:

1. **`onSubscribedMessage`** (line 270): message in a thread we previously engaged → `isMention` from platform, `isGroup=true`
2. **`onNewMention`** (line 277): bot explicitly mentioned in unsubscribed thread → `isMention=true`, `isGroup=true`
3. **`onDirectMessage`** (line 286): DM to bot → `isMention=true`, `isGroup=false`, thread ID rewritten (lines 36–45)
4. **`onNewMessage`** (line 308): plain message in unsubscribed channel (pattern match `/[\s\S]*/`) → `isMention=false`, `isGroup=true`, seeded with context

**Normalization:**
- Chat SDK serializes message to JSON (line 171)
- `messageToInbound()` (lines 164–234) projects nested `author` fields onto flat `senderId`/`sender`/`senderName` (lines 217–222)
- Attachments downloaded inline and base64-encoded (lines 187–190)
- Reply context extracted via platform hook if configured (lines 207–211)
- Raw message dropped to save DB space (line 225)
- Result: `InboundMessage` with `kind: 'chat-sdk'` (line 229)

**Thread Context Seeding:**
The bridge calls `fetchThreadContext()` (line 157) on first engagement (Slack-specific at `src/channels/slack.ts:51–70`). For thread replies, fetches up to 30 prior messages with `conversations.replies` and includes them as `threadContext` in the inbound JSON. Top-level thread roots (where `threadTs === message.id`) skip the fetch (lines 55–57).

## 3. Identity Resolution

**File:** `/home/exedev/nanoclaw/src/router.ts:158–252`

**User ID Format:**
- Chat SDK adapters (Slack included) pass raw platform IDs: `"U1234567890"` (Slack user ID) or `"C9876543210"` (Slack channel ID)
- The bridge's `messageToInbound()` extracts `author.userId` and stores as `senderId` in the inbound JSON (line 219)
- **Namespacing happens in the permissions module** (the `setSenderResolver` hook): transforms `"U1234567890"` → `"slack:U1234567890"` before upserting the `users` row

**Without the permissions module:**
- `userId` stays null and downstream code tolerates it (see `router.ts:252`)
- Messages are still routed but identity-dependent features (role checks, access gates) don't fire

## 4. Messaging-Group Lookup

**File:** `/home/exedev/nanoclaw/src/router.ts:176–206`

A single DB query fetches both the messaging group and wired agent count:

```
getMessagingGroupWithAgentCount(event.channelType, event.platformId)
```

Implemented in `/home/exedev/nanoclaw/src/db/messaging-groups.ts:53–69` as a LEFT JOIN with GROUP BY.

**On First Mention/DM:**
- No row exists yet
- Router auto-creates one (lines 185–196) with:
  - `channel_type: 'slack'`, `platform_id: "C1234567890"` (or DM platform ID)
  - `is_group: 1` (if channels) or `0` (if DM)
  - `unknown_sender_policy: 'request_approval'` (default)
  - `created_at: now`

**Platform ID encoding** (Slack-specific, determined by Chat SDK):
- Channel message: `slack:<channel_id>` or raw channel ID (adapter decides)
- DM: `slack:<user_id>` or a derived DM channel ID
- Thread ID: encoded separately by `adapter.channelIdFromThreadId()`

## 5. Router Decision

**File:** `/home/exedev/nanoclaw/src/router.ts:277–341`

**Fan-out logic:**
For each wired agent (`messaging_group_agents` row):

1. **Engagement evaluation** (lines 281–395): Does this agent engage?
   - `'pattern'` mode: regex test on message text
   - `'mention'` mode: requires platform mention (`isMention === true`)
   - `'mention-sticky'` mode: mention OR existing session for this (agent, mg, thread)

2. **Access gate** (line 283): Permissions module can reject with reason; recorded in `dropped_messages`

3. **Sender-scope gate** (line 284): Per-wiring `sender_scope` enforcement (if module installed)

4. **Decision branches:**
   - **Engages + gates pass:** call `deliverToAgent()` with `wake=true` (line 287)
   - **Doesn't engage but `ignored_message_policy='accumulate'`:** call `deliverToAgent()` with `wake=false` (line 318)
   - **All other cases:** drop silently or record reason

**Subscription (mention-sticky only):**
If the first engaging mention-sticky wiring fires on a threaded channel in a group chat (not DM), the router calls `adapter.subscribe()` once (lines 294–309). This tells Slack to forward all future messages in the thread via the subscribed path, so follow-ups don't require another mention.

## 6. Permission Gate

**File:** `/home/exedev/nanoclaw/src/router.ts:70–86`

The `setAccessGate()` hook is registered by the permissions module. When a message reaches an agent:

1. **Router calls:** `accessGate(event, userId, mg, agent.agent_group_id)`
2. **Gate returns:** `{ allowed: true }` or `{ allowed: false; reason: string }`
3. **On rejection:** message is dropped, `dropped_messages` row recorded by the gate itself
4. **Without module:** core defaults to allow-all

**Structural drops** (no agent wired, no match):
- Recorded by core at lines 221–229 or 332–340
- Reason: `'no_agent_wired'` or `'no_agent_engaged'`

## 7. Session Resolve + Container Wake

**Files:**
- `/home/exedev/nanoclaw/src/router.ts:397–485` (deliverToAgent)
- `/home/exedev/nanoclaw/src/session-manager.ts:92–143` (resolveSession)
- `/home/exedev/nanoclaw/src/container-runner.ts:85–106` (wakeContainer)

**Session Mode Calculation (router.ts:410–413):**
Threaded adapters (Slack) in group chats force `per-thread` mode regardless of wiring unless the agent is `agent-shared`:
```typescript
if (adapterSupportsThreads && effectiveSessionMode !== 'agent-shared' && mg.is_group !== 0) {
  effectiveSessionMode = 'per-thread';
}
```
DMs (where `mg.is_group === 0`) keep the agent's configured `session_mode` unchanged.

**Session Resolution (session-manager.ts:92–133):**
```
resolveSession(agentGroupId, messagingGroupId, threadId, sessionMode)
```
Returns existing session or creates new with ID `sess-<timestamp>-<random>`.

**Message Write (router.ts:450–459):**
Calls `writeSessionMessage()`, which:
1. Extracts base64 attachments from message JSON, saves to `session/inbox/<msgId>/`
2. Opens `inbound.db` (read-write)
3. Inserts into `messages_in` table with:
   - `trigger=1` if wake=true (engagement fired), `trigger=0` if accumulating
   - `channel_type`, `platform_id`, `thread_id` copied from delivery address
   - `content` is the full inbound JSON serialized as text
4. Closes DB immediately (critical for cross-mount visibility — see session-manager.ts:5–11)

**Container Wake (container-runner.ts:85–106):**
- Deduplicates concurrent wake calls via `wakePromises` map
- Spawns container process with session folder + agent group folder mounts
- Contract: never throws; returns `Promise<boolean>` (true = spawned, false = transient failure)
- Host-sweep retries on false

## 8. Inside the Container

**Files:**
- `/home/exedev/nanoclaw/container/agent-runner/src/poll-loop.ts:53–139` (main loop)
- `/home/exedev/nanoclaw/container/agent-runner/src/db/messages-in.ts:65–80` (fetch pending)
- `/home/exedev/nanoclaw/container/agent-runner/src/formatter.ts:1–40` (categorize/format)

**Poll Loop:**
1. **Fetch pending** (poll-loop.ts:73): `getPendingMessages()` reads from `inbound.db` (read-only)
   - Returns rows where `status='pending'` and `process_after` is due
   - Filters on `trigger=1` OR first-poll (lines 70, 95–98)
   - Limits to `MAX_MESSAGES_PER_PROMPT` (default 10, from container.json)

2. **Mark processing** (line 101): Writes `processing_ack` row to `outbound.db` so a crash doesn't re-process

3. **Categorize** (formatter.ts:35–56): Detects admin/filtered/passthrough commands
   - Chat-SDK IDs get namespaced: `{msg.channel_type}:{raw_id}` (lines 87–90)
   - Only `/clear` is handled by runner; others pass to agent

4. **Format messages** (poll-loop.ts ~150+): Serialize to XML or markdown with thread context

5. **Call provider** (provider.query): Push inbound XML to Claude, stream result

6. **Mark completed** (poll-loop.ts): Write `processing_ack` success

## 9. Outbound Delivery

**Files:**
- `/home/exedev/nanoclaw/src/delivery.ts:121–149` (host delivery loop)
- `/home/exedev/nanoclaw/container/agent-runner/src/db/messages-out.ts:45–77` (container writes)
- `/home/exedev/nanoclaw/src/channels/chat-sdk-bridge.ts:414–553` (deliver impl)

**Container Writes messages_out (messages-out.ts:45–77):**
- Auto-assigns odd `seq` number (1, 3, 5, ...)
- Includes `platform_id`, `channel_type`, `thread_id` from session routing
- Content is JSON with `text`, `markdown`, `type` (ask_question, card, etc.), optional `files`

**Host Delivery Poll (delivery.ts:121–149):**
Every ~1s, for running sessions:
1. Queries each session's `outbound.db` (read-only) for undelivered messages
2. Checks `delivered` table in `inbound.db` to skip already-sent
3. Calls `deliveryAdapter.deliver(channelType, platformId, threadId, kind, content, files)`

**Chat SDK Bridge deliver() (chat-sdk-bridge.ts:414–553):**
- Normal message: calls `adapter.postMessage(threadId, { markdown: text, files })`
- Ask-question card: builds Card with Buttons, `adapter.postMessage()`, stores render metadata
- Edit/reaction: `adapter.editMessage()` or `adapter.addReaction()`
- Text splitting: if `maxTextLength` set, splits on paragraph/line/char boundaries (lines 529–543)
- Result: platform message ID returned and stored in `delivered` table

**Marks delivered (delivery.ts):** Updates `inbound.db.delivered(message_id)` so the message doesn't re-send on next poll.

## 10. Thread Handling

**File:** `/home/exedev/nanoclaw/src/channels/slack.ts:28–45`

**DM Thread Rewriting:**
Top-level DM messages arrive from Slack with `thread_ts` empty. The Chat SDK adapter encodes this as a threadId with no threadTs, which causes the bridge to collapse all top-level DMs into one shared thread. The rewrite hook fixes this:

```typescript
rewriteThreadId: (threadId, message, { isDM }) => {
  if (!isDM) return threadId;  // channel threads unchanged
  const decoded = slackAdapter.decodeThreadId(threadId);
  if (decoded.threadTs) return threadId;  // already in-thread, no rewrite
  // Top-level DM: use message.id as thread_ts so each DM gets its own session
  return slackAdapter.encodeThreadId({ channel: decoded.channel, threadTs: message.id });
}
```

**Effect:** Each top-level DM gets a unique session. When the agent replies, the Chat SDK's `postMessage()` decodes the thread_ts from the threadId and Slack auto-creates a thread.

**In-thread replies:** Already have `thread_ts` set, so no rewrite needed. Reply lands naturally in the existing thread.

**mention-sticky mode:** For group channels, once a thread engages, `adapter.subscribe()` registers it so all future messages (mentions and non-mentions) route via `onSubscribedMessage` instead of `onNewMessage`, triggering the agent automatically on follow-ups.

## 11. Full End-to-End Sequence

15 numbered steps from webhook POST to Slack client sees reply:

1. **Slack POSTs Event** → `POST /webhook/slack` (webhook-server.ts:84)
   - Body: Slack Events API payload (challenge, event_type, user_id, text, etc.)

2. **Webhook Router** (webhook-server.ts:84–118)
   - Parses path, matches `/webhook/slack`
   - Converts Node.js IncomingMessage to Web API Request (lines 27–48)
   - Calls `chat.webhooks['slack'](request)`

3. **Chat SDK Dispatches** (depends on event type)
   - **Mention in unsubscribed thread:** `onNewMention()` → chat-sdk-bridge.ts:277–280
   - **DM:** `onDirectMessage()` → chat-sdk-bridge.ts:286–295
   - **Plain message:** `onNewMessage()` → chat-sdk-bridge.ts:308–311
   - **Subscribed thread:** `onSubscribedMessage()` → chat-sdk-bridge.ts:270–273

4. **Bridge Normalizes** (chat-sdk-bridge.ts:164–234)
   - Calls `messageToInbound()`, projects nested author to flat senderId/sender
   - Downloads attachments (fetchData) and base64-encodes
   - Calls `setupConfig.onInbound(channelId, threadId, inboundMessage)`

5. **onInbound Routed** (adapter setup callback points to host router)
   - channelId decoded by adapter → `channel_type: 'slack'`, `platform_id` (channel or DM ID)
   - Reaches `router.ts:158 routeInbound()`

6. **Router Intercepts** (router.ts:159–161)
   - Message interceptor hook fires (permissions module can consume)
   - If consumed, message is silently dropped; routing stops

7. **Thread Policy Applied** (router.ts:164–168)
   - Non-threaded adapters collapse `threadId = null`
   - Slack supports threads, so threadId preserved

8. **Messaging Group Lookup** (router.ts:176–206)
   - Single query: `getMessagingGroupWithAgentCount(channel_type, platform_id)`
   - No row + mention/DM: auto-create messaging_groups row
   - No row + plain chatter: return (drop, no agent engaged)

9. **Sender Resolution** (router.ts:252)
   - Calls `senderResolver()` hook (permissions module)
   - Returns `"slack:U1234567890"` or null
   - Upserts users row (permissions module side effect)

10. **Wired Agents Fetched** (router.ts:256)
    - `getMessagingGroupAgents(mg.id)` returns all messagingGroupAgent rows
    - Each row has: agent_group_id, engage_mode, ignored_message_policy, session_mode

11. **Fan-out Evaluation** (router.ts:277–329)
    - For each agent:
      - `evaluateEngage()` (lines 364–395): pattern/mention/mention-sticky test
      - `accessGate()` (line 283): permissions module approval
      - `senderScopeGate()` (line 284): per-wiring scope check
    - Engages? → `deliverToAgent(wake=true)` (line 287)
    - No engage + accumulate policy? → `deliverToAgent(wake=false)` (line 318)

12. **Session Resolve + Message Write** (router.ts:410–459)
    - Compute effective session mode (threaded → per-thread, DM → agent config)
    - `resolveSession(agentGroupId, messagingGroupId, threadId, mode)` (session-manager.ts:92–133)
      - Return existing or create new with ID `sess-<ts>-<rand>`
      - Create session folder + both DBs on first creation
    - `writeSessionMessage(agentGroupId, sessionId, message)` (session-manager.ts:193–250)
      - Extract base64 attachments, save to inbox/
      - Open inbound.db, insert into messages_in with trigger=1 (or 0 if accumulating)
      - Close DB (critical for host→container visibility)

13. **Container Wake** (router.ts:472–483)
    - `wakeContainer(session)` (container-runner.ts:85–106)
    - If already running or spawn in-flight, reuse promise
    - Spawn new process: `node agent-runner ... --session <sessionId>`
    - Container attaches to session folder, outbound.db mounts as writable

14. **Container Poll + Provider Call** (poll-loop.ts:53–)
    - Opens inbound.db (read-only), fetches messages_in rows where trigger=1
    - Marks processing_ack in outbound.db
    - Formats to XML, calls `provider.query()` with prompt + stream context
    - Writes result to messages_out (channel_type, platform_id, thread_id, content: JSON)

15. **Host Delivery Loop** (delivery.ts:121–149)
    - ~1s timer: fetch all running session outbound.db files
    - For each undelivered messages_out row:
      - Decode channel_type, platform_id, thread_id, content
      - Call `deliveryAdapter.deliver()` (chat-sdk-bridge.ts:414–553)
      - For normal message: `adapter.postMessage(threadId, { markdown: text })` (Chat SDK → Slack web API)
      - Slack POST `/chat.postMessage` with thread_ts → message appears in client
      - Store message ID in delivered table
    - ✅ Slack client receives reply in the thread where it was sent

---

## Key Implementation Details

**Two-DB Architecture (load-bearing invariants):**
- inbound.db: host writes, container reads (read-only)
- outbound.db: container writes, host reads (read-only)
- `journal_mode=DELETE` (not WAL) — WAL's mmapped -shm doesn't cross mount boundary
- Host closes DB after every write — invalidates container's page cache
- One writer per file — concurrent writes corrupt SQLite

**Message ID Namespacing (router.ts:493–496):**
When fanning out to multiple agents, same inbound message reused across sessions but ID must be unique per session. Scoped as `{baseId}:{agent_group_id}` to prevent collisions.

**Seq Numbering (messages-out.ts:45–77):**
- Container assigns odd seq (1, 3, 5, ...)
- Host assigns even seq (2, 4, 6, ...)
- Disjoint namespace is load-bearing: agent's `send_message` tool returns seq, which is looked up across both tables via `getMessageIdBySeq()`. If ranges overlapped, edit could target wrong message.

**Platform ID Encoding (channel-registry.ts + chat-sdk-bridge.ts):**
- Slack adapter encodes via `adapter.channelIdFromThreadId()` → `"slack:<channel_id>"` or DM channel
- Stored in messaging_groups.platform_id and delivery routing
- Container reads from session routing table, passes to delivery layer

**Thread Rewriting (slack.ts:36–45):**
Only applies to DMs. Top-level DMs (thread_ts empty) get rewritten so message.id becomes the thread_ts, giving each one its own session and causing Slack to auto-create a thread for the reply.
