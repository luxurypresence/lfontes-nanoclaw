# Comparison landscape (v2-flat)

Where the v2-flat rewrite sits relative to existing agent harnesses
and the runtimes they're built on. Refresh of `../ideas/comparison-landscape.md`
to reflect the channel-adapter framing.

Layers to keep straight:

- **Agent runtimes / harnesses**: the actual LLM loop. Pi, Anthropic
  Agent SDK, Claude Code, DeepAgents, Goose, Codex CLI, OpenCode CLI.
- **Higher-level frameworks**: orchestrators around one or more
  runtimes. OpenClaw, NanoClaw, IronClaw, ZeroClaw, **this rewrite**.

OpenClaw is built on Pi. NanoClaw is built on the Anthropic Agent SDK.
The **v2-flat rewrite is built on whichever harness the user picks per
VM** — and the framework doesn't really care which.

## Frameworks at a glance

| Project | Lower-layer runtime | Isolation | Storage | Secrets | Threat model | Stance |
|---------|---------------------|-----------|---------|---------|--------------|--------|
| **OpenClaw** | Pi | None — single host process, application-level checks | Single SQLite | Env vars | Trusts skill authors and model | Broken — CVE-2026-25253 (1-click RCE). |
| **NanoClaw** | Anthropic Agent SDK (in-process) | Docker container per agent group | Per-session SQLite pair as IPC + central SQLite | OneCLI Vault proxy | Trusts containers, distrusts model output reaching host | The "mount-as-policy" model. |
| **IronClaw** (Rust, NEAR AI) | Custom Rust runtime | WASM per skill | Postgres + pgvector | Boundary credential injection | Distrusts skill authors. Optional TEE. | Granular, interesting, too much for personal use. |
| **ZeroClaw** (Rust, <5 MB) | Custom Rust runtime | None — Rust safety + tight allowlists | Embedded | None native | Trusts operator's allowlist | Single binary, no containers, no host. |
| **This rewrite (v2-flat)** | Whatever harness the user picks per VM (Claude Code, Codex, OpenCode, …) | **VM per trust zone.** No in-VM containers. | SQLite per VM (Honker open question) | Subprocess env injection + Unix user split. No vault. | Trusts the user. Trusts their harness. Defends against accidents, not adversaries. | Channel adapter, not agent runtime. |

The **v2-flat row** is the substantive change from v1: instead of
splitting one VM into N containers each running its own harness, we
split into N VMs, each running one harness as a subprocess. The
framework's job is dramatically smaller.

## Lower-layer runtimes at a glance

| Runtime | Native integration patterns | Model lock | Skill/MCP support | Format proximity to Claude Code |
|---------|------------------------------|------------|-------------------|----------------------------------|
| **Pi** (pi.dev) | Subprocess CLI **or** programmatic library | None — model-agnostic | Yes — managed skills + `mcp.json` | Very close |
| **Anthropic Agent SDK** | In-process TypeScript library only | Anthropic | Yes | Conceptually close, but you build the loop |
| **Claude Code headless** (`claude -p`) | Subprocess CLI | Anthropic | Yes — literally Claude Code's | 1:1 |
| **Codex CLI** | Subprocess CLI | OpenAI | Limited | Different surface |
| **OpenCode CLI** | Subprocess CLI | Multi (OpenRouter, OpenAI…) | Yes | Different surface |
| **DeepAgents** (LangChain) | Library | None | Limited | Different surface |
| **Goose** | Subprocess CLI / library | None | Yes | Different surface |

**The v2-flat framework wraps each one as a subprocess on our side,
always.** (Principle 9, carried over from v1 unchanged.) Library-only
runtimes — Agent SDK, DeepAgents — don't fit. If we ever wanted one,
we'd write a ~50-LOC CLI shim around it rather than reintroduce an
in-process integration path.

A major v2-flat shift from v1: the framework doesn't *pick* a default
harness. Per-VM, the operator picks. v1 had "Pi for v1, claude -p
later"; v2-flat has "you bring your own — most people will start with
Claude Code because that's what they already use." The format-proximity
column is now operator-information, not framework-roadmap.

## What each project gets right

