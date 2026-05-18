# Container shim

A ~150-LOC framework-owned program that runs as PID 2 (after tini)
inside every agent container. Its job: spawn and supervise the
harness subprocess, proxy I/O over `docker exec` to the host,
handle lifecycle commands (cycle, shutdown), and emit heartbeats.

The shim is *the* piece of framework code that lives inside
containers. Everything else framework-side lives on the VM in the
host process.

## PID tree inside a container

```
PID 1: tini                                  (zombie reaper, signal forwarder)
 └─ PID 2: agent-container (the shim)       (Bun, ~150 LOC, framework-owned)
      └─ harness subprocess: claude         (or codex, or opencode)
```

tini is PID 1 because that's its sole purpose and it does it well.
The shim is its child. The harness is the shim's child. Signals from
`docker stop` reach tini → forwarded to the shim → forwarded to the
harness, in that order.

## What the shim does

Tight scope:

1. Parse args (`--harness <kind>`).
2. Spawn the harness subprocess with the right command line + env.
3. Read NDJSON commands from its own stdin (which is the host's
   `docker exec` write side).
4. Translate commands to harness actions: write message content to
   harness stdin, kill on `cycle`, exit on `shutdown`.
5. Pipe harness stdout to its own stdout (which is the host's
   `docker exec` read side), wrapping each line in a typed envelope.
6. Emit a heartbeat every 5 seconds.
7. Respawn the harness if it crashes (unless shutting down).

Out of scope (deliberately):

- Any SQLite, queue, or persistent state.
- Any HTTP server, RPC server, Unix socket.
- Any logic about which messages go where (host decides).
- Any cron / scheduler (host owns it).
- Any credential negotiation (env is injected at container spawn).

If a feature can be done by the host instead, it goes in the host.
The shim is the smallest possible thing inside the container.

## Protocol on `docker exec`

The host invokes the shim via:

```bash
docker exec -i agent-personal-dm /usr/local/bin/agent-container --harness claude
```

Stdin and stdout of that exec session are the bidirectional channel
between host and shim. Both directions speak NDJSON — one JSON
object per line, newline-terminated.

### Host → shim (stdin to the shim)

```json
{"type":"message","content":"hello, do X","thread":"slack:T0LP:C123:1234.5678","channel":"slack-dm","sender":"user:luis"}
{"type":"cycle","mode":"fresh"}
{"type":"shutdown"}
```

- **`message`** — content for the harness. Shim formats and writes
  to harness stdin (the format depends on harness; for Claude Code
  with `--input-format stream-json` it's a JSON envelope).
- **`cycle`** — kill harness, optionally clear projects/, respawn.
  `mode: "fresh"` clears the session JSONLs; `mode: "continue"`
  keeps them and the new harness resumes.
- **`shutdown`** — kill harness, exit cleanly. Container then exits
  (PID 2 dies → tini exits → container exits).

### Shim → host (stdout from the shim)

```json
{"type":"shim.ready","harness":"claude","ts":1700000000}
{"type":"harness.event","event":{"type":"text","text":"working on it"}}
{"type":"harness.event","event":{"type":"tool_use","tool":"bash","input":"ls"}}
{"type":"harness.stderr","line":"warning: ..."}
{"type":"heartbeat","ts":1700000005,"harness_pid":42}
{"type":"harness.exit","code":0,"signal":null}
{"type":"harness.crashed","code":1,"signal":"SIGSEGV"}
```

- **`shim.ready`** — emitted once at startup after harness spawn.
- **`harness.event`** — wraps a single line of harness NDJSON output.
- **`harness.stderr`** — wraps a line of harness stderr.
- **`heartbeat`** — every 5 seconds. Host's watchdog uses this to
  detect wedged shims.
- **`harness.exit`** — normal exit. Shim respawns unless shutting
  down.
- **`harness.crashed`** — abnormal exit. Shim respawns with backoff.

Everything is one-line JSON. Easy to parse, easy to inspect by hand
(`docker exec -i agent-personal-dm /usr/local/bin/agent-container`
and type commands).

## Shim implementation sketch

```ts
// container/shim/src/index.ts
// Run by base image's ENTRYPOINT: /usr/local/bin/agent-container --harness claude

import { spawn, type Subprocess } from "bun";

type Args = { harness: "claude" | "codex" | "opencode" };
const args: Args = parseArgs(Bun.argv);

let harness: Subprocess | null = null;
let cycling = false;
let shuttingDown = false;

function harnessCommand(kind: Args["harness"]): string[] {
  switch (kind) {
    case "claude":   return ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json"];
    case "codex":    return ["codex", "..."];
    case "opencode": return ["opencode", "..."];
  }
}

function emit(obj: object) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function spawnHarness() {
  harness = spawn({
    cmd: harnessCommand(args.harness),
    cwd: "/workspace",
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    onExit(_, code, signal) {
      if (shuttingDown) return;
      if (cycling) {
        emit({ type: "harness.exit", code, signal });
        return;  // cycle() respawns
      }
      emit({ type: "harness.crashed", code, signal });
      setTimeout(spawnHarness, 1000);  // 1s backoff
    },
  });

  // Pipe harness stdout (NDJSON) to host, wrapping each line.
  pipeLines(harness.stdout, (line) => {
    try {
      const event = JSON.parse(line);
      emit({ type: "harness.event", event });
    } catch {
      emit({ type: "harness.stderr", line });  // not actually stderr, but malformed
    }
  });
  pipeLines(harness.stderr, (line) => emit({ type: "harness.stderr", line }));

  emit({ type: "shim.ready", harness: args.harness, ts: Date.now() });
}

async function cycle(mode: "fresh" | "continue") {
  if (cycling) return;
  cycling = true;
  try {
    if (mode === "fresh") {
      await Bun.file("/home/agent/.claude/projects").rmRecursive?.();
      // (or: rm via fs.promises.rm; depends on Bun version)
    }
    harness?.kill("SIGTERM");
    const exited = await Promise.race([
      harness?.exited,
      new Promise(r => setTimeout(() => r("timeout"), 10_000)),
    ]);
    if (exited === "timeout") harness?.kill("SIGKILL");
  } finally {
    cycling = false;
    spawnHarness();
  }
}

// Read NDJSON commands from stdin (the docker exec write side).
for await (const line of readLines(process.stdin)) {
  let cmd;
  try { cmd = JSON.parse(line); } catch { continue; }
  switch (cmd.type) {
    case "message":
      harness?.stdin?.write(formatForHarness(args.harness, cmd) + "\n");
      break;
    case "cycle":
      await cycle(cmd.mode ?? "fresh");
      break;
    case "shutdown":
      shuttingDown = true;
      harness?.kill("SIGTERM");
      process.exit(0);
  }
}

// Heartbeat every 5s.
setInterval(() => emit({ type: "heartbeat", ts: Date.now(), harness_pid: harness?.pid }), 5000);

// Signal forwarding: SIGTERM from tini → graceful shutdown.
process.on("SIGTERM", () => {
  shuttingDown = true;
  harness?.kill("SIGTERM");
  setTimeout(() => process.exit(0), 5_000);
});

spawnHarness();
```

That's the whole shim. ~120 lines including imports and helpers.

## Why Bun

The container is small (~50MB base + Bun ~50MB + harness binary).
Bun's startup is fast, its TypeScript support is native (no
transpile step in the container build), and its subprocess API is
ergonomic. The shim could be written in Go for an even smaller
image, but TypeScript keeps it consistent with the host code style
and lets the shim share types with the host (via published types
in the npm package).

