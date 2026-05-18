# Investigation: audit event schema

## Question

What structured audit events should containers emit to the host via the
`emit_audit` RPC verb? What's the storage schema, retention policy, and
discipline rule for "is this worth an event"?

This is the host's primary window into containers. Bytes (session
transcript, scratch state) stay local to the container; **meaning**
(this happened, that decision was made, this credential was used)
goes central. Get this right and 90% of janitor/inspection/forensics
is one SQL query away.

## Constraints (recap, brief)

- One host SQLite, single-writer (principle 5, queue-based-rewrite.md §"Source-of-truth ranking").
- Containers reach the host only via RPC; `emit_audit` is one verb.
- Trust zones, not sessions, are the unit of capability. Every event
  must carry `zone_id` so we can ask "what did dm-trust do today?".
- Personal scale: one human, ~10s–100s of events per active hour,
  ~10k–100k per active month. Storage is not a scarcity problem.
- Discipline matters more than schema: NanoClaw-style "log every state
  change" would drown the signal. We log decisions and boundaries.

## Event taxonomy (TypeScript discriminated union)

```ts
// All events share this envelope. `kind` is the discriminator.
type AuditEventBase = {
  zone_id: string;          // 'dm-trust' | 'public-trust' | ...
  emitted_at: string;       // ISO-8601, set by container at emit time
  // Host adds: id, received_at, source_container
};

// 1. Conversation boundary
type SessionStart = AuditEventBase & {
  kind: 'session.start';
  thread_id: string;             // channel-native thread/conv id
  channel_id: string;
  sender_id: string;             // canonical user id, e.g. 'user:luis'
  trigger: 'message' | 'schedule' | 'wake';
};

type SessionEnd = AuditEventBase & {
  kind: 'session.end';
  thread_id: string;
  reason: 'idle_timeout' | 'explicit_close' | 'container_cycle' | 'error';
  turn_count: number;
  duration_ms: number;
};

// 2. Process / runtime lifecycle (rare, important)
type ContainerStart = AuditEventBase & {
  kind: 'container.start';
  image_digest: string;
  agent_runtime_version: string;
};
type ContainerStop = AuditEventBase & {
  kind: 'container.stop';
  reason: 'shutdown' | 'crash' | 'operator' | 'oom';
  exit_code?: number;
};
type ProcessCycle = AuditEventBase & {
  kind: 'process.cycle';      // fresh agent runtime, container stayed up
  reason: 'context_full' | 'operator' | 'periodic';
};

// 3. Messages — boundaries only, NOT every token
type MessageIn = AuditEventBase & {
  kind: 'message.in';
  thread_id: string;
  channel_id: string;
  sender_id: string;
  byte_len: number;             // content bytes — not the content itself
  attachment_count: number;
};
type MessageOut = AuditEventBase & {
  kind: 'message.out';
  thread_id: string;
  channel_id: string;
  byte_len: number;
  latency_ms: number;           // claim_work → record_message
  model: string;                // 'claude-opus-4-7'
  input_tokens: number;
  output_tokens: number;
};

// 4. Tool use — three states. Failures are first-class.
type ToolAttempt = AuditEventBase & {
  kind: 'tool.attempt';
  thread_id: string;
  tool_name: string;             // 'bash' | 'gh' | 'vercel.deploy' | ...
  arg_summary: string;           // short hand-rolled summary, NOT raw args
};
type ToolComplete = AuditEventBase & {
  kind: 'tool.complete';
  thread_id: string;
  tool_name: string;
  duration_ms: number;
  exit_code?: number;
};
type ToolFail = AuditEventBase & {
  kind: 'tool.fail';
  thread_id: string;
  tool_name: string;
  error_class: string;           // 'timeout' | 'permission' | 'network' | 'tool_error'
  message: string;               // human-readable, capped at ~500 chars
};

// 5. Credentials — every request, every response. Audit's bread and butter.
type CredentialRequest = AuditEventBase & {
  kind: 'credential.request';
  thread_id: string;
  credential_name: string;       // 'github-pat-rw' | 'slack-bot-token'
  reason: string;                // short reason from the agent
};
type CredentialResponse = AuditEventBase & {
  kind: 'credential.response';
  thread_id: string;
  credential_name: string;
  outcome: 'granted' | 'denied' | 'auto_present';
  decided_by?: string;           // user id if human approval; null if policy
};

// 6. Skills — when a skill enters the prompt for a turn
type SkillLoaded = AuditEventBase & {
  kind: 'skill.loaded';
  thread_id: string;
  skill_name: string;
  reason: 'router_match' | 'agent_invoke' | 'always_on';
};

// 7. Anomalies — the runtime caught something unexpected
type Anomaly = AuditEventBase & {
  kind: 'anomaly';
  thread_id?: string;            // optional — some anomalies are out-of-band
  severity: 'warn' | 'error';
  category: string;              // 'rpc' | 'sdk' | 'tool' | 'state' | 'policy'
  summary: string;                // one-line
  detail?: Record<string, unknown>;  // free-form, goes into payload_json
};

export type AuditEvent =
  | SessionStart | SessionEnd
  | ContainerStart | ContainerStop | ProcessCycle
  | MessageIn | MessageOut
  | ToolAttempt | ToolComplete | ToolFail
  | CredentialRequest | CredentialResponse
  | SkillLoaded
  | Anomaly;
```

