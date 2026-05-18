# Investigation: OverlayFS sessions and writable upper

## Question

`harness-mounting.md` proposes a three-layer OverlayFS mount: shared
lower (`/srv/agent/shared/.claude/`), per-agent middle
(`/srv/agent/agents/<name>/overrides/.claude/`), writable upper
(`/var/agent/upper/.claude/`). The harness writes session JSONL,
history, and scratch state to its `~/.claude/`; those writes land on
the upper layer on persistent disk.

The questions:

1. Does this actually work the way I want it to across realistic
   harness behavior?
2. What happens on VM reboot / OS update / disk full?
3. Are there OverlayFS rough edges that bite us at v1?

## What writes happen to `~/.claude/`?

Inventory, from Claude Code observed behavior:

| Path | Frequency | What |
|------|-----------|------|
| `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` | Append on every turn | The session transcript. |
| `~/.claude/projects/<encoded-cwd>/.metadata.json` (or similar) | Occasional | Project metadata. |
| `~/.claude/history` | Append on every CLI invocation | Local command history (TUI only; headless may skip). |
| `~/.claude/.credentials.json` | Rare (on auth) | Cached auth credentials. **Should never be present in our setup** — auth is injected via env. |
| `~/.claude/settings.local.json` | Rare | Per-machine settings (we configure via env, but the file may appear). |

Most volume is in `projects/`. Everything else is small.

## OverlayFS in three layers (mechanics)

OverlayFS supports an arbitrary number of `lowerdir` entries, in
left-to-right precedence. The kernel composes them into a single
view:

```
lowerdir=<middle>:<lower>
upperdir=<upper>
workdir=<work>
```

Reads check `upperdir` first, then `lowerdir` left-to-right. Writes
to any file copy it up to `upperdir` (copy-up on write). New files
land in `upperdir`. Deletes create a whiteout (`0:0` char device) in
`upperdir`.

`workdir` is the kernel's scratch space — must be on the same
filesystem as `upperdir`, must not be used for anything else.

## Behaviors we need to verify

### B1. `projects/*.jsonl` files are write-only-appends, not edits

If Claude Code only appends to a session JSONL (never truncates or
rewrites mid-file), copy-up happens once when the file is first
created on upper, and subsequent appends stay on upper. Cheap.

If Claude Code *rewrites* the file periodically (e.g., to compact),
that's also fine — still all on upper after the first copy-up.

**Verification needed:** Small smoke test — run a Claude Code session
in the layered mount, confirm that the JSONL ends up in `upper/`,
not duplicated in `lower/`, and that subsequent writes land in
`upper/` without copy-up storms.

### B2. New files created in `projects/` create new files in upper

This is OverlayFS's default behavior for new files in a directory
that exists in lower. Should "just work."

**Verification needed:** Confirm by running a fresh session and
checking that the new `<session-id>.jsonl` is in `upper/projects/<encoded-cwd>/`.

### B3. The harness doesn't try to write to files in lower that it
shouldn't

If a skill or MCP server tries to write to `~/.claude/skills/foo/SKILL.md`,
OverlayFS will copy it up to upper and the write succeeds — but now
upper has a diverged copy that no longer reflects the repo. This is
*usually fine* (the next deploy rsyncs over `shared/` again, the
upper stays as a local override), but it's a foot-gun if the operator
expects `shared/` to be authoritative.

**Mitigation:** mount lower as truly read-only at the OverlayFS
level (`lowerdir=...:..., ro`). OverlayFS already treats lower as
read-only structurally; explicit `ro` mount flags on the underlying
filesystems is belt-and-suspenders.

If the harness write to a lower file fails, it gets `EROFS` and
should handle it gracefully. **Verification needed:** what does
Claude Code do if a skill tries to write to a read-only path? Logs an
error and continues, presumably.

### B4. Whiteouts work for deletes the harness might try

