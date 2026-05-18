# Deployment shape

One VM. exe.dev for v1 because I already know it; `deploy/` folder
keeps platform-specific bits bounded so Hetzner/Fly/whatever stays
a port, not a rewrite.

## What lives where

| Surface | Where | Lifecycle |
|---------|-------|-----------|
| Framework code (host) | `@yourname/agent-host` npm package | Versioned independently. `npm update` to upgrade. |
| Container base images | `yourname/agent-claude-base:X.Y.Z` (and codex, etc.) on registry | Same version as the npm package. Cut a tag → CI publishes both. |
| Per-agent definition (Dockerfile, config, overrides) | Monorepo `agents/<name>/` subtree | Source of truth in Git. |
| Shared dotfolders | Monorepo `shared/.claude/` (and friends) | Source of truth in Git. Merged into per-agent views at deploy. |
| Deploy machinery | Monorepo `deploy/` | Never copies onto the VM in a runtime path. Stays laptop / CI side. |
| Live state | VM `data/` (gitignored, under the monorepo) | SQLite, session JSONLs, logging proxy log. Survives VM reboot, gone if VM is destroyed. |
| Bootstrap creds | VM `/etc/agent/env` (root:root, 0600) | Out-of-band — never in the repo. Provisioned by `agent-host bootstrap`. |

Hard line: anything in the *repo* is reproducible from Git; anything
under `data/` on a *VM* is replaceable. Lose a VM, `git clone &&
pnpm install && agent-host bootstrap && agent-host start` is the
recovery path.

## VM topology

```
exe.dev VM (one)
├── /etc/agent/env                  ← bootstrap secrets (root:root 0600)
├── /srv/agent/                     ← rsynced monorepo (clone target)
│   ├── package.json                ← pins @yourname/agent-host
│   ├── shared/.claude/
│   ├── agents/
│   │   ├── personal-dm/
│   │   │   ├── Dockerfile
│   │   │   ├── agent.config.toml
│   │   │   └── overrides/.claude/
│   │   └── public-bot/...
│   ├── data/                       ← gitignored; framework state
│   │   ├── agent.db                ← SQLite
│   │   ├── sessions/<name>/        ← per-agent writable session volumes
│   │   ├── merged/<name>/.claude/  ← deploy-time merge output (mounted RO into containers)
│   │   └── proxy.log               ← logging proxy
│   └── deploy/
├── Node + pnpm                     ← installed by bootstrap
├── Docker daemon                   ← installed by bootstrap
├── systemd unit: agent-host.service
└── running:
    ├── agent-host (host Node process, uid=host)
    ├── docker container: agent-personal-dm
    └── docker container: agent-public-bot
```

The host process runs *outside* containers. Each agent runs *inside*
its own container. Host ↔ container is `docker exec -i` streaming
NDJSON.

## Bootstrap walkthrough

A fresh VM goes live in roughly this order. `agent-host bootstrap`
is the script; the operator runs it from their laptop, it SSHs into
the VM.

1. Provision the VM on exe.dev (size, region, OS image). Single
   shell call.
2. SSH in, install Docker (`apt-get install docker.io` or the
   Docker convenience script).
3. Install Node 20 + corepack + enable pnpm.
4. Create Unix users:
   - `host` (the framework process; reads `/etc/agent/env`).
   - The `agent` user inside each container is the container's own
     concern — not provisioned on the VM.
5. Write `/etc/agent/env` from the operator's local secrets file
   (out-of-band path; the operator supplies it).
6. Clone the operator's monorepo to `/srv/agent/`.
7. `pnpm install --frozen-lockfile` in `/srv/agent/`.
8. `agent-host migrate` (idempotent SQLite migration, creates
   `data/agent.db` if absent).
9. For each agent in `agents/`:
   - Run deploy-time merge: rsync `shared/.claude/` then
     `agents/<name>/overrides/.claude/` into
     `data/merged/<name>/.claude/`.
   - `docker build` the agent's image (uses the pinned base image
     from registry).
10. Install + enable the systemd unit `agent-host.service`.
11. Start the service. Host reads config, starts dashboard, spawns
    agent containers.