**Queryable-as-column vs buried in `payload_json`:** anything used to
slice the log by humans gets a column. Everything else is JSON.

Promoted to columns: `zone_id`, `kind` (a.k.a. `event_type`), `thread_id`,
`channel_id`, `sender_id`, `tool_name`, `credential_name`, `created_at`.
Everything else (byte_len, latency, error_class, severity, raw detail
blob, model, token counts, etc.) lives in `payload_json`. We can promote
later via migration if a query gets common.

## Schema (SQL DDL)

```sql
CREATE TABLE audit_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  zone_id         TEXT NOT NULL REFERENCES trust_zones(id),
  event_type      TEXT NOT NULL,        -- maps to AuditEvent['kind']
  thread_id       TEXT,                 -- nullable: container.* events
  channel_id      TEXT,                 -- nullable
  sender_id       TEXT,                 -- canonical user id; nullable
  tool_name       TEXT,                 -- nullable except for tool.*
  credential_name TEXT,                 -- nullable except for credential.*
  payload_json    TEXT NOT NULL DEFAULT '{}',
  emitted_at      TEXT NOT NULL,        -- ISO-8601 from container
  created_at      TEXT NOT NULL DEFAULT (datetime('now'))
                                        -- host-side receipt time
);

-- Coverage notes:
--   * (zone, time) — "what did this zone do recently"
--   * (event_type, time) — "show me all anomalies / tool fails"
--   * (sender_id, time) — "what did Luis do yesterday"
--   * (thread_id) — full trace of one conversation
--   * (credential_name, time) — credential usage timeline
CREATE INDEX idx_audit_zone_time      ON audit_events(zone_id, created_at DESC);
CREATE INDEX idx_audit_type_time      ON audit_events(event_type, created_at DESC);
CREATE INDEX idx_audit_sender_time    ON audit_events(sender_id, created_at DESC)
  WHERE sender_id IS NOT NULL;
CREATE INDEX idx_audit_thread         ON audit_events(thread_id)
  WHERE thread_id IS NOT NULL;
CREATE INDEX idx_audit_credential     ON audit_events(credential_name, created_at DESC)
  WHERE credential_name IS NOT NULL;
```

Partial indexes keep the index small — most rows don't have a
`sender_id` or `credential_name`.

## Common queries (SQL examples)

```sql
-- "Show me everything Clanq did for me yesterday."
SELECT created_at, event_type, thread_id, tool_name,
       json_extract(payload_json, '$.summary') AS summary
FROM audit_events
WHERE sender_id = 'user:luis'
  AND created_at >= date('now', '-1 day')
  AND created_at <  date('now')
ORDER BY created_at;

-- "What tool calls failed last week and why?"
SELECT created_at, zone_id, tool_name,
       json_extract(payload_json, '$.error_class') AS error_class,
       json_extract(payload_json, '$.message')     AS message
FROM audit_events
WHERE event_type = 'tool.fail'
  AND created_at >= date('now', '-7 days')
ORDER BY created_at DESC;

-- "Who requested write access in the last 30 days?"
-- (write-credential request = credential.request whose name ends in '-rw'
--  or matches a known write set; here we use a name prefix convention.)
SELECT a.created_at, a.sender_id, a.credential_name,
       json_extract(a.payload_json, '$.reason') AS reason,
       r.event_type AS response,
       json_extract(r.payload_json, '$.outcome') AS outcome
FROM audit_events a
LEFT JOIN audit_events r
  ON r.event_type = 'credential.response'
 AND r.thread_id = a.thread_id
 AND r.credential_name = a.credential_name
 AND r.created_at >= a.created_at
WHERE a.event_type = 'credential.request'
  AND a.credential_name LIKE '%-rw'
  AND a.created_at >= date('now', '-30 days')
ORDER BY a.created_at DESC;

-- "Show all anomalies."
SELECT created_at, zone_id, thread_id,
       json_extract(payload_json, '$.severity') AS severity,
       json_extract(payload_json, '$.category') AS category,
       json_extract(payload_json, '$.summary')  AS summary
FROM audit_events
WHERE event_type = 'anomaly'
ORDER BY created_at DESC
LIMIT 200;

-- Full trace of one conversation, in order.
SELECT created_at, event_type, tool_name, credential_name, payload_json
FROM audit_events
WHERE thread_id = ?
ORDER BY created_at;

-- Daily summary, per zone.
SELECT date(created_at) AS day, zone_id, event_type, COUNT(*) AS n
FROM audit_events
WHERE created_at >= date('now', '-14 days')
GROUP BY day, zone_id, event_type
ORDER BY day DESC, zone_id, n DESC;
```

