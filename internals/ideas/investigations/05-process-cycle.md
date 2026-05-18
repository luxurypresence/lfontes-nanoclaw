# Investigation: process cycle inside container

## Question

Principle 1 says one container per trust zone, long-lived. `trust-zones.md`
lists "cycle context: restart the agent runtime *inside* the container
without restarting Docker" as a lifecycle state. What does that actually
mean mechanically?

The proposition: when the user wants a fresh conversation, kill and respawn
the agent-runner *process* inside the container. The container keeps
running — credentials stay injected, mounts stay attached, OneCLI proxy
stays reachable, the local SQLite stays open — but the in-memory agent
state (Claude Agent SDK in-process loop, transcript buffers, MCP server
child processes, any module-level singletons) is wiped.

To validate that, three things have to be true:

1. The Claude Agent SDK can in fact be killed and re-spawned without
   wedging state on disk that prevents a fresh start.
2. There's a clean PID 1 / supervisor pattern that can do the kill-respawn
   on RPC command without itself dying.
3. There's a sensible answer for "what if a query is mid-flight when the
   cycle is requested."

This note works through all three.

## Claude Agent SDK behavior (research findings)

**Where session state lives.** The SDK persists every session as a
JSONL file at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`,
where `<encoded-cwd>` is the absolute working directory with every
non-alphanumeric character replaced by `-` (so `/workspace` becomes
`-workspace`).
[Sessions docs](https://code.claude.com/docs/en/agent-sdk/sessions).

**What's in the JSONL.** "Your prompt, every tool call the agent made,
every tool result, and every response."
[Sessions docs](https://code.claude.com/docs/en/agent-sdk/sessions).
Conversation history only — not filesystem state, not MCP server state,
not in-flight `tool_use` blocks that haven't been answered yet.

**Resume by ID.** A new process can resume a session given only the
session ID, provided two preconditions:

- The JSONL file exists on the local disk at the encoded-cwd path.
- The new process is launched with the same `cwd` as the original (otherwise
  the SDK looks in the wrong project directory and silently starts a fresh
  session). [Sessions docs](https://code.claude.com/docs/en/agent-sdk/sessions).

Inside one container both are stable — `/workspace` doesn't move, and the
`~/.claude/projects/` tree is on the container's own filesystem, not a
host mount.

**Mid-flight tool calls and unclean kill.** This is the rough edge. If
the previous process was SIGKILL'd (or even SIGTERM'd without time to
flush) while a `tool_use` block was open and unanswered, resume can fail
with `No conversation found with session ID: <id>` even though the
`.jsonl` file is on disk. The JSONL is appended as the loop progresses;
the resume logic appears to require the transcript to be in a coherent
state (every `tool_use` paired with a `tool_result`), and an interrupted
loop can leave it half-written.
[claude-code#12730](https://github.com/anthropics/claude-code/issues/12730).

The community-reported workaround is "use graceful shutdown, give the
process time to flush" — which lines up with what we want for `/cycle`
anyway: SIGTERM first, wait for clean exit, only SIGKILL on hang.

**Orphan subprocesses.** The TypeScript SDK historically did *not*
auto-terminate the spawned `claude` CLI child if the parent process died
unexpectedly, leading to orphans accumulating in long-running hosts.
[claude-agent-sdk-typescript#142](https://github.com/anthropics/claude-agent-sdk-typescript/issues/142).
Inside our container this is largely solved for free by running PID 1 as
an init that reaps orphans, but it's a reminder that an unclean cycle
can leave subprocesses behind that PID 1 has to mop up.

**Practical consequence for cycle semantics.** Two cycle modes drop out
of the SDK's behavior:

- **Continue cycle.** Kill the agent-runner. Restart it. New process
  passes `resume: <previous-session-id>` (or `continue: true`). Same
  conversation, but every in-memory singleton (MCP child processes,
  module-level caches, SDK internals) is fresh. Useful when the runtime
  itself is misbehaving but the conversation is still wanted.
- **Fresh cycle.** Kill the agent-runner. Clear the saved session ID
  (in our local SQLite). Restart. New process starts a brand-new session.
  This is what `/clear` in NanoClaw effectively does today (handled
  inline via `poll-loop.ts` command handling); under the trust-zone
  model it becomes a supervisor-mediated restart instead.

For the cycle-on-fresh-context use case in `design-principles.md`, the
**fresh cycle** is the primary mode. Continue cycle is a useful escape
hatch for "process is wedged but I want my conversation back."

## Supervisor design (PID 1 strategy)

Container needs a PID 1 that can:

1. Spawn the agent-runner as a child.
2. Reap zombie subprocesses (the agent runtime fork-execs MCP servers,
   the `gh` CLI, `agent-browser`, etc.).
3. Forward signals from `docker stop` cleanly so the container shuts
   down properly when the host wants it to.
4. Accept an RPC command from the host saying "cycle the child" and
   respond by killing and respawning the agent-runner, **without itself
   exiting**.

That last requirement rules out the obvious "just use tini" answer. Tini
is strictly single-shot: it spawns one child and exits when the child
exits.
[Tini README](https://github.com/krallin/tini/blob/master/README.md).
Same for dumb-init —
[dumb-init README](https://github.com/Yelp/dumb-init).
Both are correct choices for "agent runtime is the only thing in the
container," but they don't fit the cycle model.

Options considered:

| Option | Fit | Why / why not |
|---|---|---|
| tini / dumb-init alone | No | Single-shot. Child exit = container exit. No respawn primitive. |
| systemd-in-container | No | Massive overkill. Hard to debug. Distros disagree on whether this even works. |
| s6-overlay | Maybe | Real supervisor with restart-on-exit, container-aware health propagation. Per [the s6-overlay README](https://github.com/just-containers/s6-overlay) it's designed exactly for this case. But ~10MB of scripts and DSL, and we have one child to supervise. |
| Custom Bun supervisor (PID 1) | **Yes** | We're already running Bun in the container. A ~50-line `supervisor.ts` that spawns the agent-runner, listens on a Unix socket for `cycle` RPC, and exits cleanly on SIGTERM. Zero new runtime deps. |
| tini wrapping a Bun supervisor | **Yes (preferred)** | tini stays PID 1 (zombie reaping, signal forwarding from `docker stop`). Bun supervisor runs as tini's child, owns the agent-runner as *its* child, listens for cycle RPC. Best of both. |

Going with **tini → bun supervisor → agent-runner** because:

- Reuses the same PID 1 strategy the current NanoClaw container has
  (`Dockerfile:167` already does `tini -- entrypoint.sh`), so the
  zombie-reap / signal-forward path is unchanged and well-understood.
- The supervisor layer is plain TypeScript/Bun, easy to read and test.
- The agent-runner stays unaware of cycling — it's just a normal process
  that gets started, killed, and restarted by its parent. No new SDK
  abuse, no clever in-process reset hooks.

Supervisor pseudocode:

```ts
// container/supervisor/src/index.ts
// Run as: tini -- bun run /app/supervisor/src/index.ts
// PID 1: tini. PID 2: this supervisor. Spawned child: agent-runner.

