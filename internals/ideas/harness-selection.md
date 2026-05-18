# Harness selection

The decision and the reasoning. v1 ships with **Pi only**, with a
**subprocess-CLI** provider abstraction designed so `claude -p` (headless
Claude Code) can slot in later as a second harness — and so can any
future CLI-shaped harness without architectural change.

## The decision

| | v1 | Future (post-v1, in priority order) |
|--|----|--------------------------------------|
| **Default harness** | Pi | — |
| **Alternative harnesses** | none | Claude Code headless (`claude -p`), then any other subprocess-CLI harness on demand |

Per-zone harness selection lives in the central DB. Reusing NanoClaw's
pattern: a `harness: 'pi' | 'claude-headless' | …` column on the trust
zone (or wherever the runtime config lives — see
`investigations/08-trust-zone-provisioning.md`).

## Why Pi at v1

1. **Model-agnostic compounds.** Anthropic's May 2026 split-billing
   (autonomous credit pool separate from interactive subscription) means
   "use my Claude subscription to power my agent" no longer carries the
   simplicity it used to. Pi against any backend — Anthropic API, OpenAI,
   OpenRouter, Ollama, local models — lets the operator choose based on
   cost, latency, and capability without changing the harness.
2. **Format proximity to Claude Code.** Pi's `settings.json`,
   `mcp.json`, skill conventions are close enough to Claude Code's that
   the `import-claude-code` flow is a translation pass, not a rewrite.
   See `migration-from-claude-code.md`.