## Retention policy

**Default: keep forever.** Rows are small (~200–500 bytes), volume is
human-scale (~10k–100k/month), SQLite handles tens of millions of rows
without breaking a sweat. Backups are `cp data.db data.db.bak`. The
operational simplicity of "audit is permanent" is worth the disk.

Trade-off: at 1M rows / ~500MB the DB starts feeling heavy in casual
`ncl` queries, and SQLite's single-writer model means audit writes
contend with everything else. That's the inflection where pruning earns
its place — probably a year or two of single-user use.

**Pruning, when it earns its place:**

1. **Operator command, never automatic at first.**
   `ncl audit prune --before 2025-01-01 [--keep credentials,anomalies]`.
   The `--keep` flag preserves event types that retain forensic value
   indefinitely (credential events, anomalies, session boundaries).
2. **Soft TTL via a cron-driven sweep** *only if* operator pruning
   becomes a chore — `DELETE FROM audit_events WHERE created_at < ? AND event_type NOT IN ('credential.request', 'credential.response', 'anomaly', 'session.start', 'session.end')`.
   Default TTL: 18 months. Configurable. Off by default.
3. **Size cap** is a worse axis than time — it makes "show me last
   year" stop working unpredictably. Don't.

Don't build pruning until the DB hits ~250MB or queries get noticeably
slow. That's deferred work, not Day 1 work.

## Discipline rules

The whole point of central audit is **signal**. Things that are NOT
events:

- Every Claude SDK heartbeat or token-stream chunk.
- Every successful poll of the queue (use a counter or a periodic
  rollup if you ever need it).
- Internal state transitions inside the agent runtime that have no
  external consequence ("entered formatter step", "loaded skill index").
- Routine RPC calls that already implicitly log via their corresponding
  event (e.g., don't emit `rpc.call` for a `record_message`; the
  `message.out` event *is* the record).
- Every keystroke / every line of bash output. If the agent runs a
  100-line build, that's **one** `tool.attempt` + one `tool.complete`,
  not 100 events.
- Per-token cost accounting. Roll it up into `message.out`.
- Skill text content, message content, tool args. Audit is metadata;
  bytes stay in the container. If we need the content, we pull it
  out-of-band (read the container's local SQLite, or the channel
  history). Privacy and storage both push the same way.

The bar: **an event is worth recording if a human investigating
something next year would want to see it.** "Tool failed" qualifies.
"Tool succeeded after a 4-character internal state change" doesn't.

## Recommendation

Ship the taxonomy above. Build the table with the five columns
promoted out of `payload_json` (zone, type, thread, channel, sender,
plus tool/credential nameables), and the five indexes. Wire
`emit_audit` as one RPC verb; the container's MCP tool surface gets a
thin helper per event type so the call sites read like
`audit.toolFail({ ... })` rather than `emit_audit('tool.fail', ...)`.
Don't build pruning. Don't build a UI — `ncl audit query` over these
queries is enough for years.

The discriminated union is the contract. Anything else the container
wants to emit goes through `anomaly` until it earns its own kind.

## Open sub-questions

- **Schema enforcement on the host.** Validate incoming `emit_audit`
  payloads with Zod? Or trust the container (since trust-zone trust is
  already binary)? Lean toward Zod — cheap, catches typos, makes the
  schema the single source of truth.
- **Multi-emit transactionality.** A turn produces ~5–20 events. Batch
  them in one RPC call (`emit_audits([...])`) to cut RPC overhead, or
  one at a time for simplicity? Probably batch, with a flush-on-turn-end
  contract.
- **Clock skew between container and host.** `emitted_at` (container)
  vs `created_at` (host). Trust host time for ordering, keep
  `emitted_at` for diagnostics. Don't try to reconcile.
- **Search.** SQLite FTS5 over `payload_json` summaries? Worth it once
  the corpus is large enough to benefit. Deferred.
- **Cross-zone forensic queries.** When asking "what touched this
  thread_id" across zones (rare but real), the existing `(thread_id)`
  index handles it. No special design needed.
- **Anomaly noise budget.** What's the cap before anomalies become
  background hum? Soft target: <5/day in steady state. If consistently
  above, the category should be promoted to its own `kind` (with a
  proper handler) or downgraded out of the audit log entirely.