The host uses Node + pnpm because that's what npm packages run on.
The container uses Bun because the shim is bundled into the base
image (no node_modules at runtime). Different runtimes, same
language.

## How the host talks to a specific agent

The host maintains, per agent:
- A `docker exec` subprocess attached to that agent's container.
- A readable stream of NDJSON output (the shim's stdout).
- A writable stream for NDJSON commands (the shim's stdin).

When a Slack message arrives for `personal-dm`:

```ts
host.containers["personal-dm"].stdin.write(JSON.stringify({
  type: "message",
  content: msg.text,
  thread: msg.thread_id,
  channel: "slack-dm",
  sender: msg.user_id,
}) + "\n");
```

The shim picks it up, writes to harness stdin, the harness processes,
emits events on its stdout, shim wraps them, host reads them on the
exec session's stdout, host's NDJSON parser dispatches to the right
handler (text response → send via Slack adapter; tool_use → audit
event; etc.).

There's exactly one `docker exec` per agent, alive for the life of
the container.

## Lifecycle

| Event | What happens |
|-------|--------------|
| Host start | For each agent: `docker run` (if not running) + `docker exec` the shim. Read `shim.ready` event, mark agent live. |
| Inbound message | Host writes `{type:"message",...}` to the shim's stdin. |
| Outbound text | Shim emits `{type:"harness.event",event:{type:"text",...}}`. Host's NDJSON parser sees a text event, dispatches to the right channel adapter. |
| `/cycle` from operator | Host writes `{type:"cycle",mode:"fresh"}` to shim's stdin. Shim kills harness, clears `projects/`, respawns. Emits new `shim.ready`. |
| Harness crash | Shim emits `harness.crashed`, respawns with 1s backoff. Host logs it as an audit event. |
| Host restart | exec session closes. Container keeps running. Host on restart: `docker exec` again, the shim is still up. Resume. |
| Container kill (`docker kill`) | tini gets SIGKILL, container dies. Host on next check finds it down, `docker run`s a fresh container. |
| Watchdog missed heartbeat | Host hasn't seen `heartbeat` in 30s. Host issues `agent-host cycle <name>` automatically. |

## What about resource limits

`docker run` flags handle this — `--memory`, `--cpus`. Read from
`agent.config.toml`'s `[container]` block. The shim doesn't enforce
limits itself; Docker does.

## Why not just spawn the harness directly without a shim

Tried this in v2-flat. Two reasons it didn't work:

1. **`docker exec` without a shim means the harness is PID 2** —
   you can't introduce a cycle command, a heartbeat, or
   crash-respawn logic without a wrapper.
2. **Lifecycle separation.** The host wants to send "cycle" without
   killing the container. With a shim, "cycle" is a command. Without
   a shim, "cycle" is `docker kill && docker run` which is much
   heavier (mount re-attach, env re-injection, ~1s startup vs.
   100ms harness respawn).

The ~150 LOC of shim earns its place against principle 10. Not
arbitrary code growth; specific functionality.

## Open sub-questions

- **Heartbeat cadence.** 5s is a guess. Trade-off: faster = more
  liveness signal, more chatter; slower = less chatter, more time
  to notice a hang. Reasonable bounds 5-30s. Settle once we measure.
- **What if the harness produces non-JSON stdout?** Wrap in
  `harness.stderr` (badly named — really "harness.unrecognized") and
  pass through. The host's parser ignores it for behavior but logs
  it. Some harnesses may not be NDJSON-clean; this is a graceful
  fallback.
- **stream-json input format**: Claude Code's input format for
  streaming. We need a tiny formatter per harness in the shim. ~10
  LOC per harness.
- **Bun version pin.** Base image pins Bun version. Bumping Bun is a
  base image rebuild — release-train concern.
- **MCP server processes.** If the harness spawns MCP servers (it
  does), they're grandchildren of the shim. tini reaps them on exit.
  Should Just Work; verify.