3. **Pi is the lower-level engine.** OpenClaw is built on top of Pi
   ([Armin Ronacher's article confirms it](https://lucumr.pocoo.org/2026/1/31/pi/)).
   Pi itself doesn't inherit OpenClaw's threat model — it's a clean,
   minimal coding-agent foundation. We're picking the same low-level
   layer OpenClaw used, with our own trust-zone model on top instead of
   OpenClaw's broken one.
4. **One mental model.** Shipping with one harness means one set of
   operational concerns, one set of docs, one set of bugs to chase. v1
   should ship — multi-harness is a v2 problem.

## Why Claude Code headless is next, and why the Agent SDK isn't on the list

If Pi isn't enough — operator wants "literally my Claude Code in the
cloud" — the natural second harness is **`claude -p` (headless Claude
Code as subprocess)**.

The reason: faithfulness to the pitch, *and* it costs us almost nothing
architecturally because we've committed to subprocess-only integration.
See "Subprocess-only is the integration pattern" below.

| | Pi | `claude -p` headless |
|--|-----|----------------------|
| **Pitch fidelity** | "Your Claude Code *workflow* in the cloud, with any model" | "Your literal Claude Code in the cloud" |
| **System prompts, compaction, skill loading** | Pi's own (Claude-Code-shaped) | Claude Code's actual logic — same code path the TUI uses |
| **Model lock-in** | None | Anthropic |
| **Resume mechanism** | Pi's own session model (long-running stdio likely) | JSONL files at `~/.claude/projects/<encoded-cwd>/`, programmatic via `--resume <id>` / `continuation: <id>` |
| **Mid-response push** | Capability-flag dependent (likely supported via Pi's stream-stdin mode) | Supported via `--input-format stream-json` |

The Agent SDK is *not* on the future roadmap. Reason: it's in-process by
definition, which would force us back to maintaining two integration
patterns (subprocess + in-process). The cost of that abstraction tax
outweighs the upside, and nothing in our design actually needs in-process
control (the harness owns its own loop — principle 3). If we ever discover
we *do* need host-level orchestration of the agent loop, that's the moment
to reconsider; until then, subprocess-only stays.

Other CLI-shaped harnesses (Goose, OpenCode, Codex, DeepAgents with a CLI
shim) become "install via skill" the same way NanoClaw handles
`/add-codex` and `/add-opencode` today.

## Billing reality (May 2026 onward)

Anthropic split usage into two buckets effective June 15, 2026:

- **Human-in-the-loop** (Claude Code in a TUI, web chat, desktop app) →
  flat subscription, untouched. The user is interactive.
- **Autonomous** (Agent SDK, `claude -p`, GitHub Actions, anything
  unattended) → **separate monthly credit pool**, bundled into each tier.
  Overage metered.

Per-tier autonomous credits (approximate, [check pricing page](https://claude.com/pricing)):
- Pro ($20/mo) → $20 autonomous credit
- Max ($100/mo) → $100 autonomous credit
- Max ($200/mo) → $200 autonomous credit

Implications for the rewrite:
- **All three Anthropic harnesses (Claude Code headless, Agent SDK, Pi against Anthropic API)
  eat from the autonomous pool.** The harness choice doesn't change the
  billing model.
- **Pi against non-Anthropic backends** (OpenRouter, Ollama, etc.) bills
  through that provider, not Anthropic. This is real money saved if you
  use it for the bulk of conversations.
- **Rate limits matter.** Anthropic temporarily raised Claude Code weekly
  limits 50% through July 13, 2026. After that, the lower limits return.
  Local models and OpenRouter sidestep this.

## Subprocess-only is the integration pattern

NanoClaw expresses three integration patterns through its `AgentProvider`
abstraction: in-process library (`claude.ts` wrapping the Anthropic Agent
SDK), subprocess CLI (`codex.ts`, `opencode.ts`), and mock for tests.
We're keeping only the subprocess CLI pattern.

Reasoning is in `design-principles.md` principle 10 and was worked through
in chat — short version: subprocess-only gives operational uniformity,
language independence, crash isolation, eat-your-own-dogfood ("same `claude`
binary as local"), and easy harness-swap experiments. The cost is some
developer ergonomics (NDJSON parsers per harness, weaker stack traces) and
the loss of guaranteed mid-response push as a primitive. Both are
bearable; the wins compound.

### The interface

We lift the shape of NanoClaw's `AgentProvider`
(`container/agent-runner/src/providers/types.ts:1-17`) but reimplement
subprocess-only. One material change: add `supportsMidResponsePush` so
adapters can declare whether they can accept new user input mid-stream.

```ts
interface AgentProvider {
  readonly supportsNativeSlashCommands: boolean;
  /**
   * Whether this adapter can inject a new user message into an active
   * query stream. Pi (stream-stdin) and claude -p (--input-format
   * stream-json) → true. Adapters without stream-stdin support → false;
   * the host queues mid-stream messages until the current turn completes.
   */
  readonly supportsMidResponsePush: boolean;
  query(input: QueryInput): AgentQuery;
  isSessionInvalid(err: unknown): boolean;
}

interface QueryInput {
  prompt: string;
  continuation?: string;   // opaque — adapter decides what it means
  cwd: string;
  systemContext?: { instructions?: string };
}

interface AgentQuery {
  /** No-op for adapters where supportsMidResponsePush is false. */
  push(message: string): void;
  end(): void;
  events: AsyncIterable<ProviderEvent>;
  abort(): void;
}

type ProviderEvent =
  | { type: 'init'; continuation: string }
  | { type: 'result'; text: string | null }
  | { type: 'error'; message: string; retryable: boolean; classification?: string }
  | { type: 'progress'; message: string }
  | { type: 'activity' };
```

The `continuation` field is opaque, adapter-defined. Pi's continuation is
its session handle; `claude -p`'s is the `session_id` captured from JSON
output and threaded back as `--resume`. The host doesn't care what the
string means.

### The adapter shape (always the same)

Every adapter is a subprocess wrapper:

```
1. Spawn the harness binary (Bun.spawn / child_process.spawn)
   - Long-running stdio for harnesses that support it (Pi)
   - Spawn-per-turn for harnesses that resume cleanly (claude -p)
2. Write prompt to stdin (or pass via CLI args, depending on harness)
3. Read NDJSON / streaming JSON from stdout, parse into ProviderEvent
4. Read stderr → emit as audit events + progress
5. On AgentQuery.push() — if supportsMidResponsePush, write to stdin;
   otherwise no-op (host handles queueing)
6. On AgentQuery.abort() — SIGTERM, then SIGKILL after a grace period
7. Capture continuation from init event; thread back next turn
```

~200 LOC per adapter, mostly the same scaffolding with a per-harness
NDJSON parser. The first adapter (Pi) does the work of designing the
scaffolding; subsequent adapters are cheaper.

### Long-running vs spawn-per-turn

A real per-adapter decision:

- **Spawn-per-turn** (likely `claude -p`): clean state each turn, natural
  fit with `--resume <session_id>`, ~50-100ms spawn overhead per turn.
- **Long-running stdio** (likely Pi): container stays warm, faster per
  turn, slightly more complex (when does the session end? what if it
  hangs? heartbeat from harness into adapter?).

Either is fine. Adapters declare their mode and the scaffolding handles
both shapes. Document the choice in each adapter.

### What about a tool like execa, zx, dax, Bun Shell?

Skip them for the primary loop. They're optimized for shell-script
ergonomics, not long-running streaming subprocess management. Use
`child_process.spawn` (Node) or `Bun.spawn` (Bun) directly — lowest-level
primitive, total control over stdio. execa is fine for one-shot ancillary
commands the host might run (healthchecks, `pi --version`).

## v1 work breakdown

| Component | Approx LOC | Notes |
|-----------|-----------|-------|
| `providers/types.ts` | ~80 | Interface + `ProviderEvent` discriminated union. Lifted-and-modified from NanoClaw. |
| Subprocess-adapter scaffolding | ~150 | Shared across all adapters: spawn helpers, NDJSON parser harness, lifecycle (SIGTERM/SIGKILL), stderr→audit pipe, push-or-queue wrapper around `supportsMidResponsePush`. |
| `providers/pi.ts` (the adapter) | ~120 | Pi-specific: command args, mode (long-running stdio vs spawn-per-turn), output protocol parsing, session-handle handling. |
| Host-side `providers/pi.ts` | ~50 | Container env, mount config, Pi config dir injection. |
| Provider registry + factory | ~40 | Lifted from NanoClaw. |
| Importer subcommand (`ncl import-claude-code`) | ~400 | See `migration-from-claude-code.md` for the spec. |
| Pi binary in the container image | — | Layered into the per-zone Dockerfile. |
| Per-zone harness selection in DB | ~20 | One column on the trust zones table. |

Roughly a week of focused work for the harness layer. Subsequent
adapters (`claude -p` and beyond) reuse the scaffolding — adding one is
~150 LOC of the harness-specific bits, days not weeks.

## Roadmap

| Stage | Status | Adds |
|-------|--------|------|
| v1 | TODO | Pi only. Importer. Per-zone harness column exists but only "pi" is valid. |
| v1.x | TODO | Add `claude -p` as second valid harness. Pitch becomes "your literal Claude Code, or any model via Pi." |

Future harnesses (Goose, DeepAgents with a CLI shim, Codex, OpenCode,
anything else with a CLI) become "install via skill" the same way
NanoClaw does it today — branch repo + `/add-<harness>` skill. Each
reuses the subprocess scaffolding. Not v1 work.

The Agent SDK does *not* appear on the roadmap. See "Why Claude Code
headless is next, and why the Agent SDK isn't on the list" above.

## Open sub-questions

- **Pi's stability.** What's Pi's release cadence? Are there breaking
  changes that would affect a subprocess integration? Need a quick
  research pass before locking in. (Out of scope for the design docs;
  belongs in a future investigation file or a pre-implementation spike.)
- **Anthropic API key vs Pi's chosen backend.** Pi can use Anthropic
  directly. Should the rewrite recommend that as the default backend
  (closest to the Claude Code experience), or push toward OpenRouter /
  local models? Probably default = Anthropic, document the alternatives.
- **Container image size.** Pi is small. `claude -p` future addition
  adds a ~50MB Node binary. Both fit comfortably. Just note for the
  Dockerfile work.
- **Tool allowlist convention.** Claude Code's `permissions.allow`/`deny`
  may not map cleanly to Pi's tool allowlist semantics. Need a one-pass
  test on real allowlists to confirm round-trip.

Sources:
- [Pi Coding Agent — pi.dev](https://pi.dev/)
- [Pi: The Minimal Agent Within OpenClaw — Armin Ronacher](https://lucumr.pocoo.org/2026/1/31/pi/)
- [Run Claude Code programmatically — Claude Code Docs](https://code.claude.com/docs/en/headless)
- [Anthropic June 15 Claude subscription billing overhaul](https://help.apiyi.com/en/anthropic-claude-subscription-agent-sdk-billing-split-june-2026-en.html)