import { spawn } from "bun";
import { unlinkSync } from "fs";
import { serve } from "bun";

const SOCK = "/tmp/supervisor.sock";
let child: ReturnType<typeof spawn> | null = null;
let cycling = false;

function spawnAgent() {
  child = spawn({
    cmd: ["bun", "run", "/app/src/index.ts"],
    cwd: "/workspace",
    stdio: ["inherit", "inherit", "inherit"],
    onExit(_, exitCode, signalCode) {
      console.log(`[supervisor] agent exited code=${exitCode} sig=${signalCode}`);
      // Auto-respawn unless we're shutting the whole container down.
      if (!shuttingDown) spawnAgent();
    },
  });
}

async function cycle(mode: "continue" | "fresh") {
  if (cycling) return { ok: false, error: "already cycling" };
  cycling = true;
  try {
    if (mode === "fresh") {
      // Clear saved session ID so the new agent starts a brand-new
      // SDK session. Stored in the container's local SQLite.
      clearSavedSessionId();
    }
    child?.kill("SIGTERM");
    const exited = await waitForExit(child, 10_000);
    if (!exited) child?.kill("SIGKILL");
    // onExit handler respawns automatically.
    return { ok: true };
  } finally {
    cycling = false;
  }
}

// Tiny RPC: Unix socket, JSON lines. Host can also send via
// the supervisor's well-known socket path mounted into the container
// or via an HTTP loopback — protocol detail, not core to this design.
serve({
  unix: SOCK,
  async fetch(req) {
    const { command, mode } = await req.json();
    if (command === "cycle") return Response.json(await cycle(mode ?? "fresh"));
    if (command === "status") return Response.json({ pid: child?.pid, cycling });
    return Response.json({ ok: false, error: "unknown command" }, { status: 400 });
  },
});

