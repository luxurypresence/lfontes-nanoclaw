# Distribution

The framework distributes as **one npm package plus a small set of
pre-built base images**. Same version number across all artifacts.
One release pipeline.

## The artifacts

| Artifact | What it is | Where it lives | Who pulls it |
|----------|------------|----------------|--------------|
| `@yourname/agent-host@X.Y.Z` | Node host code, CLI, Dockerfile templates, migrations | npm registry | User's monorepo pins it in `package.json`; VM installs it via `pnpm install`. |
| `yourname/agent-claude-base:X.Y.Z` | Linux base + Claude Code binary + framework shim | Docker registry | User's per-agent `Dockerfile` does `FROM`. |
| `yourname/agent-codex-base:X.Y.Z` | Linux base + Codex CLI + framework shim | Docker registry | Same, for Codex agents. |
| (future) `yourname/agent-opencode-base:X.Y.Z` | Linux base + OpenCode CLI + framework shim | Docker registry | For OpenCode agents. |

All four share the same `X.Y.Z` tag. Cutting `v1.4.2` publishes all
of them in lockstep.

## The framework repo

Lives separately from the user's monorepo. This is where the
framework's own source code lives — the npm package's source and
the base images' Dockerfiles.

```
framework-repo/                          ← @yourname/agent-host source
├── package.json                          ← npm package metadata
├── pnpm-lock.yaml
├── README.md                             ← framework developer docs
├── tsconfig.json
├── src/                                  ← host TypeScript
│   ├── index.ts                          ← `agent-host start` entry
│   ├── cli/                              ← CLI subcommands
│   │   ├── start.ts
│   │   ├── bootstrap.ts
│   │   ├── new-agent.ts
│   │   ├── migrate.ts
│   │   ├── cycle.ts
│   │   ├── doctor.ts
│   │   └── status.ts
│   ├── channels/                         ← Slack, Discord, dashboard adapters
│   ├── containers/                       ← docker exec / docker run wrappers
│   ├── db/                               ← SQLite layer
│   ├── proxy/                            ← logging proxy
│   └── dashboard/                        ← server-rendered HTML
├── bin/
│   └── agent-host                        ← CLI entry script (#!/usr/bin/env node)
├── templates/                            ← Dockerfile templates for users
│   ├── Dockerfile.claude.template
│   ├── Dockerfile.codex.template
│   └── agent.config.toml.example
├── migrations/                           ← numbered SQLite migrations
│   ├── 001_initial.sql
│   └── 002_audit_indexes.sql
├── container/                            ← base image source
│   ├── Dockerfile.claude-base            ← → yourname/agent-claude-base
│   ├── Dockerfile.codex-base             ← → yourname/agent-codex-base
│   └── shim/
│       ├── src/
│       │   └── index.ts                  ← the ~150 LOC container shim (Bun)
│       └── package.json
└── .github/
    └── workflows/
        ├── ci.yml                        ← test + typecheck on PR
        ├── release-npm.yml               ← on tag: publish npm
        └── release-base-images.yml       ← on tag: publish Docker images
```

## Release pipeline

A new release of the framework:

1. Land changes on `main`. CI runs tests, typecheck, lint.
2. Cut tag `v1.4.2`.
3. CI's two release workflows run in parallel:
   - `release-npm.yml`: `pnpm publish` → `@yourname/agent-host@1.4.2`.
   - `release-base-images.yml`: builds each `container/Dockerfile.*-base`,
     pushes to registry with tags `:1.4.2`, `:1.4`, `:1`, `:latest`.
4. CHANGELOG entry — semver discipline:
   - Patch: bug fixes, safe.
   - Minor: additive features, auto-migrations safe.
   - Major: breaking config or behavior; manual migration required.

The two release workflows are independent jobs but they're triggered
by the same tag, so version skew between npm and Docker artifacts
shouldn't happen. CI checks before publishing that both succeed
before either is marked released.

## How the user picks up updates

```bash
# In the monorepo, on the laptop:
pnpm update @yourname/agent-host

# package.json now says "^1.5.0" or whatever (pnpm bumps the caret-pinned range)
# pnpm-lock.yaml has the new exact version

git add package.json pnpm-lock.yaml
git commit -m "bump agent-host to 1.5.2"
git push
```

CI on push:
1. rsync the monorepo to VM.
2. SSH: `pnpm install --frozen-lockfile` — installs the new
   `@yourname/agent-host` and any transitive dep changes.
3. SSH: `agent-host migrate` — runs new SQLite migrations.
4. SSH: `agent-host doctor` — quick sanity check; refuses to proceed
   if base image versions on the VM don't match the npm package's
   expected version.
5. SSH: `docker pull yourname/agent-claude-base:1.5.2` (etc.) — pull
   matching base images.
6. SSH: for each agent, re-`docker build` if the base image tag in
   its Dockerfile changed.
7. SSH: `systemctl restart agent-host`.

The version check at step 4 catches the failure mode "user bumped
npm but forgot to bump the base image tag in their Dockerfile."
`agent-host doctor` reads the Dockerfiles and warns.

## The CLI surface

`@yourname/agent-host` exposes one binary: `agent-host`. Subcommands:

