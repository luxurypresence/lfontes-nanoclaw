# Harness mounting

How the user's `.claude/` (or `.codex/`, or `.opencode/`) gets into a
container in a way that:

1. The harness sees an apparently-normal home directory.
2. The framework owns nothing inside it (principle 3).
3. The harness can write session/history files freely.
4. Shared baseline + per-agent overrides are composable.
5. No OverlayFS, no kernel feature dependency.

The trick: **merge happens at deploy time, not at runtime.** Two
plain bind mounts at `docker run` time. That's it.

## The deploy-time merge

The deploy pipeline does, per agent, on the VM:

```bash
# Per agent, into data/merged/<name>/.claude/
rm -rf /srv/agent/data/merged/personal-dm/.claude/
mkdir -p /srv/agent/data/merged/personal-dm/.claude/

rsync -a /srv/agent/shared/.claude/   /srv/agent/data/merged/personal-dm/.claude/
rsync -a /srv/agent/agents/personal-dm/overrides/.claude/ /srv/agent/data/merged/personal-dm/.claude/
```

After these two commands:

- Files in shared only → exist in `merged/<name>/.claude/`.
- Files in overrides only → exist there too.
- Files in both → the overrides version wins (rsync runs second).

`data/merged/<name>/.claude/` is the unified view. It lives on the
VM under `data/` (gitignored). Re-run the merge after every deploy
that changes either `shared/` or `agents/<name>/overrides/`.

The deploy-time merge runs:
- During `agent-host bootstrap` for each agent.
- During CI deploy when `shared/` or `agents/<name>/overrides/`
  changed.
- On `agent-host new-agent` after scaffolding.

## The two container mounts

```bash
docker run --rm -i --name agent-personal-dm \
  --entrypoint /usr/local/bin/agent-container \
  -v /srv/agent/data/merged/personal-dm/.claude:/home/agent/.claude:ro \
  -v /srv/agent/data/sessions/personal-dm/projects:/home/agent/.claude/projects \
  -e ANTHROPIC_API_KEY \
  ...
  yourname-agent-personal-dm:latest --harness claude
```

Two bind mounts compose into the harness's `~/.claude/`:

| Container path | Host path | Mode | What |
|----------------|-----------|------|------|
| `/home/agent/.claude/` | `/srv/agent/data/merged/personal-dm/.claude/` | `ro` | Merged shared + overrides. Read-only. |
| `/home/agent/.claude/projects/` | `/srv/agent/data/sessions/personal-dm/projects/` | `rw` | Harness session JSONL files. Writable, survives container restart. |

The second mount overlays the `projects/` subdirectory with a
writable bind mount. The harness sees one `~/.claude/` tree with
most of it read-only and `projects/` writable. No OverlayFS, no
whiteouts, no `workdir`.

What the harness sees:

```
/home/agent/.claude/
├── CLAUDE.md                ← from merged/, RO
├── settings.json            ← from merged/, RO
├── skills/                  ← from merged/, RO
├── commands/                ← from merged/, RO
├── agents/                  ← from merged/, RO (Claude Code subagents)
├── mcp.json                 ← from merged/, RO
└── projects/                ← writable bind mount from data/sessions/<name>/projects/
    └── -workspace/
        └── <session-id>.jsonl
```

The harness writes session state to `projects/`. Everything else is
read-only. If a skill tries to write to `~/.claude/skills/foo.md`,
it gets `EROFS` — by design, because that's the framework's
read-only contract for the user's config.

## What happens if the harness wants to write to a "definitional" file?

It gets a write error. The framework's stance: **the user's
config in shared/ + overrides/ is the source of truth.** A harness
writing to its own `~/.claude/skills/foo.md` would mean drifting
from Git. We refuse it structurally.

If a future use case requires the harness to write to non-projects
paths — for example, Claude Code auto-updating a settings cache —
the framework adds another writable bind mount for the specific
subpath. No general "writable upper layer" the way OverlayFS would
provide.

## Multi-harness support

Different harnesses look in different dotfolder paths:

| Harness | Dotfolder | Mount target |
|---------|-----------|--------------|
| Claude Code | `~/.claude/` | `/home/agent/.claude/` |
| Codex | `~/.codex/` | `/home/agent/.codex/` |
| OpenCode | `~/.opencode/` | `/home/agent/.opencode/` |

The base image declares the right `agent` user with the right home
directory. The container shim reads `--harness <kind>` from its args
(supplied by the host) and knows which dotfolder is in play.

For an agent using Codex, `shared/` and `overrides/` would contain
`.codex/` instead of (or in addition to) `.claude/`. The host's
deploy-time merge logic picks the right subpath based on
`agent.config.toml`'s `harness.kind`.

## Importing the user's existing `~/.claude/`

The pitch: "bring your existing Claude Code setup to a VM in one
command." The implementation:

```bash
# On the laptop, in the monorepo root:
pnpm agent-host import-dotfolder ~/.claude shared/.claude
```

Which:

1. Copies `~/.claude/` to `shared/.claude/`.
2. Refuses to copy `~/.claude/projects/` (session history; lives on
   the VM under `data/sessions/`, not in the repo).
3. Refuses to copy `~/.claude/.credentials.json` and anything
   matching secret-shaped patterns (`sk-*`, `ghp_*`, `xoxb-*` in
   `.env`-like files). Emits a warning listing what was skipped.
4. Lets the user `git add shared/.claude/` and commit.

Notice this does **not** translate anything. The user's existing
`.claude/` is the format. The framework reads what Claude Code reads.

Multi-harness extension: `pnpm agent-host import-dotfolder ~/.codex
shared/.codex`.

## Session JSONL across container lifecycle

The Claude Agent SDK persists every session at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. In the
container, `cwd` is `/workspace` (set by the shim or the base
image), so encoded-cwd is `-workspace`.

Session files live at:

- **Inside container:** `/home/agent/.claude/projects/-workspace/<id>.jsonl`
- **On VM:** `/srv/agent/data/sessions/personal-dm/projects/-workspace/<id>.jsonl`

Across container restarts:

- `agent-host cycle personal-dm` (kill + respawn): session files
  untouched. Harness can resume by ID via `--resume`.
- VM reboot: bind mounts re-attach on container start; session files
  intact.
- VM destroyed: session files gone. Agent comes back from `git clone`
  + bootstrap with no prior conversations.

For backup, snapshot `data/sessions/` to off-VM storage. Cheap to add.

## Workspace / cwd convention

`/workspace` is the cwd inside every container. Stable per agent.
The harness sees `cwd=/workspace`, which gives a stable encoded-cwd
for session bucketing.

If the operator wants project-specific contexts within one agent
(e.g., different `cwd` per channel), that's a later feature. v1: one
workspace per agent.

## Permissions

The merged tree on the VM is owned by the `host` user (or whoever
ran the deploy). When mounted into the container, the `agent` user
inside the container needs read access.

Two ways:
1. **World-readable:** `chmod -R a+r data/merged/`. The shared
   config is mostly markdown and JSON — not sensitive. Trivial.
2. **UID/GID matching:** make `host` on the VM and `agent` in the
   container share a UID. More fiddly; not worth the precision at
   this scale.

Go with (1). `agent-host bootstrap` sets the right perms.

The session-writable bind mount needs to be writable by the
container's `agent` user. Easiest: `chmod 0777 data/sessions/`,
accept that the operator on the VM can also read it (they own the
VM anyway). For tighter isolation, make `data/sessions/<name>/`
owned by a different host-side UID per agent — but the threat model
(single tenant, audited config) doesn't justify it.

## Why not OverlayFS

We considered OverlayFS in `../ideas-v2-flat/harness-mounting.md`.
It works, but:

- Requires kernel OverlayFS support (universal but a dep).
- Three layers (lower / middle / upper), `workdir/`, whiteouts —
  more concepts than we need.
- Debugging "where did this file come from?" requires understanding
  OverlayFS internals.

Deploy-time merge gives the same end result (a unified tree at the
mount source) with:

- Zero kernel features used.
- Plain rsync — operators understand it.
- The merge output (`data/merged/<name>/.claude/`) is grep-able and
  inspectable. "What does the harness see?" is `ls
  /srv/agent/data/merged/personal-dm/.claude/`.

The cost: the merge runs at deploy time, not on every read. When
`shared/` changes, every agent's merge needs to re-run. That's one
rsync per agent — trivial, takes seconds.

## Open sub-questions

- **Symlinks across the two mounts.** If `~/.claude/CLAUDE.md`
  (read-only) refers to something in `~/.claude/projects/`
  (writable), Docker bind mounts handle this cleanly because they're
  separate mountpoints. Should "just work" but worth a smoke test.
- **What encoded-cwd does Claude Code actually use?** Verify against
  current source. v2-flat's investigation 02 covered this — the rule
  is "absolute path with non-alphanumerics replaced by `-`." Stable.
- **Concurrent sessions in one agent.** If Slack DM and dashboard
  chat both land in the same agent simultaneously, do they share a
  cwd (and thus session bucket) or get separate ones? Default: share.
  The harness handles interleaving. Revisit if it gets messy.
- **Periodic session JSONL cleanup.** They accumulate forever. A
  cron task that deletes JSONLs older than N days (and emits an
  audit event) keeps `data/sessions/` in check. Not v1.
- **Read-only enforcement on the bind mount.** Docker's `:ro` flag
  is real. Confirm the harness gets `EROFS` (not a confusing
  alternative error) when it tries to write to read-only paths.
