# Investigation: RPC catalog

## Question

What is the complete intent-shaped RPC surface the host exposes to trust-zone
containers? Every verb, its signature, its failure modes, its idempotency
guarantees — laid out concretely enough to write `src/rpc/*.ts` from.

Principle 4 of `design-principles.md` is the constraint: verbs, not queries.
If the only way to name an endpoint is `select_*` or `update_*(sql=…)`, it
doesn't go in this catalog.

## Constraints (recap, brief)

- Single host (Node), single SQLite + Honker, one Unix-domain socket.
- Two long-lived containers (`dm-trust`, `public-trust`); maybe a third later.
- Each container holds one **zone-tier RPC token**. Host validates
  `token → zone_id` on every call and rejects anything scoped to another
  zone.
- A second **operator-tier token** (held by `ncl` on the host, never inside
  a container) unlocks destructive admin verbs.
- Trust boundary is the socket. Inside a zone container, ambient access to
  whatever the zone provisioned is the rule (principle 2).
- Everything ephemeral lives in the container; everything durable goes
  through these verbs.

## Cross-cutting concerns

### Transport

- Unix domain socket at `/run/nanoclaw/rpc.sock` (host-only bind mount into
  each container at `/host/rpc.sock`, mode 0660, container UID matches).
- Framing: newline-delimited JSON (`\n` per message), one request per line,
  one response per line. Keeps debugging trivial (`socat - UNIX:rpc.sock`).
- Long-running calls (`ask_user_question`, `request_credential`) hold the
  connection open until completion or timeout — no polling shim required.
- A second framing mode is allowed for streaming pushes (host → container)
  on the same socket: server-initiated frames carry `{type: "push", …}`.
  See `04-idle-wake.md` for the wake/inject channel.

### Auth

- Each request envelope:
  ```ts
  type Envelope<T> = {
    v: 1;                       // protocol version
    id: string;                 // client-generated, used for response correlation
    token: string;              // zone-tier token, opaque, 32+ bytes base64
    verb: string;
    args: T;
    idem?: string;              // optional idempotency key (see per-verb notes)
  };
  ```
- Token → zone mapping is a single SQLite lookup, cached in-process by the
  host with a short TTL (30 s) so rotation propagates fast.
- Rotation: `ncl zones rotate-token --id dm-trust` issues a new token, stores
  it in the DB, restarts the container (env-injected). Old token is
  invalidated immediately.
- Operator-tier endpoints require a separate token (`NANOCLAW_OPERATOR_TOKEN`
  loaded from host `.env`, never exported into any container env). Same
  envelope, different validation table.

### Versioning

- The `v` field on the envelope is the protocol major. New verbs are
  additive at the same major; renames or breaking arg changes bump to `v: 2`.
- Host advertises supported versions via `describe()` (a verb available to
  any caller). Containers refuse to start if the host advertises a major they
  don't speak.
- Per-verb args evolve by adding optional fields only. Once a field is
  documented as required, removing it = new major.

### Rate limiting

- Per-zone token-bucket per endpoint family (work / messaging / scheduling /
  files / credentials / audit / discovery). Tunable via central DB row, not
  hardcoded. Defaults are generous (hundreds per minute for messaging, low
  for `request_credential`).
- Operator-tier endpoints are not rate-limited (only one human operator).

### Logging / audit

- Every non-`heartbeat`, non-`describe` RPC call writes one row to
  `rpc_log` (zone, verb, id, idem, args_hash, status, latency_ms).
- `emit_audit` calls are themselves audit events, plus they create domain
  audit rows — both layers retained.
- `heartbeat` and `describe` are rate-counted but not logged per call.

---

## Endpoints

### 1. Work management

#### `claim_work`
- **Inputs:** `{ max?: number; visibility_ms?: number }` — max claims per
  call (default 1), how long the container holds the lease (default 60_000).
- **Outputs:** `{ items: Array<{ work_id: string; lease_id: string;
  message: InboundMessage; context: { history_window: Message[];
  system_prompt: string; sender: CanonicalUser } }> }`
- **Auth:** any zone token; returns only work assigned to that zone.
- **Failure modes:** none beyond auth — empty list is a normal result.
- **Idempotency:** not idempotent (each call consumes work). Re-claiming
  the same `work_id` is impossible; the lease model in Honker covers
  crash-during-process.