let shuttingDown = false;
process.on("SIGTERM", () => {
  shuttingDown = true;
  child?.kill("SIGTERM");
  setTimeout(() => process.exit(0), 5_000);
});

spawnAgent();
```

Important: the supervisor's RPC is **trust-zone-internal** — host calls
in, agent never calls out. The agent-runner doesn't get a "cycle me"
tool. Cycling is a host-driven operator action; from inside the
container's trust model it's no different from `docker restart`.

## In-flight handling

Three behaviors to choose from when a `/cycle` arrives during an active
agent query:

| Behavior | UX | Cost |
|---|---|---|
| Refuse: "agent is busy, try again in N seconds" | Predictable, no data loss | Operator has to retry. Annoying for a wedged process. |
| Queue: wait for current turn, then cycle | Clean | Could take minutes if the agent is on a long tool chain. Defeats the use case of "agent is stuck and I want it reset." |
| Force-kill: SIGTERM with short grace, then SIGKILL | Most useful for "stuck process" | User loses the partial response. Possible JSONL corruption → resume failure. |

Choosing **force-kill with a short grace period, mode-aware**:

- `/cycle fresh` (the common case): SIGTERM, wait 10s, SIGKILL. Partial
  response is lost. JSONL state doesn't matter because we're starting a
  new session anyway. This is the "/clear because I'm stuck" mode.
- `/cycle continue` (rare): SIGTERM, wait *30s* to give the SDK time to
  flush the JSONL coherently, then SIGKILL. Warn the operator that
  resume may fail and the conversation may need to be re-prompted.
- `/cycle status` returns whether a query is currently active, so the
  caller can choose to queue manually if they care about a clean cut.

This matches the failure mode from
[claude-code#12730](https://github.com/anthropics/claude-code/issues/12730):
unclean kill plus resume = "No conversation found." Fresh cycle avoids
the whole class of bugs because resume isn't attempted.

## State preservation

By construction, the **container's filesystem** survives a process
cycle. That means:

- **OneCLI proxy config + injected credentials** — survive (container
  env + proxy is wired at container start, not process start).
- **Mounts** — survive (`/workspace`, `/home/node/.claude/`, etc.).
- **Local SQLite for session memory** — survives. Anything the agent
  persisted across turns (notes, scratch state, the saved session ID
  itself if we're doing `continue` mode) is on disk in the container's
  own FS.
- **The Claude Agent SDK JSONL transcript at
  `~/.claude/projects/-workspace/<id>.jsonl`** — survives. Useful for
  `continue` mode; ignored for `fresh` mode.
- **Open file descriptors, in-memory caches, MCP server child
  processes, module-level singletons in agent-runner.ts** — all gone.
  This is the *point* of cycling. Anything we cared about should have
  been written to disk before this moment.

In-memory state that matters: **nothing**, as long as the agent-runner
loads from disk fresh on every start. That's already true in NanoClaw
today (`config.ts` reads `container.json` at boot, `destinations.ts`
queries the DB live every batch, the session continuation ID is
persisted to `session_state` after every `init` event). The trust-zone
agent-runner should keep the same discipline: **no in-memory state that
doesn't trace back to disk.** If a future change adds a long-lived cache
that survives turns, that cache becomes a cycle-correctness risk.

## When is a cycle triggered

Three plausible triggers, listed from most-likely-needed to least:

1. **Operator `/cycle` (a.k.a. `/clear`) command.** User-typed slash
   command in any channel where the agent is wired. Router catches it
   *before* it goes to the agent-runner, sends a `cycle` RPC to the
   supervisor, replies "conversation reset" in-channel. NanoClaw already
   handles `/clear` inline in the poll loop; the trust-zone model moves
   that handling up to the host/supervisor seam.

2. **Stuck-process recovery from the operator side.** If the host's
   heartbeat watcher (`/workspace/.heartbeat` mtime, same pattern as
   NanoClaw today) detects a hung agent-runner, host issues a cycle.
   This is the "container is alive but the runtime is wedged" case —
   the alternative being a full `docker restart`, which is much more
   expensive (mounts re-attach, credentials re-inject, OneCLI proxy
   reconnect). Cycle is the cheap recovery path.

3. **Idle/long-gap auto-cycle.** Conversation boundary detection: after
   N hours of silence, the next inbound message implicitly starts a
   fresh session. Cheap to implement (router checks gap, conditionally
   issues `cycle fresh` before delivering the message). Saves token
   spend on stale context being carried forward forever. Probably worth
   doing but not on the critical path.

Not a trigger: **per-channel session boundary**. Trust zones are
container-per-zone, not container-per-conversation. Different
conversations *don't* get their own cycle automatically; if conversation
isolation matters, that's a separate concern handled by how the
agent-runner buckets messages, not by the supervisor.

## Recommendation

1. PID 1 = tini (unchanged from NanoClaw today).
2. tini's child = a small Bun supervisor at `container/supervisor/src/index.ts`,
   ~50 lines.
3. Supervisor spawns the agent-runner as its child; on agent exit,
   auto-respawn unless the container is shutting down.
4. Supervisor listens on a Unix socket (`/tmp/supervisor.sock`) for
   `cycle {mode: "fresh" | "continue"}` and `status` RPC.
5. Two cycle modes: `fresh` (clear saved session ID, then SIGTERM/grace/
   SIGKILL the child) and `continue` (longer grace to let SDK flush the
   JSONL, then resume by ID on respawn).
6. In-flight handling: force-kill with mode-dependent grace. `/cycle
   status` exposes "query active" so callers can choose to wait.
7. Triggers: operator `/cycle` (primary), heartbeat-driven recovery
   (host-side), optional idle auto-cycle (cheap addition).

This is structurally tiny — one new ~50-line file, one new RPC verb on
the host side, no changes to the agent-runner itself, no SDK gymnastics.
It earns its place against principle 7 (minimal moving parts).

## Open sub-questions

- **Cycle from agent-side?** Should the agent itself be able to request
  a cycle via an MCP tool (e.g., self-detected wedge, "I think my
  context is corrupted")? Leaning no: cycle is an operator-driven
  trust-zone-external action, and self-initiated cycle is hard to
  distinguish from a misbehaving agent trying to escape an
  unfavorable context. Revisit if a concrete use case shows up.
- **What happens to in-flight outbound messages on cycle?** The
  agent-runner writes to outbound.db; the host polls and delivers. If
  the agent had unsent messages buffered in memory at the moment of
  SIGTERM, those are lost. Fix: enforce write-on-emit (already the
  pattern today). Verify there's no in-memory output queue that
  buffers across the agent→DB boundary.
- **Supervisor crash recovery.** What happens if the supervisor itself
  crashes? tini sees its only child exit and the container exits — same
  as today. Fine, but means a supervisor bug is a container restart.
  Worth keeping the supervisor *boring*: no MCP, no DB connections, no
  network beyond the local Unix socket.
- **Multi-agent in one trust-zone container?** Out of scope here, but
  if a zone ever runs N agent-runners (e.g., one per active
  conversation within the zone), the supervisor needs a process table
  not a single-child model. The pseudocode above is the simple case.
- **Cycle observability.** Each cycle should emit an audit event to the
  host (`emit_audit` per principle 4). Belongs in the supervisor's RPC
  handler, not the agent-runner.
- **Does `continue` mode actually buy anything?** Given that fresh
  cycle is the dominant case and continue mode is fragile (depends on
  JSONL coherence), maybe just ship `fresh`. Continue can be added
  later if a real use case emerges. Default Yes-fresh-only until proven
  otherwise.
