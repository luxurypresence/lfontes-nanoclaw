# Design principles (v3-hybrid)

The canonical "what I'm building" doc for v3-hybrid. Everything else
under `ideas-v3-hybrid/` refers back to these. If a later note
contradicts a principle here, either this doc gets updated or the
note gets rejected.

Supersedes `../ideas/design-principles.md` (v1) and
`../ideas-v2-flat/design-principles.md` (v2-flat). The reasoning
behind both rejected paths lives in those folders.

## What I'm building

A personal AI-agent runner. Single tenant (me). One VM (exe.dev for
v1, ports to Hetzner/Fly via the `deploy/` folder). N Docker
containers on that VM, one per agent. Each container runs whatever
coding agent harness the operator picks — Claude Code, Codex,
OpenCode — as a subprocess. The framework around them is a Node host
that handles channels, dashboard, observability, and lifecycle.
Nothing more ambitious than that.

One-sentence pitch:

> Your existing Claude Code setup, running as a Slack/Discord/
> dashboard-reachable bot on a single cheap VM, with per-agent
> isolation, observability, and one-command updates.

## Principles

### 1. Container = trust zone; one VM hosts them all

One Docker container per trust profile. For my use case, ~2: a
`personal-dm` agent and a `public-bot` agent. They share the VM's
hardware but have separate filesystems, separate users (inside the
container), separate credential sets, separate tool installs.

The trust boundary is the Docker container's namespace — not the
Unix user, not a config flag, not an in-process check. If a skill
on `public-bot` wants to read `personal-dm`'s session JSONL, the
file isn't on its filesystem.

### 2. The harness is the agent

The framework does not implement an agent loop. The harness — Claude
Code, Codex, OpenCode — IS the agent. The framework wraps it: webhook
in, container's harness subprocess invoked, output piped back to
channel out.

Carried over from v2-flat unchanged. This was the single most
important framing shift across all three iterations.

### 3. The user's dotfolder is sacred

The framework owns nothing inside `~/.claude/` (or `.codex/`, or
`.opencode/`). The user drops their existing dotfolder into
`shared/`, optionally adds a per-agent overlay in
`agents/<name>/overrides/`, and the deploy pipeline merges the two
into a per-container view. The framework doesn't translate, doesn't
inject, doesn't rewrite.

### 4. Framework distributes as one npm package plus base images

The Node host code ships as `@yourname/agent-host` on npm. The
per-harness container base images (`yourname/agent-claude-base:X.Y.Z`,
etc.) ship to a Docker registry. **One version number, three
artifacts.** Cut a tag, CI publishes everything in lockstep. The
user's `package.json` pins the npm package; their per-agent
Dockerfiles `FROM` the base image at the matching tag.

Updates are `npm update` + `git push` + CI deploy. The user never
edits framework code, never resolves merge conflicts in framework
code, never `git pull`s the framework into their tree.

### 5. Repo structure = trust structure

The user's monorepo has `shared/`, `agents/<name>/`, `deploy/`, and
`data/` (gitignored). The deploy pipeline doesn't slice per VM
(there's only one VM) but slices per *container*: each agent's
container mounts only its own `agents/<name>/.claude.merged/`
directory, never sibling agents. Containers physically cannot read
each other's configs.

### 6. GitHub is the durable layer; the VM is cattle

Skills, configs, Dockerfiles, `agent.config.toml`s — all in the
monorepo. The VM holds only ephemeral state under `data/`: SQLite,
session JSONL files, the logging proxy log. Nuke the VM, `git clone`,
`pnpm install`, `agent-host bootstrap`, you're back.

### 7. Container walls are primary; Unix permissions are defense-in-depth

Containers are the trust boundary. *Inside* each container we still
use Unix permissions: PID 1 is a small framework shim (`agent-container`
binary), the harness runs as a non-root user with limited filesystem
access. Credentials reach the harness via process env, never via
files it can read.

The Unix split is belt-and-suspenders — even if a harness has a path-
traversal bug, it can't read another container's data because that
data isn't on its filesystem. The Unix permissions just stop the
harness from reading its own container's secrets file (there isn't
one) or scribbling on its own mounted read-only config.

