# Investigation: container shim protocol

## Question

`container-shim.md` sketches the NDJSON protocol between host and
shim over `docker exec`. This investigation pins it down: every
message type, every field, every failure mode. The goal is a
versionable contract that the host can drive and the shim can
serve without surprise.

The protocol is a public surface (principle 9). Breaking it = major
version bump. Worth nailing.

## Constraints

- Bidirectional newline-delimited JSON over `docker exec -i`'s
  stdin/stdout.
- Stdin to shim = commands from host.
- Stdout from shim = events to host.
- Stderr from shim = raw human-readable logs (not parsed; goes to
  `docker logs` for debugging only).
- Every line is one JSON object with a `type` field.
- Forward and backward compat within a major version (host minor ≥
  shim minor is fine; shim ignores unknown command types; host
  ignores unknown event types — see `framework-versioning.md`).

## Commands (host → shim)

### `message`

The agent has a new message to process.

```ts
type MessageCommand = {
  type: "message";
  content: string;                 // user-visible content
  thread: string;                  // channel-native thread/conv id (opaque)
  channel: string;                 // channel-adapter id ("slack-dm", "dashboard", ...)
  sender: string;                  // canonical user id ("user:luis")
  attachments?: Attachment[];      // optional, see "Attachments"
  conversation_id?: string;        // optional harness session ID to resume
};
```

Shim behavior:
- Forwards `content` (and attachments + conversation_id if supplied)
  to harness stdin in the harness's expected format.
- For Claude Code with `--input-format stream-json`, that's a JSON
  envelope like `{"type":"user","message":{"role":"user","content":"..."}}`.
- For Codex / OpenCode, the format is whatever those binaries
  expect; shim has per-harness formatters.

Failure modes:
- Harness stdin closed (shouldn't happen during normal operation;
  if it does, shim emits `harness.crashed` and respawns).
