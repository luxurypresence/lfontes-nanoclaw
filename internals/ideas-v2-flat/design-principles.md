# Design principles (v2-flat)

The canonical "what I'm building" doc for the v2-flat architecture.
Everything else under `ideas-v2-flat/` refers back to these. If a
later note contradicts a principle here, either this doc gets updated
or the note gets rejected.

Supersedes `../ideas/design-principles.md` (the container-per-zone
model). The reasoning that produced this doc lives in v1; this is
the conclusion that survived.

## What I'm building

A personal AI-agent runner. Single tenant (me). Each trust profile
gets its own cheap VM (exe.dev for v1, ports to Hetzner/Fly trivially
later). The agent runtime is a real coding agent — Claude Code, Codex,
OpenCode — running as a subprocess on the VM. The framework around it
is a channel adapter that turns "this Slack DM" into "this subprocess
invocation" and back. Nothing more ambitious than that.

One-sentence pitch:

> A VM-deployable channel adapter that runs your existing Claude Code
> setup as a bot, reachable over Slack/Discord/dashboard, with
> observability.

## Principles

### 1. VM = trust zone

One VM per trust profile. Need "me on DM, full powers" and
"public-channel bot, read-only" as separate profiles? Two VMs. Need a
third for work-only stuff? Third VM.

VMs are cheaper than the architectural cost of in-VM isolation. The
container-as-trust-boundary model (v1) tried to make one VM host
multiple trust profiles safely; v2-flat decides that's the wrong
trade. Hardware-level isolation is bought, not engineered.

### 2. The harness is the agent

The framework does not implement an agent loop. The harness — Claude
Code, Codex, OpenCode — IS the agent. The framework wraps it: webhook
in, subprocess invoked, output piped to channel out.

This is the single biggest framing shift from v1. v1 thought of the
container as the agent and the harness as a runtime detail. v2-flat
flips it: the harness is the unit of identity, and the framework is
plumbing around it.

### 3. The user's dotfolder is sacred

The framework owns nothing inside `~/.claude/` (or `.codex/`, or
`.opencode/`). No injected MCP servers, no injected skills, no
settings overrides. If something needs to be passed to the harness,
it goes via env vars or CLI flags.

Mount the user's existing dotfolder as read-only lower; let the agent
write to a writable upper layer; never edit the lower in place. The
user's harness home is their territory.

### 4. Framework code never lives in the user's repo

The framework ships as a versioned Docker image
(`yourname/agent-host:1.4.2`). The user's repo contains a Dockerfile
that's `FROM yourname/agent-host:1.4.2` plus their tool installs.
Upgrade = bump tag, redeploy. The user never has to `git pull` a
framework update; the user never has to resolve a merge conflict in
framework code.

Per-agent independent versioning falls out of this. Different agents
can run different framework versions. Test on one before flipping the
other.

### 5. Repo structure = trust structure

The monorepo has `shared/`, `agents/<name>/`, and `deploy/`. The
deployment pipeline slices the monorepo per VM: each VM only receives
the bytes for its agent — its own `agents/<name>/` subtree plus
`shared/`, never sibling agents, never `deploy/`. Agents are
physically incapable of seeing other agents' configs.

This is the v2-flat answer to "how do trust boundaries get enforced":
not at runtime by walls, but at deploy time by which bytes ever reach
which VM.

### 6. GitHub is the durable layer

Skills, configs, prompts, Dockerfiles — all in the monorepo (Git).
The VM holds only ephemeral state: live sessions, audit log, queue.
Nuke a VM, `git clone`, `docker pull`, rebuild — back to the same
agent. VMs are cattle.

Honcho-style continual memory, vector stores, long-term agent memory
— all out of scope. If the harness wants to persist conversation
state, it does so in its own `~/.claude/projects/`, which lives on
the VM's persistent disk (writable upper layer of OverlayFS) and gets
backed up like any other VM state. The framework doesn't try to be
the memory layer.

### 7. Unix permissions do the security work

Two users on the VM: `host` (the Node framework process) and `agent`
(the harness subprocess). The `.env` file with credentials lives at
`/etc/agent/env`, owned `root:root`, mode `0600`. `host` reads it at
startup; `agent` cannot read it from disk. Credentials reach the
harness via subprocess env, in memory only.

