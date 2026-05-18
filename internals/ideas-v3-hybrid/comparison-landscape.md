# Comparison landscape (v3-hybrid)

Where v3-hybrid sits relative to existing agent frameworks and the
runtimes they're built on. Refresh of `../ideas-v2-flat/comparison-landscape.md`,
which was itself a refresh of `../ideas/comparison-landscape.md`.

Two layers to keep straight:

- **Agent runtimes / harnesses**: the actual LLM loop. Pi, Anthropic
  Agent SDK, Claude Code, DeepAgents, Goose, Codex CLI, OpenCode CLI.
- **Higher-level frameworks**: orchestrators around one or more
  runtimes. OpenClaw, NanoClaw, IronClaw, ZeroClaw, **v3-hybrid**.

OpenClaw is built on Pi. NanoClaw is built on the Anthropic Agent SDK.
**v3-hybrid is built on whichever harness the user picks per agent** —
and the framework doesn't really care which.

## Frameworks at a glance

| Project | Lower-layer runtime | Isolation | Storage | Secrets | Threat model | Stance |
|---------|---------------------|-----------|---------|---------|--------------|--------|
| **OpenClaw** | Pi | None — single host process, application-level checks | Single SQLite | Env vars | Trusts skill authors and model | Broken — CVE-2026-25253 (1-click RCE). |
| **NanoClaw** | Anthropic Agent SDK (in-process) | Docker container per agent group | Per-session SQLite pair as IPC + central SQLite | OneCLI Vault proxy | Trusts containers, distrusts model output reaching host | The "mount-as-policy" model. |
| **IronClaw** (Rust, NEAR AI) | Custom Rust runtime | WASM per skill | Postgres + pgvector | Boundary credential injection | Distrusts skill authors. Optional TEE. | Granular, interesting, too much for personal use. |
| **ZeroClaw** (Rust, <5 MB) | Custom Rust runtime | None — Rust safety + tight allowlists | Embedded | None native | Trusts operator's allowlist | Single binary, no containers, no host. |
| **v3-hybrid (this rewrite)** | Whatever harness the user picks per agent | **Docker container per agent, single VM** | Single SQLite in user monorepo's `data/` | Host injects env per container at spawn. No vault. | Trusts the user. Trusts their harness. Defends against accidents. | Channel adapter, not agent runtime. |

The v3-hybrid row is the substantive landing. It keeps NanoClaw's
container-as-trust-boundary insight, drops NanoClaw's complex IPC
plumbing, and rejects v2-flat's "lose containers altogether" reaction.

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

**The v3-hybrid framework wraps each one as a subprocess inside its
container, always.** (Principle 9.) Library-only runtimes — Agent
SDK, DeepAgents — don't fit. If we ever wanted one, a ~50-LOC CLI
shim around it would let it participate in the same subprocess flow.

Per-agent harness selection is set in `agent.config.toml`:

```toml
[harness]
kind = "claude"      # "claude" | "codex" | "opencode"
```

The shim inside each container reads this and spawns the right
binary. The host doesn't care which.

## What each project gets right

- **OpenClaw** — simplicity, first to ship. Established the channel-
  adapter pattern.
- **NanoClaw** — containers as trust boundaries (the right idea,
  with simpler implementation in v3-hybrid).
- **IronClaw** — per-skill capability as a *coherent* abstraction.
- **ZeroClaw** — minimum-viable bias. Reminds us that 1000-1500 LOC
  is a real ceiling.

## What v3-hybrid takes from each

