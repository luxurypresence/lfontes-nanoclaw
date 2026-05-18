# Comparison landscape

Where the rewrite sits relative to existing agent harnesses and the
runtimes they're built on. Useful when I forget *why* I rejected an option.

Two layers worth keeping straight:

- **Agent runtimes / harnesses** (the lower layer): the actual loop that
  drives an LLM, manages tools, handles compaction. Examples: Pi,
  Anthropic Agent SDK, Claude Code, DeepAgents, Goose, Codex CLI,
  OpenCode CLI.
- **Higher-level frameworks** (the upper layer): orchestrators that run
  one or more agent runtimes in some operational shape — usually around
  channels, identity, scheduling, multi-agent wiring. Examples: OpenClaw,
  NanoClaw, IronClaw, ZeroClaw, this rewrite.

OpenClaw is built on Pi. NanoClaw is built on the Anthropic Agent SDK.
The rewrite is built on Pi (same lower layer as OpenClaw, different upper
layer with a different threat model).

## Frameworks at a glance

| Project | Lower-layer runtime | Isolation | Storage | Secrets | Threat model | Stance |
|---------|---------------------|-----------|---------|---------|--------------|--------|
| **OpenClaw** | Pi | None — single host process, application-level checks only | Single SQLite | Env vars | Trusts skill authors and the model | Broken — CVE-2026-25253 (1-click RCE) proved it. |
| **NanoClaw** | Anthropic Agent SDK (in-process) | Container per agent group | Per-session SQLite pair as IPC + central SQLite | OneCLI Vault proxy with per-request injection | Trusts containers, distrusts model output reaching the host | Where this fork starts. The "mount-as-policy" model. |
| **IronClaw** (Rust, Llion Jones / NEAR AI) | Custom Rust runtime | WASM per skill | Postgres + pgvector | Boundary credential injection | Distrusts skill authors. Optional TEE. | Architecturally interesting, too granular for personal use. |
| **ZeroClaw** (Rust, single binary, <5 MB RAM) | Custom Rust runtime | None — Rust safety + tight allowlists + workspace scoping | Embedded | None native | Trusts the operator's allowlist | Closer to OpenClaw's threat model but much stricter execution. |
| **This rewrite** | Pi (subprocess CLI; `claude -p` later as second harness) | Container per trust zone (~2 containers) | Central SQLite + Honker; per-container SQLite for session | Ambient env per zone, scoped to that zone's powers | Trusts me. Untrusts model output reaching the host. | Departure from NanoClaw — splits on identity, not agent group. |

## Lower-layer runtimes at a glance

| Runtime | Native integration patterns | Model lock | Skill/MCP support | Format proximity to Claude Code |
|---------|------------------------------|------------|-------------------|----------------------------------|
| **Pi** (pi.dev) | Subprocess CLI **or** programmatic library | None — model-agnostic (Anthropic, OpenAI, OpenRouter, Ollama, local…) | Yes — managed skills + `mcp.json` | Very close: same `settings.json` filename, same skills convention, MCP via json mapping |
| **Anthropic Agent SDK** (`@anthropic-ai/claude-agent-sdk`) | In-process TypeScript library only | Anthropic (Claude only) | Yes — mimics Claude Code's behavior | Conceptually close, but you build the loop |
| **Claude Code headless** (`claude -p`) | Subprocess CLI | Anthropic (Claude only) | Yes — literally Claude Code's | 1:1 (it *is* Claude Code) |
| **Codex CLI** | Subprocess CLI | OpenAI | Limited | Different surface |
| **OpenCode CLI** | Subprocess CLI | Multi (OpenRouter, OpenAI, etc.) | Yes | Different surface |
| **DeepAgents** (LangChain) | Library | None | Limited | Different surface |
| **Goose** | Subprocess CLI / library | None | Yes | Different surface |

**Our rewrite wraps each one as subprocess CLI on our side, always**
(see `design-principles.md` principle 10 and `harness-selection.md`).
That means runtimes with a native CLI mode slot in cleanly (Pi,
`claude -p`, Codex, OpenCode, Goose); library-only runtimes like the
Agent SDK and DeepAgents don't fit and aren't on the roadmap. If we
ever need a library-only runtime, we'd write a small CLI shim around
it (~50 LOC) rather than reintroduce an in-process integration path.

## What each one gets right

- **OpenClaw** — simplicity, first to ship. Established the pattern.
- **NanoClaw** — containers as trust boundaries, no IPC except files,
  single-writer-per-file rule. Real engineering investment in safety.
- **IronClaw** — per-skill capability as a *coherent* abstraction (even if
  too granular for me).
- **ZeroClaw** — proves you can ship something useful in <5 MB. The
  forcing function of minimalism produces interesting code.

## What I'm taking from each

| From | What |
|------|------|
| NanoClaw | Containers as trust boundaries. Channel adapter pattern. The `AgentProvider` abstraction (lifted nearly verbatim — see `harness-selection.md`). OneCLI-style boundary credential injection (idea, not the actual proxy). |
| Pi | The lower-layer runtime — model-agnostic, minimal, with Claude-Code-shaped configuration. Same engine OpenClaw chose, with our own upper layer on top. |
| IronClaw | Treating "what tools a context has" as a deliberate, declared thing — but I move the declaration from per-skill to per-zone. |
| ZeroClaw | Bias toward small. If a feature can't justify ~50 LOC, it doesn't ship. |
| pg-boss / Honker | Queue + cron + pub-sub semantics that don't require a daemon. |
| Claude Code | The configuration surface (`~/.claude/`) — skills, subagents, MCP servers, CLAUDE.md. The importer translates this into Pi's near-identical equivalent. |

## What I'm explicitly not taking

| From | What | Why |
|------|------|-----|
| NanoClaw | Per-session SQLite-as-IPC | Solves a problem (cross-mount writer contention) I don't have, costs a lot in complexity. See `queue-based-rewrite.md`. |
| NanoClaw | Per-agent-group containers | Wrong axis for my actual trust model. See `trust-zones.md`. |
| IronClaw | WASM per skill | Defense against malicious skill authors — not my threat model. |
| IronClaw | Postgres + pgvector | Wasted on a single-writer single-host setup. Reconsider only if I want Honcho. |
| IronClaw | TEE | Hardware/cloud lock-in for a personal install. |
| ZeroClaw | No-container design | I want the kernel-level isolation of containers for credential blast-radius reasons. |

## How I'd describe the resulting design in one sentence

> NanoClaw's container-as-trust-boundary model, but split on sender identity
> instead of agent group, with Pi as the lower-layer runtime, the per-session
> SQLite-as-IPC dance replaced by an intent-shaped RPC layer over a single
> Honker-backed SQLite file, and your local Claude Code config importable
> in one command.

## When to revisit

| Trigger | Revisit |
|---------|---------|
| Want pgvector-backed continual memory (Honcho) | Postgres central store |
| Multi-tenant becomes a goal | Whole design — probably start over |
| Honker becomes unmaintained at alpha | Move to pg-boss + Postgres |
| Need shareable skill marketplace with untrusted authors | WASM-per-skill (IronClaw) model |
| Skill set explodes past what one human can audit | Same |
| Want to run on TEE for compliance reasons | Add TEE-mode flag, keep rest |
| Pi becomes unmaintained or pivots away from MCP/skills compat | Add `claude -p` (headless Claude Code) as second harness (already on roadmap — see `harness-selection.md`) |
| Operator wants "literally my Claude Code" pitch fidelity over model-agnostic | Same — `claude -p` as alternate harness |
