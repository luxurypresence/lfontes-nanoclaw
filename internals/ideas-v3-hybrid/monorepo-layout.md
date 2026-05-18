# Monorepo layout

The user's repo. The framework is a dependency in `package.json`,
not source in the tree. Per-agent definitions live under
`agents/<name>/`; shared baseline under `shared/`; deploy machinery
under `deploy/`; live state under `data/` (gitignored).

## Directory tree

```
my-agents/                                ← single repo on my laptop
├── package.json                          ← pins @yourname/agent-host
├── pnpm-lock.yaml
├── .gitignore                            ← includes `data/`
├── README.md                             ← operator's notes
├── host.config.toml                      ← VM-wide config (dashboard port, etc.)
├── shared/
│   ├── .claude/                          ← user's existing ~/.claude, copied in
│   │   ├── CLAUDE.md
│   │   ├── settings.json
│   │   ├── skills/
│   │   ├── commands/
│   │   ├── agents/                       ← Claude Code subagents
│   │   └── mcp.json
│   ├── .codex/                           ← if also using Codex
│   └── .opencode/                        ← if also using OpenCode
├── agents/
│   ├── personal-dm/
│   │   ├── Dockerfile                    ← FROM yourname/agent-claude-base:1.4.2
│   │   ├── agent.config.toml             ← harness, channels, identity
│   │   └── overrides/
│   │       └── .claude/                  ← per-agent overlay on top of shared/.claude/
│   │           ├── CLAUDE.md             ← per-agent identity memory
│   │           └── skills/
│   │               └── personal-only/    ← skills only this agent gets
│   └── public-bot/
│       ├── Dockerfile
│       ├── agent.config.toml
│       └── overrides/
│           └── .claude/
│               └── CLAUDE.md
├── deploy/                               ← NEVER lands on the VM at runtime
│   ├── exe-config.toml                   ← exe.dev VM spec
│   ├── bootstrap.sh                      ← wrapper around `agent-host bootstrap`
│   └── env-templates/
│       └── env.example                   ← `.env` file shape
├── data/                                 ← gitignored
│   ├── agent.db                          ← SQLite (host state)
│   ├── sessions/                         ← per-agent writable session volumes
│   │   ├── personal-dm/
│   │   │   └── projects/                 ← Claude Code JSONL files
│   │   └── public-bot/
│   │       └── projects/
│   ├── merged/                           ← deploy-time merge output
│   │   ├── personal-dm/.claude/          ← mounted RO into personal-dm container
│   │   └── public-bot/.claude/
│   └── proxy.log
└── .github/
    └── workflows/
        └── deploy.yml                    ← on push: rsync, install, migrate, restart
```

## `package.json`

```json
{
  "name": "my-agents",
  "private": true,
  "type": "module",
  "packageManager": "pnpm@9.0.0",
  "dependencies": {
    "@yourname/agent-host": "^1.4.0"
  },
  "scripts": {
    "start":     "agent-host start",
    "migrate":   "agent-host migrate",
    "doctor":    "agent-host doctor",
    "new-agent": "agent-host new-agent",
    "bootstrap": "agent-host bootstrap"
  }
}
```

Single framework dependency. The `agent-host` CLI binary comes with
the package. Everything operator-facing is one command.

## `.gitignore`

```
data/
node_modules/
*.local.toml
.env
.env.*
```

`data/` is the entire framework state. Survives Git pulls, gets
wiped if the VM is destroyed.

## `host.config.toml`

VM-wide host configuration. Shared by all agents on the VM.

```toml
[host]
dashboard_port = 8443
dashboard_url  = "https://my-agents.exe.dev/"

[logging]
proxy_listen = "127.0.0.1:8080"
retention_days = 30

[bootstrap]
node_version = "20"
docker_install = true
```

Lives in the repo. Read by `agent-host start` and `agent-host
bootstrap`. Doesn't change between agents.

## `agent.config.toml` (per agent)

```toml
[agent]
name     = "personal-dm"
identity = "user:luis"               # canonical operator who can talk to this agent

[harness]
kind          = "claude"             # "claude" | "codex" | "opencode"
flags         = ["--dangerously-skip-permissions"]

[container]
image_tag     = "yourname-agent-personal-dm:latest"   # built from this dir's Dockerfile
memory_limit  = "2g"
cpu_limit     = 1.0

[env]
# Names of env vars the host should inject into this container at spawn.
# Values come from /etc/agent/env on the host.
inject = ["ANTHROPIC_API_KEY", "GH_TOKEN_RW", "VERCEL_TOKEN"]

[channels]
adapters = ["slack-dm", "dashboard"]

[channels.slack-dm]
workspace      = "T0LP"
allow_senders  = ["U_luis"]          # Slack user IDs that this agent listens to
```

Host parses this when starting and uses it to:
- Build the `docker run` invocation (image, mounts, env, limits).
- Wire channel webhooks to route to this agent based on
  `(channel, sender) → agent`.
- Reject inbound messages from senders not in `allow_senders`.