A delete of a file that exists only in lower creates a whiteout in
upper. The file appears gone in the unified view. This is mainly a
concern if the harness deletes skills or MCP configs (it shouldn't,
but let's say a misbehaving `self-mod` tool does). Whiteouts persist
across reboots; they're regular files on upper.

**Cleanup:** `rm /var/agent/upper/.claude/<path>` removes a whiteout
and restores the lower file in the unified view.

### B5. Permissions and uid mapping

The agent process runs as uid `agent`. The shared files in lower were
rsynced as uid `host` (or whatever the deploy ran as). The harness
needs to read them.

**Mitigation:** make shared files world-readable (`chmod -R a+r
/srv/agent/shared/`). They're not sensitive — they're the user's
public-ish config. Or rsync as a user that's in a group `agent` is
also in. Operational detail; flag in `deploy/bootstrap.sh`.

### B6. systemd remount on boot

`/etc/systemd/system/agent-overlay.mount` orders the OverlayFS mount
before `agent-host.service`. On VM reboot:

1. Disk mounts in the usual order.
2. `agent-overlay.mount` activates, composing the three layers.
3. `agent-host.service` starts, spawns the harness, harness sees its
   `~/.claude/` as if nothing happened.

The session JSONLs the harness wrote pre-reboot are still on upper,
under their original paths. Resume by ID continues to work.

**Verification needed:** Power off / power on the VM, confirm session
state is intact and the harness can list previous projects.

## VM reboot specifics

| Scenario | Effect on upper layer |
|----------|----------------------|
| Soft reboot (systemctl reboot) | Upper layer intact. Sessions resume. |
| Crash / power loss | Upper layer intact (persistent disk). May need to clean up `workdir/` if mid-write, but OverlayFS handles this. |
| VM destroyed and recreated | Upper layer gone. Sessions gone. Agent restarts fresh from `git clone + docker pull`. |
| Disk full | Writes to upper fail with `ENOSPC`. Harness errors. Mitigation: monitor disk usage, alert at 80%. |
| OS update (kernel change) | OverlayFS module is stable; should be transparent. Worst case, may need to remount. |

## Backup / snapshot strategy

`/var/agent/upper/` is the entire "agent state worth keeping." A daily
snapshot to off-VM storage (S3-compatible bucket, restic, borg) gives
us point-in-time recovery for conversation history.

This is **out of scope for v1** but the structure makes it cheap to
add: one path, one cron, one bucket.

## OverlayFS rough edges worth knowing

1. **xattr handling.** OverlayFS may not pass extended attributes
   from lower transparently. We don't use them; flag if a tool
   reads/writes xattrs.
2. **Hardlinks across layers.** Don't work. Harness doesn't try.
3. **Files >> 2GB.** Copy-up cost is proportional to file size; large
   session JSONLs (which they may eventually become) take time to
   copy up on first write. After that, they live in upper. Probably
   fine but worth measuring.
4. **Concurrent writes from different processes.** If both the host
   and harness try to write the same file, OverlayFS doesn't add
   coordination — that's userspace. Doesn't matter for us; only the
   harness writes to `.claude/`.
5. **`/var/agent/work/` must be on the same filesystem as upper.**
   Easy to honor; both live under `/var/agent/`.

## Recommendation

**Adopt the three-layer mount as specified in `harness-mounting.md`.**
The mechanics work; the rough edges don't bite our use case. Verify
B1, B2, B3, and B6 with a one-hour smoke test before locking it in.

Belt-and-suspenders details:

- Mount underlying lower paths read-only (`ro`) in addition to
  OverlayFS treating them as lower.
- Make `shared/` files world-readable on the VM.
- Place `upper/`, `work/`, and `~agent/` all on `/var/agent/`
  (same filesystem) so OverlayFS is happy and a single backup
  covers everything.

## Open sub-questions

- **What's the right encoded-cwd?** Claude Code uses the absolute
  path of `cwd` with non-alphanumerics replaced by `-`. If we set
  `cwd=/workspace`, encoded-cwd is `-workspace`. Verify the actual
  encoding rule against current Claude Code source.
- **Resume by ID after process cycle.** Host spawns a fresh harness;
  if the operator wants to continue the previous conversation, the
  host needs to pass `--resume <session-id>`. Where does the session
  ID get stored between cycles? Probably in a `last_session_id`
  column on a `harness_state` table in SQLite. Flag for
  `host-responsibilities.md`.
- **Multiple concurrent sessions.** If the host accepts two channels
  (Slack DM + dashboard chat), does each get its own
  `encoded-cwd`/workspace, or do they share one? Default: share one
  workspace per agent; conversations interleave but the harness
  manages it. Revisit if it gets messy.
- **Snapshot vs. backup distinction.** Snapshot = LVM-style point in
  time on the VM; backup = off-VM. We want backup. Snapshot is a
  nice-to-have for fast local rollback. Decide later.
- **Periodic cleanup of old `projects/*.jsonl`.** They accumulate
  forever. A cron task that deletes JSONLs older than N days (and
  emits an audit event) keeps disk in check.
