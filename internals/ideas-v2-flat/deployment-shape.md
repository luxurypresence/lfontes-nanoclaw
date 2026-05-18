# Deployment shape

One VM per trust zone. Cheap, isolated, swappable. exe.dev for v1
because I already know it; deploy/ folder keeps platform-specific
bits bounded so Hetzner/Fly/whatever stays a port, not a rewrite.

## What lives where

| Surface | Where | Lifecycle |
|---------|-------|-----------|
| Framework code | Docker image `yourname/agent-host:X.Y.Z` in a registry | Versioned independently. Published once, pulled by many VMs. |
| Per-agent definition (Dockerfile, config, overrides) | Monorepo `agents/<name>/` subtree on my laptop + GitHub | Source of truth in Git. Deploys to one VM. |
| Shared dotfolders | Monorepo `shared/.claude/` (and friends) | Source of truth in Git. Mounted read-only on every VM. |
| Deploy machinery | Monorepo `deploy/` | Never reaches the VMs. Lives on laptop + CI runner. |
| Live agent state | VM persistent disk: `~agent/.claude/projects/`, SQLite DB at `/var/agent/data.db`, audit log | Ephemeral but durable across reboots. Regeneratable from repo + `.env` if lost. |
| Bootstrap creds | VM `/etc/agent/env` (root:root, 0600) | Manually provisioned during VM bootstrap. Rotated by editing + restarting. |

The hard line: anything in the *repo* is reproducible; anything on a
*VM* is replaceable. Lose a VM, `git clone && docker pull && bootstrap`
and you're back to the same agent.

## Per-VM provisioning sketch

A new agent goes live in roughly this order:

1. Add `agents/<new-name>/` to the monorepo with a `Dockerfile`,
   `agent.config.toml`, and any `overrides/`. Commit.
2. Run `deploy/bootstrap.sh <new-name>` from laptop. This:
   - Creates a VM on exe.dev with the right size and region.
   - Writes `/etc/agent/env` from a local `.env.<new-name>` (the only
     secrets material that never enters the repo).
   - Creates the two Unix users (`host`, `agent`).
   - Installs Docker (or the base packages) on the VM.
   - Pulls the framework image at the version pinned in
     `agent.config.toml`.
   - Configures the OverlayFS mount points for the harness dotfolder.
   - Configures HTTPS terminator + dashboard auth.
   - Starts the host process under systemd.
3. CI's deploy-on-push workflow rsync's `agents/<new-name>/` and
   `shared/` to the VM and restarts the host.

The whole point of `deploy/` is that step 2 is a script, not a
runbook. If I forget the exact sequence in six months, the script
remembers.

## exe.dev specifics (for v1)

- Single VM type, sized for personal use. ~2 vCPU / 4 GB / 25 GB is
  more than enough for one host + one harness subprocess.
- HTTPS via exe.dev's built-in TLS terminator. Dashboard auth lives
  inside the framework, not at the proxy.
- VM persistent disk holds:
  - `/var/agent/data.db` — SQLite (audit log, queue, scheduled tasks).
  - `~agent/.claude/projects/` — harness session JSONL files.
  - `/etc/agent/env` — bootstrap credentials.

Anything else can be wiped between deploys.

## Cost reality

Two VMs is two bills. Three is three. The principle says "if you need
another trust profile, spin up another VM," and that has a real cost
curve. At my projected scale (N ≤ 3 for the foreseeable future), this
is fine. If it ever becomes 5+, the math gets less friendly and I'd
revisit consolidating low-risk agents back onto one VM.

The savings from "no Docker-orchestration code, no per-zone Dockerfile
tree, no shared bridge network" pay for the second VM's bill many times
over in developer time. The savings stop scaling at some N.

## Portability to Hetzner / Fly / etc.

Everything in `deploy/` is exe.dev-specific. Everything outside it is
not. A port to Hetzner is:

1. New `deploy/hetzner-config.toml` and `deploy/hetzner-bootstrap.sh`.
2. Same framework image, same `agents/<name>/` layout, same
   `agent.config.toml`, same OverlayFS approach.
3. Different HTTPS terminator wiring (Hetzner doesn't terminate for
   you; need Caddy or Traefik on the VM).

Bounded work, not a rewrite. The discipline that keeps it bounded is
"never let exe.dev-isms leak into framework code or agent definitions."

## Failure modes and recovery

| What breaks | Recovery |
|-------------|----------|
| VM disk corruption | Provision a new VM, deploy the same agent, `.claude/projects/` history is gone but the agent is back. |
| Bad framework image | Pin previous version in `agent.config.toml`, redeploy. Per-agent versioning means I can roll back one without touching the other. |
| Lost `/etc/agent/env` | Restore from password manager / personal secrets store. The only piece that requires out-of-band recovery. |
| Stale dashboard auth | Reset via VM SSH; dashboard auth is a hashed password in SQLite. |
| Slack token revoked | Update `.env`, restart host. No code change. |

## Open sub-questions

- **VM region / latency.** Does the harness's LLM API call need to
  come from a specific region for compliance/cost? Probably not at
  personal scale; revisit if I ever want multi-region.
- **Backup strategy.** SQLite + `~agent/.claude/projects/` are the
  only state worth backing up. A daily `restic` push to a separate
  bucket would cover both. Out of scope for the first cut; documented
  as "wanted before any real reliance."
- **Service manager.** systemd is the default; runit / s6 work too.
  The framework should be agnostic — `docker run` invocation that
  any supervisor can hold.
- **VM restart behavior.** On reboot, the host comes up via systemd,
  re-mounts OverlayFS, restarts the harness subprocess. The harness
  resumes from `~/.claude/projects/` if it can. See
  `investigations/02-overlayfs-sessions.md`.