End state: dashboard at `https://<vm>.exe.dev/`, two containers
running, ready to receive Slack/Discord/dashboard messages.

Bootstrap is idempotent. Re-running on a configured VM no-ops the
already-done steps and refreshes anything that needs refreshing.

## Update flow

For framework updates:

```bash
# Laptop
npm update @yourname/agent-host             # in the monorepo's package.json
git add package.json pnpm-lock.yaml
git commit -m "bump agent-host to 1.5.2"
git push

# CI runs:
#   rsync to VM
#   ssh: pnpm install --frozen-lockfile
#   ssh: agent-host migrate
#   ssh: systemctl restart agent-host
# Host restarts; spawns fresh containers from current images
```

For agent-image updates (new tool, harness bump, etc.):

```bash
# Laptop — edit agents/personal-dm/Dockerfile
git commit && git push

# CI runs:
#   rsync to VM
#   ssh: docker build -t yourname-agent-personal-dm:latest /srv/agent/agents/personal-dm/
#   ssh: agent-host cycle personal-dm        # kill + respawn that container only
```

Per-agent container changes don't touch the host. Framework changes
restart the host (and therefore all containers).

## exe.dev specifics (for v1)

- One VM. ~2 vCPU / 8 GB / 25 GB is comfortable for one host + 2-3
  agent containers running real harnesses.
- HTTPS via exe.dev's built-in TLS terminator pointing at the host
  process's dashboard port.
- VM persistent disk holds `/srv/agent/` (including `data/`) and
  `/etc/agent/env`. Anything else can be wiped between provisions.

## Portability

Everything in `deploy/` is exe.dev-specific. Everything outside it
is not. A port to Hetzner is:

1. New `deploy/hetzner-config.toml` and `deploy/hetzner-bootstrap.sh`.
2. Same npm package, same agent base images, same `agents/<name>/`
   layout.
3. Different HTTPS terminator wiring (Hetzner doesn't terminate;
   need Caddy or Traefik on the VM).

Bounded work. The discipline that keeps it bounded: never let
exe.dev-isms leak into framework code or `agent.config.toml`.

## Failure modes

| What breaks | Recovery |
|-------------|----------|
| VM disk corruption | Provision new VM, `agent-host bootstrap`. Session history under `data/sessions/` is gone unless backed up. |
| Bad framework version | Pin previous in `package.json`, redeploy. All agents revert. |
| Bad single-agent image | `git revert` that agent's Dockerfile, redeploy; host cycles that container. |
| Lost `/etc/agent/env` | Restore from password manager. Only piece that needs out-of-band recovery. |
| Single container crashes | Host watchdog (heartbeat) detects, host cycles the container. |
| Host process crashes | systemd restarts it. Containers are still alive from prior `docker run`; host re-attaches via `docker exec` on restart. |
| Dashboard auth password lost | SSH in, `sqlite3 data/agent.db "UPDATE dashboard_users SET ..."`. |

## Cost

One VM. One bill. At exe.dev pricing for ~2 vCPU / 8 GB, this is
single-digit dollars per month. If load grows, scale the VM up
(more cores, more RAM) — still one bill. Adding agents doesn't
linearly add VMs.

If I ever need a second VM (one agent that truly needs hardware
isolation), the architecture supports it: that agent becomes a
single-agent v2-flat-style deployment, with its own host process
and dashboard. But that's a deliberate escape hatch, not the
default.

## Open sub-questions

- **Backup strategy.** `data/agent.db` and `data/sessions/` are the
  state worth backing up. A daily `restic` push to a separate bucket
  covers both. Out of scope for v1; documented as "wanted before
  any real reliance."
- **VM region / latency.** Single-region is fine at personal scale.
- **Service manager.** systemd is the default. The framework should
  be agnostic — `docker run` invocations any supervisor can hold.
- **Disk full mitigation.** `data/agent.db` and `data/sessions/`
  could grow. Monitor + alert at 80% disk. `agent-host doctor` checks
  disk pressure.
- **Container restart on framework upgrade.** Currently global
  (restart host = restart all containers). Could become rolling
  (host upgrades, then cycles containers one by one). Not v1.