- **Notes:** verb is plural-friendly. Container can claim N at once if it
  wants to batch.

#### `complete_work`
- **Inputs:** `{ work_id: string; lease_id: string; outcome?: "ok" | "noop";
  summary?: string }`
- **Outputs:** `{ ok: true }`
- **Auth:** zone that owns the lease.
- **Failure modes:** `lease_expired` (someone else now holds it),
  `not_found`, `wrong_zone`.
- **Idempotency:** safe — completing an already-completed work is a no-op.
- **Notes:** `summary` is durably attached to the work record for ops view.

#### `fail_work`
- **Inputs:** `{ work_id: string; lease_id: string; reason: string;
  retryable: boolean; backoff_ms?: number }`
- **Outputs:** `{ ok: true; will_retry: boolean }`
- **Auth:** lease owner.
- **Failure modes:** as `complete_work`.
- **Idempotency:** safe (additional failures after the first are recorded
  as duplicate notes but don't double-schedule retries).
- **Notes:** Honker visibility timeout already covers crashes; this is for
  *deliberate* failure with a reason.

#### `heartbeat`
- **Inputs:** `{ lease_ids?: string[] }`
- **Outputs:** `{ extended: string[]; expired: string[] }`
- **Auth:** zone token.
- **Failure modes:** none.
- **Idempotency:** trivially idempotent.
- **Notes:** unlogged. If `lease_ids` empty, just refreshes the zone's
  liveness without extending any leases.

---

### 2. Messaging out

#### `record_message`
- **Inputs:** `{ channel_id: string; content: string;
  thread_id?: string; in_reply_to?: string; files?: FileRef[];
  formatting?: "markdown" | "slack" | "plain" }`
- **Outputs:** `{ message_id: string; delivery_status: "queued" |
  "delivered" }`
- **Auth:** zone must have `channel_id` in its destination allow-list
  (resolved via `list_destinations`).
- **Failure modes:** `scope_violation` (channel not in zone's destinations),
  `unknown_channel`, `rate_limited`, `content_too_large`.
- **Idempotency:** caller supplies `idem` on the envelope. Same key in a
  10-minute window returns the original `message_id`.
- **Notes:** delivery is async; host's channel adapter does the actual send.
  `delivery_status: queued` is the common case.

#### `edit_message`
- **Inputs:** `{ message_id: string; content: string;
  formatting?: ... }`
- **Outputs:** `{ ok: true }`
- **Auth:** zone that authored the original message.
- **Failure modes:** `not_found`, `wrong_zone`, `channel_does_not_support_edit`
  (e.g. SMS), `too_old` (per-channel policy).
- **Idempotency:** same content → no-op.
- **Notes:** host adapter translates to the channel's edit primitive.

#### `add_reaction`
- **Inputs:** `{ message_id: string; emoji: string }` — `emoji` is the
  canonical name (`"+1"`, `"check"`), host maps per channel.
- **Outputs:** `{ ok: true }`
- **Auth:** zone with write access to the channel of `message_id`.
- **Failure modes:** `not_found`, `unsupported_channel`,
  `reaction_unknown`.
- **Idempotency:** safe (same reaction twice = once).

#### `delete_message`
- **Inputs:** `{ message_id: string; reason?: string }`
- **Outputs:** `{ ok: true }`
- **Auth:** zone that authored the message OR operator-tier.
- **Failure modes:** `not_found`, `wrong_zone`, `too_old`,
  `channel_does_not_support_delete`.
- **Idempotency:** safe.
- **Notes:** `reason` lands in the audit log.

---

### 3. Scheduling

#### `schedule_message`
- **Inputs:** `{ at: string /* ISO8601 */ | { cron: string; tz?: string };
  channel_id: string; content: string; thread_id?: string; files?: FileRef[];
  label?: string }`
- **Outputs:** `{ scheduled_id: string }`
- **Auth:** zone must own `channel_id` as a destination.
- **Failure modes:** `scope_violation`, `bad_schedule` (invalid cron / past
  time), `rate_limited`.
- **Idempotency:** `idem` deduplicates within a 1-hour window.
- **Notes:** Honker cron + queue does the work. `label` is for the operator
  view.

#### `cancel_scheduled`
- **Inputs:** `{ scheduled_id: string }`
- **Outputs:** `{ ok: true; was_pending: boolean }`
- **Auth:** zone that created it (or operator).
- **Failure modes:** `not_found`, `wrong_zone`.
- **Idempotency:** safe.

#### `list_scheduled`
- **Inputs:** `{ limit?: number; before?: string /* cursor */;
  label_prefix?: string }`
- **Outputs:** `{ items: ScheduledTask[]; next?: string }`
- **Auth:** zone-scoped automatically — only this zone's scheduled tasks.
- **Failure modes:** none beyond auth.
- **Idempotency:** trivially safe (read-only).
- **Notes:** intent-shaped because the output is "the things you scheduled",
  not "any row in the scheduled_tasks table".

---

### 4. Interactive

#### `ask_user_question`
- **Inputs:** `{ channel_id: string; question: string;
  thread_id?: string; choices?: string[]; timeout_ms?: number;
  context_hint?: string }`
- **Outputs:** `{ answered: true; answer: string; answered_by: CanonicalUser;
  at: string }` or `{ answered: false; reason: "timeout" | "channel_dead" }`
- **Auth:** zone with write access to channel.
- **Failure modes:** `timeout` (returned as `answered: false`),
  `scope_violation`, `rate_limited`.
- **Idempotency:** envelope `idem` deduplicates re-asks within a 1-minute
  window (returns the in-flight promise).
- **Notes:** long-running. Connection stays open. Host delivers the
  question via the normal channel adapter, then captures the next message in
  that thread from the original sender as the answer.

#### `wait_for_answer`
- **Inputs:** `{ question_id: string; timeout_ms?: number }`
- **Outputs:** same as `ask_user_question`'s answered variants.
- **Auth:** zone that asked the question.
- **Failure modes:** `not_found`, `wrong_zone`, `timeout`.
- **Idempotency:** safe (just waits).
- **Notes:** if the agent restarted mid-question (process cycle), it
  reattaches via this verb instead of re-asking. `question_id` is returned
  by `ask_user_question` even before answer arrives (as a separate field
  on the same connection, or via `describe_question`).

---

### 5. Files

#### `upload_file`
- **Inputs:** `{ filename: string; mime: string; size: number;
  bytes_b64: string }` — small files inline. For large files, two-phase:
  `upload_file_begin` → returns upload URL on a sibling socket, then
  `upload_file_complete`.
- **Outputs:** `{ file_id: string; sha256: string }`
- **Auth:** zone token; per-zone quota applies.
- **Failure modes:** `quota_exceeded`, `size_mismatch`, `bad_mime`.
- **Idempotency:** if `sha256` already exists for this zone, returns the
  existing `file_id` (content-addressed dedup).
- **Notes:** files live in `data/files/<sha256-prefix>/<sha256>`; rows in
  `files` table carry owner-zone and MIME.

#### `attach_file_to_message`
- **Inputs:** `{ message_id: string; file_id: string;
  display_name?: string }`
- **Outputs:** `{ ok: true }`
- **Auth:** zone that owns both objects.
- **Failure modes:** `not_found`, `wrong_zone`, `already_attached`.
- **Idempotency:** safe.

#### `get_file_metadata`
- **Inputs:** `{ file_id: string }`
- **Outputs:** `{ file_id: string; sha256: string; size: number;
  mime: string; created_at: string }`
- **Auth:** zone that uploaded it OR a zone the file was shared into via
  `attach_file_to_message` to a channel that zone owns.
- **Failure modes:** `not_found`, `scope_violation`.
- **Idempotency:** trivially safe.
- **Notes:** intentionally **no** `get_file_bytes`. Containers don't pull
  arbitrary blobs from the host — they receive bytes inline at the moment a
  message lands (`claim_work` payload), or they uploaded them in the first
  place.

---

### 6. Credentials

#### `request_credential`
- **Inputs:** `{ name: string; reason: string;
  duration_ms?: number /* default 5 minutes */ }`
- **Outputs:** `{ granted: true; secret_handle: string;
  expires_at: string } | { granted: false; reason: "denied" | "timeout" }`
- **Auth:** zone token; some credentials are zone-restricted by policy.
- **Failure modes:** `unknown_credential`, `policy_denied` (zone may never
  ask for this), `approval_timeout`, `rate_limited`.
- **Idempotency:** envelope `idem` collapses concurrent asks for the same
  `name` from the same zone within `duration_ms` of each other.
- **Notes:** out-of-band: host emits an approval prompt to the operator (DM
  via the `dm-trust`-owning channel). The returned `secret_handle` is an
  opaque token usable with HTTP shims that the host proxies — the raw
  secret never crosses the socket.

#### `list_available_credentials`
- **Inputs:** `{}`
- **Outputs:** `{ items: Array<{ name: string;
  requires_approval: boolean; description: string }> }`
- **Auth:** zone token. Returns only credentials this zone is *allowed* to
  request (the discovery is itself policy-shaped).
- **Failure modes:** none beyond auth.
- **Idempotency:** trivially safe.
- **Notes:** values are never returned. Names + metadata only. This is the
  "intent" version of "what auth do I have access to" — agents see options
  without ever seeing secrets.

---

### 7. Audit

#### `emit_audit`
- **Inputs:** `{ event_type: string; payload: object;
  severity?: "info" | "warn" | "alert"; ref?: string /* optional linkable id,
  e.g. message_id or work_id */ }`
- **Outputs:** `{ event_id: string }`
- **Auth:** zone token. `event_type` namespaced by zone (`dm-trust.deploy.began`).
- **Failure modes:** `event_type_invalid` (must match
  `[a-z][a-z0-9._-]{1,63}`), `payload_too_large` (16 KB cap),
  `rate_limited`.
- **Idempotency:** envelope `idem` collapses dupes within 1 minute.
- **Notes:** see `06-audit-events.md` for the taxonomy of events.

---

### 8. Sessions / context

#### `cycle_process`
- **Inputs:** `{ reason: string; preserve_pending_work?: boolean }`
- **Outputs:** `{ ok: true; cycle_id: string }`
- **Auth:** zone token (zone self-restart only).
- **Failure modes:** `cycle_in_progress`, `rate_limited` (cap at 1/minute).
- **Idempotency:** dedup via `idem`; same key within 30 s = single cycle.
- **Notes:** restarts the agent runtime inside the container without
  restarting Docker. See `05-process-cycle.md`. Open leases survive via
  Honker visibility timeout; new process re-claims on first
  `claim_work`.

#### `get_session_metadata`
- **Inputs:** `{}`
- **Outputs:** `{ zone_id: string; container_name: string;
  started_at: string; protocol_version: number;
  features: string[]; rate_limits: Record<string, { rpm: number }> }`
- **Auth:** zone token.
- **Failure modes:** none.
- **Idempotency:** trivially safe.
- **Notes:** called once at container start to discover what the host
  supports this run.

---

### 9. Discovery

#### `list_destinations`
- **Inputs:** `{}`
- **Outputs:** `{ items: Array<{ channel_id: string; display_name: string;
  capabilities: { send: boolean; edit: boolean; react: boolean;
  delete: boolean; files: boolean } }> }`
- **Auth:** zone token. Only this zone's permitted destinations.
- **Failure modes:** none.
- **Idempotency:** trivially safe.
- **Notes:** the discovery that lets the agent know *where* it can write.
  Capabilities are channel-adapter declared; `record_message` enforces.

#### `list_available_skills`
- **Inputs:** `{}`
- **Outputs:** `{ items: Array<{ name: string; description: string;
  required_tools: string[]; available: boolean; unavailable_reason?: string
  }> }`
- **Auth:** zone token. All skills in the registry are listed, with
  `available: false` and a reason for those the zone can't run.
- **Failure modes:** none.
- **Idempotency:** trivially safe.
- **Notes:** intent-shaped — the agent asks "what can I do here" not
  "select * from skills".

---

## Operator-tier (separate from zone-tier)

Operator endpoints are validated against `NANOCLAW_OPERATOR_TOKEN`, never a
zone token. Host rejects with `operator_required` if a zone token tries.

#### `restart_container`
- **Inputs:** `{ zone_id: string; reason: string }`
- **Outputs:** `{ ok: true; new_container_id: string }`
- **Auth:** operator.
- **Failure modes:** `unknown_zone`, `restart_in_progress`.
- **Idempotency:** safe — restarts that find no running container start one.

#### `redeploy_zone`
- **Inputs:** `{ zone_id: string; image_ref?: string;
  env_overlay?: Record<string, string> }`
- **Outputs:** `{ ok: true; image_used: string; container_id: string }`
- **Auth:** operator.
- **Failure modes:** `unknown_zone`, `image_not_found`, `provision_failed`.
- **Idempotency:** envelope `idem` collapses identical redeploys.
- **Notes:** end-to-end re-provisioning: rebuilds env, recreates container,
  rotates the RPC token.

#### `merge_users`
- **Inputs:** `{ winner: string; loser: string; reason: string }`
- **Outputs:** `{ ok: true; aliases_moved: number }`
- **Auth:** operator.
- **Failure modes:** `unknown_user`, `merge_would_orphan_zone_assignment`.
- **Idempotency:** safe — merging already-merged users is a no-op.
- **Notes:** the canonical action behind `03-identity-collapse.md`.

#### `rotate_zone_token`
- **Inputs:** `{ zone_id: string }`
- **Outputs:** `{ ok: true; new_token_distributed: boolean }`
- **Auth:** operator.
- **Failure modes:** `unknown_zone`.
- **Idempotency:** each call generates a new token; re-callable safely (old
  ones invalidate).

#### `inspect_zone_audit`
- **Inputs:** `{ zone_id: string; since?: string; until?: string;
  event_type_prefix?: string; limit?: number }`
- **Outputs:** `{ items: AuditEvent[]; next?: string }`
- **Auth:** operator.
- **Failure modes:** none beyond auth.
- **Notes:** read-only operator window into a zone's audit log. Containers
  can `emit_audit` but cannot read other zones' audit.

---

## Recommendation (next concrete step)

Write `src/rpc/schema.ts` first — the Zod (or equivalent) schemas for every
envelope and verb in this catalog. That's the executable form of this
document and the bridge between "RPC catalog" and code. Specifically:

1. One file per category (`work.ts`, `messaging.ts`, `scheduling.ts`,
   `interactive.ts`, `files.ts`, `credentials.ts`, `audit.ts`, `session.ts`,
   `discovery.ts`, `operator.ts`).
2. Each exports `{ verb_name: { input: ZodType; output: ZodType; auth:
   "zone" | "operator"; idempotency: ... } }`.
3. A central `src/rpc/router.ts` dispatches by `verb`, validates with the
   schema, validates auth, applies rate limit, logs, calls the handler.
4. Handlers live in `src/rpc/handlers/*` and only get pre-validated args +
   a resolved `zone_id` (or operator flag). They never see the raw
   envelope.

This makes the catalog the *spec*, the code the *implementation*, and the
test suite (one fuzz test per verb confirming "zone A can never act on
zone B's resources") the enforcement.

## Open sub-questions

- **Streaming push frames.** Mixing request/response with server-initiated
  push on one socket is doable but needs care. Worth a dedicated note —
  defer to `04-idle-wake.md`.
- **File quota policy.** Per-zone byte quotas need a sweep job to enforce
  retention; not designed here.
- **Approval delivery for `request_credential`.** Operator gets DMed, but
  what if the operator is the one making the request via the `dm-trust`
  zone? Probably auto-approve when `requester == operator`, but the policy
  needs writing down.
- **`cycle_process` semantics with in-flight `ask_user_question`.** The
  pending question survives in the DB; the new process must `wait_for_answer`
  to reattach. Diagram this in `05-process-cycle.md`.
- **Operator over the socket vs over a separate `ncl-socket`.** Currently
  same socket, different token. Easier ops; slightly larger blast radius if
  the socket file mode is misconfigured. Reconsider before writing code.
- **`describe()` as a per-call vs once-at-start.** Currently
  `get_session_metadata` covers start. A live `describe()` lets clients
  re-discover after a host upgrade without restart. Cheap; add if needed.
- **Per-verb cost accounting.** If rate limits get smarter ("LLM-cost-aware"),
  some verbs need a cost weight. Not for v1.