| Subcommand | Run by | What it does |
|------------|--------|--------------|
| `agent-host start` | systemd / operator manually on the VM | Boots the host process. Reads `host.config.toml`, opens `data/agent.db`, spawns agent containers per `agents/*/agent.config.toml`, starts dashboard, starts logging proxy. The default `npm start` script. |
| `agent-host bootstrap` | Operator from laptop (SSHs to VM) | Provisions a fresh VM. Installs Node, pnpm, Docker, creates `host` user, writes `/etc/agent/env` from a local secrets file, clones the monorepo, runs initial install + migrations. |
| `agent-host new-agent <name>` | Operator from laptop | Scaffolds `agents/<name>/` from templates. Copies `Dockerfile.claude.template` → `Dockerfile`, `agent.config.toml.example` → `agent.config.toml`, creates empty `overrides/.claude/`. |
| `agent-host migrate` | Run automatically by CI deploy; also runnable manually | Runs pending SQLite migrations from the npm package's `migrations/` directory. Idempotent. |
| `agent-host cycle <name>` | Operator manually or via dashboard | Kill + respawn the container for one agent. Used after a Dockerfile change or to recover from a wedged harness. |
| `agent-host status` | Operator manually | One-line per agent: container status, last activity, last error. |
| `agent-host doctor` | Run automatically by CI deploy; also operator manually | Diagnostic check: Docker daemon up, `/etc/agent/env` exists with right perms, base images present at matching version, agents' Dockerfiles parse, etc. |
| `agent-host stop` | systemd / operator manually | Graceful shutdown: stop accepting webhooks, drain in-flight, stop containers, exit. |
| `agent-host dashboard` | Operator manually | Print the dashboard URL. Cosmetic. |

Optional later:
- `agent-host logs <name>` — wrap `docker logs` for an agent.
- `agent-host shell <name>` — wrap `docker exec -it sh` for an
  agent (debugging only).
- `agent-host audit <query>` — quick CLI access to the audit log.

## Pre-built base images: what's in them

Each `yourname/agent-<harness>-base:X.Y.Z` image contains:

- A small Linux base (Debian slim or Alpine, ~50MB).
- Bun runtime (for the shim).
- The harness binary at a pinned version.
- The framework shim binary at `/usr/local/bin/agent-container`.
- A non-root user `agent` with a home at `/home/agent/`.
- `ENTRYPOINT ["/usr/local/bin/agent-container"]` declared.

What's NOT in them:

- The host code (lives on the VM, not in containers).
- The user's `.claude/` (mounted at runtime).
- Tool installs like `gh`, `vercel` (added by the per-agent
  Dockerfile).
- Credentials (injected at `docker run` time via env).

## Why ship a base image AND a Dockerfile template

Two operator personas:

- **"Just works":** doesn't want to think about the Dockerfile, takes
  the template as-is. Their `agents/<name>/Dockerfile` is `FROM
  yourname/agent-claude-base:X.Y.Z` and one or two `RUN apt-get
  install` lines. They never touch the entrypoint, never think about
  the shim.
- **"Full control":** wants to build their own base. Can ignore our
  base image and roll their own — but must include the shim binary
  and the right entrypoint. The framework's docs spell out the
  contract: "your image must run `/usr/local/bin/agent-container` as
  the entrypoint, with the harness binary in `$PATH`."

The pre-built base covers ~95% of cases. The contract documentation
covers the rest.

## Entrypoint enforcement (belt-and-suspenders)

Even if a user accidentally overrides `ENTRYPOINT` in their
Dockerfile (`ENTRYPOINT ["bash"]` from a copy-paste), the host's
`docker run` invocation explicitly sets `--entrypoint`:

```bash
docker run --rm -i --name agent-personal-dm \
  --entrypoint /usr/local/bin/agent-container \
  -v /srv/agent/data/merged/personal-dm/.claude:/home/agent/.claude:ro \
  -v /srv/agent/data/sessions/personal-dm/projects:/home/agent/.claude/projects \
  -e ANTHROPIC_API_KEY \
  -e GH_TOKEN_RW \
  --memory=2g --cpus=1.0 \
  yourname-agent-personal-dm:latest \
  --harness claude
```

`--entrypoint` overrides whatever the image says. The framework
contract is enforced regardless of user error.

## Versioning rules (recap)

`package.json` pins the npm package; per-agent `Dockerfile`s pin the
base image. These should match. If they don't:

| Situation | Behavior |
|-----------|----------|
| npm package version `X.Y.Z` matches all agents' base image versions | Boot normally. |
| Agents on older base image (e.g., npm at 1.5.0, Dockerfile FROM 1.4.2) | Warn at `agent-host start`, allow boot if within same major. Suggest rebuild. |
| Agents on newer base image (npm at 1.4.0, Dockerfile FROM 1.5.0) | Refuse — the host is too old to drive the newer shim's protocol. |
| Major mismatch in either direction | Refuse. Run `agent-host migrate` first. |

The version check is part of `agent-host doctor` and runs on every
`agent-host start`.

## Open sub-questions

- **Registry choice.** GitHub Container Registry (ghcr.io) is free
  for public repos and integrates with the framework's GitHub
  workflows. Docker Hub is more universally pull-able. Pick one and
  document.
- **Beta channel.** A `:next` or `:beta` tag for pre-release base
  images, pinnable in Dockerfile for early adopters. Cheap to add.
- **Air-gapped install.** If anyone ever wants to run this offline,
  they need to mirror npm + Docker registry locally. Out of scope.
- **Renovate / Dependabot integration.** Standard. The user's monorepo
  enables Dependabot for `@yourname/agent-host`; PRs land
  automatically when new versions ship.
- **Auto-update vs. opt-in.** Opt-in. Operator decides when to bump.
  Auto-update on a personal install is the kind of thing that wakes
  you up at 3am.