### 8. Single host owns visibility

One Node host process. One SQLite under `data/agent.db`. One
dashboard URL. One auth password. One env file at `/etc/agent/env`.
Cross-agent queries ("what did all my agents do yesterday") are one
SQL query against one table.

This restores what v2-flat had to give up. The single-VM topology
makes "host owns visibility" structurally honest again.

### 9. Subprocess-only harness integration

Every harness is wrapped as a subprocess inside its container. The
host doesn't talk to harnesses via in-process libraries or SDKs. The
container shim spawns `claude` (or `codex`, etc.) with stdin/stdout
piped, parses NDJSON from stdout, forwards to the host over
`docker exec`. One integration pattern across all harnesses.

### 10. Minimal moving parts

Node host on the VM. SQLite under `data/`. Docker daemon. N agent
containers, each running tini → shim → harness. Channel webhooks in
(Slack first), dashboard out. That's it.

Target: ~1500 LOC of framework code total (host + shim + CLI).
Holdable in head. If a feature can't justify ~50 LOC, it doesn't
ship without explicit argument.

## What I'm explicitly not doing

| Rejected | Why |
|----------|-----|
| Containers as nothing-but-build-images (v2-flat's later position) | The container's namespace isolation is worth the modest cost of Docker. |
| One VM per agent (v2-flat's headline model) | Operator UX at N≥2 is N dashboards / N envs / N webhooks / N bills. Not worth the hardware-VM isolation gain at single-tenant personal scale. |
| Dual SQLite DBs as IPC (v1) | Host directly streams over `docker exec`. No need. |
| OneCLI vault | Subprocess env injection is enough. |
| Honker pub/sub / queue | Single host process = direct in-process dispatch. SQLite handles cron + retry trivially. See `investigations/01-honker-after-simplification.md`. |
| Translating Claude Code config into framework format | Mount the user's dotfolder directly. v1 had an importer; v3-hybrid doesn't need one. |
| WASM-per-skill (IronClaw) | Wrong threat model. |
| OverlayFS for mounts | Deploy-time merge into a unified directory + two bind mounts is simpler. |
| Multi-tenant on the VM | Single human. If I ever host for someone else, separate VM. |
| Framework code in the user's repo | npm package + base images. The user's repo holds *their* stuff. |
| Per-agent framework versions | All agents on one VM share one framework. Container image versioning is independent per-agent; framework versioning is per-VM. |
| Per-call human approval for credentials | The logging proxy is a future place to add this; not v1. |

## Accepted trade-offs

- **One VM, one bill.** No N-of-everything operator tax. Trade-off:
  if I want stronger isolation for one specific agent (say,
  `public-bot` on the open internet), I'd have to spin it onto its
  own VM and the architecture has to accommodate that. The
  architecture *does* accommodate it — `public-bot` becomes a single-
  agent v2-flat-style deployment — but it's a separate path, not the
  default.
- **All agents share framework version.** A buggy framework upgrade
  affects all agents on the VM at once. Mitigation: standard Node-app
  deployment hygiene — stage the upgrade on a non-production monorepo
  first.
- **Docker daemon on the VM.** One more thing to set up. Standard,
  cheap. `agent-host bootstrap` handles it.
- **Container restart on framework upgrade.** Bumping
  `@yourname/agent-host` triggers a host restart, which means a
  brief outage for all agents. Mitigation: do upgrades during low-
  activity windows; if it ever becomes painful, add rolling container
  restarts on framework boot.
- **No cross-VM aggregation.** Same as v2-flat; if I ever want
  multiple VMs (because one specific agent needed hardware isolation),
  the aggregation path from `../ideas-v2-flat/investigations/04-cross-vm-aggregation.md`
  still applies.

## Where to find what

- **Why containers and not VMs:** the conversation trail across
  `../ideas/` (v1) and `../ideas-v2-flat/` (v2-flat). v3-hybrid is
  where the contradictions resolved.
- **Distribution shape:** `distribution.md`.
- **Container internals:** `container-shim.md`.
- **Storage and mounting:** `harness-mounting.md`.
- **Open questions:** `investigations/`.
