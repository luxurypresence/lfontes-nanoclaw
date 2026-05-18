# Monorepo layout

The repo *is* the trust structure. Per-agent definitions live under
`agents/<name>/`; shared baseline lives under `shared/`; deploy
machinery lives under `deploy/`. The deploy pipeline slices the repo
per VM so each agent only ever sees its own subtree plus `shared/`.

## Directory tree

```
my-agents/                                ← single repo on my laptop
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
│   │   ├── Dockerfile                    ← FROM yourname/agent-host:1.4.2 + tools
│   │   ├── agent.config.toml             ← harness, channels, identity, version pin
│   │   └── overrides/
│   │       └── .claude/                  ← per-agent overlay on top of shared/.claude/
│   │           ├── CLAUDE.md             ← appended/overridden agent memory
│   │           └── skills/
│   │               └── personal-only/    ← skills only this agent gets
│   └── public-bot/
│       ├── Dockerfile
│       ├── agent.config.toml
│       └── overrides/
│           └── .claude/
│               └── CLAUDE.md             ← "you are the public bot, be careful" memory
├── deploy/                               ← NEVER reaches the VMs
│   ├── exe-config.toml                   ← exe.dev VM specs per agent
│   ├── bootstrap.sh                      ← one-shot per new VM
│   └── env-templates/
│       ├── personal-dm.env.example
│       └── public-bot.env.example
├── .github/
│   └── workflows/
│       └── deploy.yml                    ← on push: rsync the right subtree to the right VM
└── README.md                             ← operator handbook
```

## Trust slicing on deploy

The CI workflow does, per agent:

```bash
rsync -av --delete \
  --include='shared/***' \
  --include='agents/personal-dm/***' \
  --exclude='*' \
  ./ host@personal-dm.exe.dev:/srv/agent/
```

A VM holding `personal-dm` physically does not receive
`agents/public-bot/` or `deploy/`. If a compromised harness on
`personal-dm` tries to read sibling configs, the files aren't on the
disk. Repo structure isn't just *advisory* trust; it's enforced by
which bytes ever land where.

## `agent.config.toml` shape

```toml
[agent]
name            = "personal-dm"
identity        = "user:luis"            # canonical operator
framework_version = "1.4"                # semver, see framework-versioning.md

[harness]
kind            = "claude"               # "claude" | "codex" | "opencode"
dotfolder_path  = ".claude"              # what to mount as the harness's home
                                          # (defaults from kind, override if needed)
flags           = ["--dangerously-skip-permissions"]   # CLI flags

[channels]
adapters        = ["slack-dm", "dashboard"]

[channels.slack-dm]
workspace       = "T0LP"
allow_senders   = ["U_luis"]             # Slack user IDs that this agent listens to
```

The host reads this at boot. `harness.kind` selects the subprocess
binary and the dotfolder name to mount. `framework_version` lets the
framework refuse to start if the image is incompatible.

`identity` is the canonical sender identity that's allowed to talk to
this agent. Anyone else gets a "not authorized for this agent" reply.
For a personal bot, identity is a single user. For a public bot it'd
be `"*"` or a list.

## Override semantics

`shared/.claude/` and `agents/<name>/overrides/.claude/` get merged via
OverlayFS at runtime, with overrides on top. Practically:

- File in shared only → harness sees it.
- File in overrides only → harness sees it.
- File in both → harness sees the overrides version. (The shared
  version still exists on the lower layer but is shadowed.)
- File deleted in overrides → use OverlayFS whiteout (a `0:0` char
  device with the same name) to hide the shared version.

The discipline: prefer *additions* in `overrides/` over *replacements*.
If `overrides/.claude/CLAUDE.md` exists, it fully replaces
`shared/.claude/CLAUDE.md` — there's no append semantics. So large
shared memories should live in `shared/`, and per-agent memories
should be standalone files (or accept the full-replace cost).

Mounting details in `harness-mounting.md`.

## What goes in shared vs. agent-specific

Rule of thumb: anything I'd want **identical across all my agents**
goes in `shared/`. Anything that's **part of what makes this agent
different** goes in `agents/<name>/overrides/`.

Examples:

| Thing | Where | Why |
|-------|-------|-----|
| My general coding-style CLAUDE.md | `shared/` | Same across all agents. |
| "You are personal-dm, you have write access to my repos" | `agents/personal-dm/overrides/.claude/CLAUDE.md` | Per-agent identity. |
| `gh-research` skill | `shared/` | Useful everywhere. |
| `deploy-prod` skill | `agents/personal-dm/overrides/` | Only `personal-dm` should ever invoke this. |
| MCP servers everyone uses | `shared/.claude/mcp.json` | Common pool. |
| MCP server specific to one agent's tools | `agents/<name>/overrides/.claude/mcp.json` | Replaces the shared file entirely — copy what's needed from shared, add the agent-specific bits. |

## CI / deploy-on-push

`.github/workflows/deploy.yml` reads which agent's files changed in
the push and only redeploys those VMs. If `shared/` changed,
everything redeploys; if `agents/personal-dm/` changed, only
`personal-dm` redeploys; if only `deploy/` changed, nothing
redeploys (it's laptop-side).

Concrete deploy steps per agent that needs an update:

1. `rsync` the sliced subtree to the VM.
2. SSH + `docker pull` if `framework_version` changed.
3. `systemctl restart agent-host` to pick up changes.

Roll-forward only. No automatic rollback; if a deploy goes wrong, I
revert the commit and push.

## Operator UX

The monorepo is the entire surface. Adding an agent is:

1. `cp -r agents/personal-dm agents/work-bot`
2. Edit `agents/work-bot/agent.config.toml`.
3. Edit `agents/work-bot/Dockerfile` if the tool surface differs.
4. Run `deploy/bootstrap.sh work-bot` once to provision the VM.
5. `git push` — CI deploys.

Removing an agent:

1. `deploy/teardown.sh work-bot` to destroy the VM.
2. `rm -rf agents/work-bot`.
3. `git push`.

The whole lifecycle is reading and editing files in this repo.

## Open sub-questions

- **Mono vs. multi-repo.** Could `shared/` be a separate repo or a Git
  submodule. Lean monorepo: single push deploys all changes
  coherently, no submodule headaches.
- **Where do per-agent secrets go?** `deploy/env-templates/` has the
  *shape*; actual secrets live in a password manager and get written
  to `/etc/agent/env` during bootstrap, never in the repo.
- **Generated vs. hand-written `Dockerfile`.** Each agent's Dockerfile
  is short (3-10 lines) and hand-written. Generating from `agent.config.toml`
  would be doable but probably over-engineered.
- **Diff visibility.** A `make diff` that shows "what would actually
  deploy to which VM if I pushed now" is cheap to write and useful for
  catching trust-slicing mistakes early.