- Malformed content (shim doesn't validate; harness handles).

### `cycle`

Restart the harness inside the container.

```ts
type CycleCommand = {
  type: "cycle";
  mode: "fresh" | "continue";       // fresh = clear projects/; continue = keep
  reason?: string;                  // for audit log; opaque to shim
};
```

Shim behavior:
- `mode: "fresh"`: SIGTERM harness, wait up to 10s, SIGKILL if
  still alive, recursively delete `/home/agent/.claude/projects/`,
  respawn.
- `mode: "continue"`: SIGTERM harness, wait up to 30s (let JSONL
  flush coherently), SIGKILL if still alive, respawn. Harness will
  re-read its `projects/` JSONL files on start.
- Emit `shim.ready` when respawned harness is ready.

Idempotency: if a cycle is already in progress, drop the new
cycle command (emit `cycle.duplicate`).

### `shutdown`

Stop the container cleanly.

```ts
type ShutdownCommand = {
  type: "shutdown";
  drain_ms?: number;                // default 10000
};
```

Shim behavior:
- Set shutdown flag.
- SIGTERM harness.
- Wait up to `drain_ms` for harness to exit.
- SIGKILL if still alive.
- Exit shim process with code 0.
- Container PID 1 (tini) sees its child exit; container exits.

After receiving `shutdown`, the shim ignores any further commands
on stdin. The host treats the exec stream as half-closed.

### Optional future commands (post-v1)

| Command | Purpose | When |
|---------|---------|------|
| `status` | Ping the shim for state | If the host wants on-demand status beyond the heartbeat |
| `interrupt` | Cancel the in-flight turn | If a user types `/stop` mid-response |
| `set_config` | Hot-reload harness config | If we want config changes without cycle |

All three are minor-version additions. Not v1.

## Events (shim → host)

### `shim.ready`

Emitted when shim starts and after every successful cycle. Signals
"harness is alive and accepting input."

```ts
type ShimReadyEvent = {
  type: "shim.ready";
  harness: "claude" | "codex" | "opencode";
  harness_pid: number;
  ts: number;                       // epoch ms, shim clock
};
```

Host doesn't write any `message` commands until it sees a
`shim.ready` for the current exec session.

### `harness.event`

Wraps one line of harness NDJSON stdout. The shim is a passthrough
for these — it doesn't parse or interpret the inner `event`.

```ts
type HarnessEvent = {
  type: "harness.event";
  event: unknown;                   // whatever the harness emitted; shape depends on harness
};
```

For Claude Code (stream-json output), the inner `event` is one of
Claude Code's documented event types: `text`, `tool_use`,
`tool_result`, `result`, etc. Host has per-harness parsers that
dispatch the inner `event` to channel adapters, audit, or other
handlers.

### `harness.stderr`

A line from harness stderr or a malformed stdout line.

```ts
type HarnessStderr = {
  type: "harness.stderr";
  line: string;
};
```

Host treats this as informational. Goes to audit as a
`harness.warning` event if it looks important; otherwise logged
only.

### `harness.exit`

Harness exited cleanly (or during a deliberate cycle).

```ts
type HarnessExit = {
  type: "harness.exit";
  code: number | null;
  signal: string | null;
};
```

During a `cycle`, this is followed by a `shim.ready` for the
respawned harness. Outside of cycle, the shim respawns on its own
and emits `shim.ready` shortly after.

### `harness.crashed`

Harness exited unexpectedly (non-zero exit, segfault, OOM).

```ts
type HarnessCrashed = {
  type: "harness.crashed";
  code: number | null;
  signal: string | null;
  last_stderr_tail?: string[];      // last ~10 stderr lines if available
};
```

Host emits an audit event (`anomaly`, severity `error`), increments
a crash counter for that agent, may issue a `cycle` if crashes
exceed a threshold.

### `heartbeat`

Periodic liveness signal.

```ts
type HeartbeatEvent = {
  type: "heartbeat";
  ts: number;
  harness_pid: number | null;       // null if harness is in respawn window
  uptime_ms: number;                // shim's own uptime
};
```

Default cadence: every 5 seconds. Host's watchdog expects
heartbeats; missing >2 in a row triggers a cycle.

### `cycle.duplicate`

Acknowledge that a cycle command arrived while a cycle was in
progress, and the new command was dropped.

```ts
type CycleDuplicateEvent = {
  type: "cycle.duplicate";
  ts: number;
};
```

Host treats this as informational. No retry; the operator can issue
another cycle after the in-progress one finishes.

## Attachments

If a message has file attachments (image, PDF), they need to reach
the harness somehow. Two options:

### Option A: shim provides via mounted volume

Host writes the file to a shared volume (`/srv/agent/data/inbox/<agent>/<id>`),
which is mounted into the container. Message command references the
container-path of the file:

```json
{
  "type": "message",
  "content": "describe this image",
  "attachments": [
    {"kind": "file", "path": "/agent-inbox/abc123.png", "mime": "image/png"}
  ]
}
```

Pros: no large blobs over `docker exec` stdin; supports big files.
Cons: requires a writable bind mount we wouldn't otherwise have.

### Option B: base64-encoded in the command

```json
{
  "type": "message",
  "attachments": [
    {"kind": "file", "name": "image.png", "mime": "image/png", "data_b64": "..."}
  ]
}
```

Pros: no shared volume needed.
Cons: a 5 MB image becomes ~7 MB base64 over a single stdin write;
`docker exec` pipes have buffering quirks; probably fine for small
files but degrades.

Recommendation: **Option A** with size limits. Files >1 MB use the
mounted volume; small files (e.g., short text snippets pasted by the
user) can be inline.

The shared volume is `/srv/agent/data/inbox/<agent>/`, mounted
read-only into the container at `/agent-inbox/`. Host writes, agent
reads. Host garbage-collects after the message is processed (audit
event `inbox.cleaned` confirms).

## Compatibility rules

Reading from `framework-versioning.md`:

- **Within a major version**, the protocol is additive. New event
  types are allowed; new command types are allowed. Old hosts
  ignore unknown events; old shims ignore unknown commands. Field
  additions to existing types are allowed.
- **Across major versions**, the protocol can rename or restructure
  types. Host major mismatch with shim major = refuse to start.
- **Per-event-type evolution**, fields can only be added (optional).
  Removing or renaming = major bump.

The `framework_version` check at `agent-host start` makes the
agent's pinned base image version visible to the host before any
exec — catches major skew up-front.

## Failure modes

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Shim crashes | `docker exec` stream closes; host sees EOF | Host issues `docker exec` again; container's tini may have already exited (if shim was PID 2 and crashed, container died). If container dead, host `docker run`s fresh. |
| Harness crashes | Shim emits `harness.crashed`; respawns automatically | Host logs anomaly; no operator action needed unless crashes are repeated. |
| Heartbeat stops | Host watchdog: no heartbeat in 15s | Host issues `cycle fresh`. If cycle doesn't restore heartbeats, host `docker kill && docker run`. |
| Host crashes mid-exec | Container keeps running; shim's stdout fills the OS pipe buffer until something reads | systemd restarts host; host on boot does `docker exec` again; shim resumes streaming (old buffered output gets flushed first). |
| Container OOM | Docker kills container; tini exits; container gone | Host's `docker run` retries; logs `anomaly` audit event. |
| Malformed line on stdin | Shim parses, fails, drops; ideally emits `cycle.duplicate`-style `parse.error` | Don't send malformed lines. |

## Performance characteristics

Per turn, rough breakdown of NDJSON volume:

- 1 inbound `message` command (~200 bytes).
- ~5-20 outbound `harness.event` events (varies by tool use).
- 1 final harness response event (varies by length, often a few KB).

Plus heartbeats every 5s (~80 bytes each).

Total: KB/turn, not MB. `docker exec` over a Unix-domain socket
handles this easily. Latency is dominated by harness inference, not
the NDJSON pipe.

## Open sub-questions

- **Maximum line length on stdin/stdout.** `docker exec` pipes have
  default 64KB buffers. Most messages fit. Large attachments use
  Option A mount instead of inline base64.
- **Reading the protocol version up-front.** Should `shim.ready`
  include a `protocol_version` field? Probably yes; lets the host
  detect "shim is a newer minor than I expected" without crashing.
- **Cancellation semantics.** If host writes a `message` and then a
  `cycle` arrives before the harness finished, the cycle kills the
  in-flight turn. Host needs to mark the response as cancelled in
  audit. Add a `result.cancelled` event from harness if it can
  detect signal; otherwise infer from `harness.exit` mid-turn.
- **Streaming partial output.** Claude Code with stream-json emits
  partial text events. Host should be able to render these
  progressively in the dashboard. Already supported by the
  `harness.event` passthrough; just need the dashboard to know to
  render incrementally.
- **Multi-turn batching.** If multiple `message` commands arrive
  while a turn is in progress, shim queues them in memory and feeds
  them as the harness becomes ready. Simple FIFO.