No `framework_version` field — the whole VM runs one framework
version (the one pinned in `package.json`). Container image
versioning is per-agent via the Dockerfile.

## Override semantics

`shared/.claude/` is the base. `agents/<name>/overrides/.claude/` is
the overlay. Deploy-time merge produces `data/merged/<name>/.claude/`,
which gets mounted read-only into the container as `~/.claude/`.

Merge rules (it's just rsync, but worth being explicit):

- File in shared only → appears in merged.
- File in overrides only → appears in merged.
- File in both → overrides version wins (overrides is rsynced *after*
  shared, overwriting).
- Directory in both → contents are merged (rsync default).

No "append" semantics. If `shared/.claude/CLAUDE.md` has memory you
want everywhere and an agent wants additional memory, the agent's
`overrides/.claude/CLAUDE.md` fully replaces the shared one — the
operator either includes the shared content in the override, or
splits memory into separate files (one in shared, one per-agent).

Practical convention: most things go in `shared/`. Overrides should
be small — per-agent identity memory, a couple of agent-specific
skills. If overrides start mirroring shared, that's a signal to
move content the other way.

## What goes in shared vs. agent-specific

| Thing | Where | Why |
|-------|-------|-----|
| General coding-style CLAUDE.md | `shared/` | Same across all agents. |
| "You are personal-dm" identity prompt | `agents/personal-dm/overrides/.claude/CLAUDE.md` | Per-agent identity. |
| `gh-research` skill | `shared/` | Useful everywhere. |
| `deploy-prod` skill | `agents/personal-dm/overrides/` | Only `personal-dm` should ever invoke this. |
| MCP servers everyone uses | `shared/.claude/mcp.json` | Common pool. |
| MCP server specific to one agent | `agents/<name>/overrides/.claude/mcp.json` | Fully replaces shared file — copy what's needed from shared, add the agent-specific bits. |

## Per-agent Dockerfile shape

The framework ships templates (see `distribution.md`). A typical one
ends up as:

```dockerfile
FROM yourname/agent-claude-base:1.4.2

# Per-agent tool installs
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      gh vercel-cli \
 && rm -rf /var/lib/apt/lists/*

# Entrypoint is inherited from the base image:
#   /usr/local/bin/agent-container
# We do NOT override ENTRYPOINT or CMD.
USER agent
```

Three lines of actual content. The base image owns the framework
shim (`agent-container`) and the harness binary. The user adds tools.

For an agent that wants minimal tooling (`public-bot`):

```dockerfile
FROM yourname/agent-claude-base:1.4.2
USER root
RUN apt-get update && apt-get install -y gh \
 && rm -rf /var/lib/apt/lists/*
USER agent
```

The Dockerfile is the per-agent capability declaration: "this agent
has `gh` and `vercel`, that one has just `gh`."

## CI / deploy-on-push

`.github/workflows/deploy.yml` does, on push to main:

1. `rsync` the monorepo (minus `data/`, `node_modules/`, `deploy/`)
   to `/srv/agent/` on the VM.
2. SSH: `pnpm install --frozen-lockfile`.
3. SSH: `agent-host migrate` (idempotent).
4. SSH: for each agent whose `Dockerfile` or `overrides/` changed:
   - Re-run deploy-time merge into `data/merged/<name>/`.
   - `docker build` the new image.
   - `agent-host cycle <name>` to restart that container.
5. SSH: `systemctl restart agent-host` if anything in `node_modules/`
   changed (i.e., framework was bumped).

Change-detection is cheap (compare `git diff` paths). Avoid
restarting the host unless the framework changed.

## Operator UX

Adding an agent:

```bash
pnpm agent-host new-agent work-bot
# scaffolds agents/work-bot/{Dockerfile, agent.config.toml, overrides/.claude/}

# edit agents/work-bot/agent.config.toml
# edit agents/work-bot/Dockerfile if you need different tools
git add agents/work-bot/
git commit -m "add work-bot agent"
git push
# CI deploys; host picks up the new agent on restart
```

Removing an agent:

```bash
rm -rf agents/work-bot
git commit -am "remove work-bot agent"
git push
# CI deploys; host stops + removes the work-bot container on restart
```

The whole lifecycle is reading and editing files in this repo.

## Open sub-questions

- **Mono vs. multi-repo.** Monorepo. Submodules and multiple repos
  fight the simplicity story.
- **Where do per-agent secrets go?** `deploy/env-templates/env.example`
  has the *shape*; actual secrets live in a password manager and get
  written to `/etc/agent/env` on the VM during bootstrap.
- **Generated vs. hand-written `Dockerfile`.** Each agent's Dockerfile
  is short (3-10 lines) and hand-written. `agent-host new-agent`
  scaffolds it; the operator edits freely.
- **`make diff` for trust-slicing.** A command that shows "what
  would actually deploy" is cheap to write and useful for catching
  mistakes. Optional v1.
- **Bootstrap convenience.** `deploy/bootstrap.sh` is just a wrapper
  around `agent-host bootstrap` that pre-fills exe.dev specifics from
  `deploy/exe-config.toml`. Different platforms get different
  wrapper scripts.