| From | What |
|------|------|
| NanoClaw | Container-per-agent trust boundary. Channel adapter pattern. The subprocess-CLI harness abstraction. The discipline of "the harness is a sealed surface; the framework wraps it." |
| v2-flat (rejected) | Monorepo with `shared/` + `agents/<name>/` + `deploy/`. Framework distributes as a versioned image (refined: npm package + base images). "Framework owns nothing in `~/.claude/`." Mount, don't translate. |
| Pi / Claude Code / Codex | The harness — whichever the operator chose locally. The framework doesn't impose. |
| OpenClaw | Channel-adapter shape as the minimum viable product. |
| IronClaw | Declarative capabilities — moved up to per-container Dockerfile, not per-skill. |
| ZeroClaw | Small. ~1500 LOC ceiling. |
| Honker / pg-boss | Queue + cron semantics — but we don't end up needing the queue (single host, single in-memory dispatcher). See `investigations/01-honker-after-simplification.md`. |
| Claude Code's `~/.claude/` | The configuration surface — mounted directly, not translated. |

## What v3-hybrid explicitly does NOT take

| From | What | Why |
|------|------|-----|
| NanoClaw | Per-session SQLite-as-IPC | Solves a problem (cross-mount writer contention) v3-hybrid doesn't have — host writes its own DB, containers don't touch it. |
| NanoClaw | OneCLI vault | Subprocess env injection is enough for single-user. |
| NanoClaw | Container-side agent-runner with long-poll RPC | Host streams stdin/stdout via `docker exec`. No long-poll needed. |
| NanoClaw | `import-claude-code` translator | Replaced by deploy-time merge of `shared/` + `overrides/`. Mount > translate. |
| v1 (containers + RPC) | The whole IPC architecture | Massive simplification. The host is in charge; containers don't need to phone home. |
| v2-flat (rejected) | One VM per agent | Operator UX disaster at N≥2. |
| v2-flat (rejected) | OverlayFS for dotfolder layering | Deploy-time merge is simpler and doesn't need a kernel feature. |
| IronClaw | WASM per skill | Wrong threat model. |
| IronClaw | Postgres + pgvector | Single-writer single-host. |
| IronClaw | TEE | Hardware/cloud lock-in. |
| ZeroClaw | No-container design | We keep containers — they're the trust boundary. |

## Resulting design in one sentence

> A Node host on one VM that orchestrates N Docker containers, each
> running your existing Claude Code (or Codex, or OpenCode) setup as
> a subprocess, with channels in, dashboard out, mounted dotfolders,
> and one observability surface.

## When to revisit

| Trigger | Revisit |
|---------|---------|
| Want pgvector-backed continual memory (Honcho) | Per-VM Postgres. |
| Multi-tenant becomes a goal | Whole design — probably start over. |
| One agent needs true hardware isolation (e.g., compliance) | Spin *that one* into a separate VM (v2-flat-style); the rest stay on the shared VM. |
| Number of agents grows past ~5 on one VM | Consider hardware-resource pressure; consider whether to split into two VMs along trust lines. |
| Need shareable skill marketplace with untrusted authors | WASM-per-skill (IronClaw) model. |
| Operator wants per-tool credential gating with human approval | Logging-proxy upgrade: env var substitution at request time + out-of-band approval. |
| Pi or Claude Code becomes unmaintained | The shim is harness-agnostic; switch the binary. |

## Honest comparison vs. v1 and v2-flat

What v3-hybrid wins on (vs. v1):

- Dramatically simpler IPC (none, really — `docker exec` stream).
- No dual-DB-as-IPC.
- No OneCLI vault.
- No per-container scheduler/queue.
- Smaller framework footprint (~1500 LOC vs. v1's projected ~3000+).
- The monorepo + mount-dotfolder model.

What v3-hybrid wins on (vs. v2-flat):

- One dashboard.
- One env file.
- One Slack app possible (host routes by sender).
- One auth password.
- One VM bill.
- Cross-agent observability is free.
- No OverlayFS dependency.

What v3-hybrid gives up (vs. v2-flat):

- Hardware-VM-level isolation between agents. Container + Unix-user-
  inside-container is meaningfully less, but enough for the threat
  model (single-tenant, audited skills, defends against accidents
  not adversaries).
- Per-agent independent reboot of the framework. (Per-agent container
  restart still works; framework upgrade is global to the VM.)

I think the trade is right for any operator running ≤5 agents on
their own. If you're running 50, you're not running this framework.