- **OpenClaw** — simplicity, first to ship. Established the pattern.
- **NanoClaw** — containers as trust boundaries (the right idea, even
  if I'm not adopting the implementation). Real engineering on
  cross-mount safety, single-writer rules, IPC discipline.
- **IronClaw** — per-skill capability as a *coherent* abstraction.
- **ZeroClaw** — proves you can ship something useful in <5 MB. The
  forcing function of minimalism produces interesting code.

## What v2-flat takes from each

| From | What |
|------|------|
| NanoClaw | The subprocess-CLI harness abstraction. Channel adapter pattern. The discipline of "the harness is a sealed surface; the framework wraps it." |
| Pi / Claude Code / Codex | The harness itself — whichever the operator chose locally. The framework doesn't impose. |
| OpenClaw | The "minimum viable channel adapter" target — but with a real trust boundary (VM) and real observability. |
| IronClaw | Declarative capabilities — moved up to the agent.config.toml + Dockerfile level (what tools this *VM* has), not per-skill. |
| ZeroClaw | Bias toward small. ~1000–1500 LOC ceiling. |
| Honker / pg-boss | Queue + cron + pub-sub semantics that don't require a daemon — though v2-flat may not even need the queue. See `investigations/01-honker-after-simplification.md`. |
| Claude Code's `~/.claude/` | The *configuration surface* — but as a mount target, not a translation source. |

## What v2-flat explicitly does NOT take

| From | What | Why |
|------|------|-----|
| NanoClaw | Per-session SQLite-as-IPC | Solves a problem (cross-mount writer contention) v2-flat doesn't have. |
| NanoClaw | Per-agent-group containers | Wrong axis for this trust model. VMs are the unit. |
| NanoClaw | The OneCLI vault | Overkill for single-user. Subprocess env injection is enough. |
| NanoClaw | The `import-claude-code` translator | Replaced by "mount `.claude/` directly." Strictly better. |
| IronClaw | WASM per skill | Defense against malicious skill authors — not the threat model. |
| IronClaw | Postgres + pgvector | Wasted on single-host, single-writer. |
| IronClaw | TEE | Hardware/cloud lock-in. |
| ZeroClaw | No-container design (in the OpenClaw sense) | We use containers — just as VMs, not as in-VM trust boundaries. |
| v1 of this rewrite | Container-per-zone, host-as-orchestrator | The same threat model is achieved with VMs, simpler. Preserved in `../ideas/` as the rejected path. |

## Resulting design in one sentence

> A VM-deployable channel adapter that runs your existing Claude Code
> (or Codex, or OpenCode) setup as a bot, reachable over Slack /
> Discord / a built-in dashboard, with per-agent observability — one
> trust profile per VM, no in-VM trust boundaries.

## When to revisit

| Trigger | Revisit |
|---------|---------|
| Want pgvector-backed continual memory (Honcho) | Per-VM Postgres? Or accept that harness JSONL is enough. |
| Multi-tenant becomes a goal | Whole design — probably start over. |
| Cross-VM aggregation friction outgrows N tabs | `investigations/04-cross-vm-aggregation.md` |
| N > 5 VMs becomes routine | Either consolidate (back to container-per-zone on one VM) or build the aggregation service. |
| Need shareable skill marketplace with untrusted authors | WASM-per-skill (IronClaw) model. |
| Operator wants per-tool credential gating with human approval | Logging-proxy upgrade: substitute env vars at request time, request approval out-of-band. |
| Want to run on TEE for compliance reasons | Per-VM TEE host. |
| One harness becomes the obvious default and locking matters | Pin a harness version in the framework image instead of leaving it user-installed. |

## Honest comparison vs. v1

What v2-flat *wins* on:

- LOC budget (~1300 vs. v1's projected ~3000+).
- Operator simplicity (one repo, two folders, scripts deploy).
- Faithfulness to the user's existing setup (mount, not translate).
- Decoupling: per-agent framework versions, per-agent harness choice.

What v2-flat *gives up* vs. v1:

- One pane of glass across agents.
- Per-call credential gating with human approval (could be re-added
  later via the logging proxy).
- Per-skill capability declaration (could be re-added via the
  harness's existing allowlist; out of framework scope).
- The intellectual elegance of "trust zone is a container abstraction
  the host orchestrates."

I think the trade is right. Whether you agree depends on whether
"one operator, ≤3 agents" matches your reality.