This is enough security for a single-user personal-use bot. It's not
defense against a malicious harness; it's defense against
*accidents* — a skill that reads `~/.env` by mistake, a log line that
flushes too much. The threat model is bug-shaped, not adversary-shaped.

### 8. Per-VM visibility; cross-VM aggregation is later

Each VM exposes its own dashboard, internet-reachable via exe.dev
HTTPS, auth-gated. The dashboard shows that VM's audit log, recent
activity, queue state, scheduled tasks.

The v1 principle "host owns visibility" is *demoted* here, deliberately.
Cross-VM aggregation (one dashboard for all your agents) is real
operator friction at N=5 but tolerable at N=2. The aggregation layer
is a future add-on — sketched in `investigations/04-cross-vm-aggregation.md`,
not built in v1.

### 9. Subprocess-only harness integration

Every harness is wrapped as a subprocess. No in-process libraries, no
SDK paths. One integration pattern across all harnesses.

This principle carries over from v1 verbatim — the reasoning is in
`../ideas/harness-selection.md`. With v2-flat the case is even
stronger: the host process is small and language-agnostic, and the
harness is whatever the user happens to be using locally. Subprocess
is the only honest interface.

### 10. Minimal moving parts

Node host. SQLite (with or without Honker — see
`investigations/01-honker-after-simplification.md`). Logging proxy.
Subprocess. A dashboard view. Channel adapters for Slack/Discord/
dashboard chat.

Target ~1000–1500 lines of framework code, total. If it grows past
that without a deliberate decision, something has slipped past this
principle and needs to be argued for explicitly.

## What I'm explicitly not doing

| Rejected | Why |
|----------|-----|
| Containers as trust boundaries (v1's model) | VMs do the same job better, with less in-VM architecture. The whole container-per-zone reasoning lives in `../ideas/` if I ever doubt this. |
| OneCLI / credential vault | Same threat model as env vars + Unix permissions, with more moving parts. Acceptable at this scale. |
| Translating Claude Code config into our own format | The v1 importer becomes irrelevant when we just mount `.claude/` directly. Mount > translate. |
| Cross-agent shared state in the framework | If two agents need to share state, they do it through a channel. The framework doesn't try to be a coordinator. |
| Multi-tenant on one VM or across VMs | Single human. If I ever host this for someone else, spin them their own VMs. |
| Postgres centrally | SQLite on each VM, single-writer, single-host. Same reasoning as v1. |
| WASM-per-skill (IronClaw model) | I write/audit my own skills. The harness's existing tool allowlist is enough. |
| Framework-injected config in user's dotfolder | The user's `.claude/` is read-only-lower; the framework doesn't touch it. |
| A single dashboard across all VMs at v1 | Acknowledged loss vs v1. Path documented in `investigations/04-cross-vm-aggregation.md`. Not built at v1. |

## Accepted trade-offs

- **N VMs cost N bills.** Two VMs is two bills. If it ever becomes
  four or five, that's real money. Mitigation: exe.dev is cheap and
  VMs can be aggressively sized down. Watch the line.
- **Per-VM channel webhooks.** Each VM wired to Slack needs its own
  webhook URL configured in the Slack app (or one Slack app routing
  to N URLs). Documented in `investigations/03-webhook-fanout.md`.
  Setup tax, not a runtime concern.
- **No single audit view across agents at v1.** "What did all my
  agents do yesterday?" is N tabs or N CLI queries. Acceptable at
  N=2; gets annoying past N=3. Investigation 04 is the escape hatch.
- **OverlayFS dependency.** Mounting the user's `.claude/` as
  read-only lower + writable upper requires OverlayFS on the VM
  kernel. Universal on modern Linux; flagged in
  `investigations/02-overlayfs-sessions.md`.
- **Honker may not survive simplification.** With one host + one
  subprocess per VM, the pub/sub and queue-with-many-workers value
  of Honker drops sharply. We may end up using SQLite directly. See
  `investigations/01-honker-after-simplification.md`.

## Where to find what

- **Why this supersedes v1's container model:** the conversation
  trail in `../ideas/` plus the new top-level discussion. v1 isn't
  wrong; v1 is over-engineered for the actual threat model.
- **Deployment specifics:** `deployment-shape.md`.
- **Repo layout:** `monorepo-layout.md`.
- **Harness mounting:** `harness-mounting.md`.
- **Framework lifecycle:** `framework-versioning.md`.
- **Open questions:** `investigations/`.
