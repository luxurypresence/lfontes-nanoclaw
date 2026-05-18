# Harness mounting

How the user's `.claude/` (or `.codex/`, or `.opencode/`) gets onto a
VM in a way that:

1. The harness sees an apparently-normal home directory.
2. The framework owns nothing inside it (principle 3).
3. The harness can write to session/history files freely.
4. Shared baseline + per-agent overlay are composable.
5. Multiple harnesses can be supported with ~50 lines of adapter
   code each.

OverlayFS is the right tool. Three layers.

## The three-layer mount

```
                          (harness writes land here)
                              │
                              ▼
          ┌─────────────────────────────────────┐
upper:    │  /var/agent/upper/.claude/          │  ← VM persistent disk
          │  (writable; survives reboot)        │
          └─────────────────────────────────────┘
                              │
          ┌─────────────────────────────────────┐
middle:   │  /srv/agent/agents/personal-dm/     │  ← from repo, rsynced
          │  overrides/.claude/                 │     read-only
          │  (read-only; shadows shared/)       │
          └─────────────────────────────────────┘
                              │
          ┌─────────────────────────────────────┐
lower:    │  /srv/agent/shared/.claude/         │  ← from repo, rsynced
          │  (read-only baseline)               │     read-only
          └─────────────────────────────────────┘

                  All three union-mounted at:
                              │
                              ▼
                  /home/agent/.claude/
                  (what the harness actually sees)
```

OverlayFS reads top-down: upper > middle > lower. Writes always land in
upper. The harness sees one flat `~/.claude/` and never knows there are
layers.

## What ends up where

| Path inside `~/.claude/` | Layer of origin | Why |
|--------------------------|----------------|-----|
| `CLAUDE.md` (memory) | Lower or middle | Shared if generic; overridden per agent if needed. |
| `settings.json` | Lower or middle | Same. |
| `skills/<name>/` | Lower if shared, middle if per-agent | Composable. |
| `commands/<name>` | Lower or middle | Same. |
| `mcp.json` | Lower or middle | Same. |
| `projects/<encoded-cwd>/<session-id>.jsonl` | **Upper** | Written by the harness as conversations progress. Persists across reboots, gone if the upper layer is wiped. |
| `history` / scratch state | **Upper** | Same. |

The discipline: lower and middle are *definitional* (in Git, regenerable);
upper is *operational* (on the VM, ephemeral-but-durable). If
something appears only in upper that I'd want versioned, that's the
signal to lift it into the repo.

## systemd unit (sketch)

```ini
# /etc/systemd/system/agent-overlay.mount
[Unit]
Description=OverlayFS for harness dotfolder
RequiresMountsFor=/srv/agent /var/agent

[Mount]
What=overlay
Where=/home/agent/.claude
Type=overlay
Options=lowerdir=/srv/agent/agents/personal-dm/overrides/.claude:/srv/agent/shared/.claude,upperdir=/var/agent/upper/.claude,workdir=/var/agent/work/.claude
```

`lowerdir` is colon-separated, leftmost-first; OverlayFS treats the
leftmost path as the "upper" of the read-only stack. That gives the
middle-layer override the precedence we want over the shared lower.

systemd handles the rest: ordering before the host service starts,
unmounting cleanly on stop.

## Pluggability: harnesses beyond Claude Code

`agent.config.toml`'s `harness.kind` selects the dotfolder name. Each
supported harness needs:

- A known dotfolder name (`.claude`, `.codex`, `.opencode`).
- A subprocess invocation command.
- An NDJSON/streaming output parser (already covered by the v1
  subprocess scaffolding from `../ideas/harness-selection.md`).

Adding OpenCode support is roughly:

1. Add `.opencode/` to `shared/` (and to each agent's `overrides/`
   that wants it).
2. Add a case to the framework's harness dispatch (~30 lines): mount
   `.opencode` instead of `.claude`, spawn `opencode` instead of
   `claude`.
3. Add an NDJSON parser tuned to OpenCode's output (~20 lines if it
   follows a typical streaming JSON convention).

The OverlayFS layout is harness-agnostic by construction.

## What about multiple harnesses on one VM?

Out of scope. One agent on one VM uses one harness. If I want both a
Claude Code agent and a Codex agent, that's two agents → two VMs.

Reasoning: a single agent.config.toml has a single `harness.kind`.
Allowing two would multiply the subprocess and dotfolder management
surface for no real win — the simpler answer is to just have two
agents.

## Migration: the user's local `~/.claude/`

The pitch: "bring your existing Claude Code setup to a VM in one
command." The implementation:

```bash
# Run from the monorepo root, on the laptop
deploy/import-dotfolder.sh ~/.claude shared/.claude
```

Which:

1. Copies `~/.claude/` to `shared/.claude/`.
2. Refuses to copy `~/.claude/projects/` (session history; lives on
   each VM, not in the repo).
3. Refuses to copy plaintext credentials in `~/.claude/.credentials.json`
   or anything matching secret-shaped patterns; emits a warning
   listing what was skipped.
4. Lets the user `git add shared/.claude/` and commit.

Notice this does NOT translate anything (unlike the v1 importer). The
user's existing `.claude/` is the format. The framework reads what
Claude Code reads.

Multi-harness extension: `deploy/import-dotfolder.sh ~/.codex shared/.codex`.

## Session JSONL across reboots

The Claude Agent SDK persists every session at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Inside the VM
that lands on the upper layer at
`/var/agent/upper/.claude/projects/...`, on persistent disk.

On VM reboot:
- systemd remounts the OverlayFS.
- Upper layer is intact; sessions are right where the harness left
  them.
- Host process restarts, harness subprocess restarts, harness can
  resume by ID if the framework hands it one.

On VM destruction (disk gone):
- Upper layer is gone. Session history is gone.
- The agent comes back from `git clone + docker pull + bootstrap`
  with no prior conversations. Acceptable for a personal bot.

For more detail on the upper-layer semantics and pitfalls, see
`investigations/02-overlayfs-sessions.md`.

## Open sub-questions

- **Symlinks across layers.** OverlayFS handles them, but a symlink
  in lower pointing to a path that only exists in upper is a real
  edge case. Probably won't come up; flag if it does.
- **xattr / sparse files / hardlinks.** OverlayFS has well-known
  rough edges around these. Claude Code's `.claude/projects/` is
  vanilla files, so we're probably fine. Check before we add anything
  exotic.
- **Wiping the upper layer.** "Start fresh, keep my repo as-is" should
  be a one-liner: `systemctl stop agent-host && rm -rf /var/agent/upper/.claude/* && systemctl start agent-host`.
- **Snapshotting upper.** Periodic snapshots of `/var/agent/upper/` to
  an off-VM bucket would buy us conversation-history backup. Out of
  scope for v1.
- **Per-project workspaces.** Claude Code uses `cwd` to bucket projects.
  Do I want one workspace per channel (so DM history doesn't mix with
  bot-channel history), one workspace per agent (everything pooled),
  or one per logical project? Default: one workspace per agent, lives
  at `/workspace`. Revisit if it gets messy.
