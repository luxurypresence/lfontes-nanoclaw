# Framework versioning

The framework ships as a versioned Docker image. The user's repo
contains a Dockerfile that's `FROM yourname/agent-host:1.4.2` plus
tool installs. Upgrading is a tag bump and a redeploy.

## Image surface

`yourname/agent-host:X.Y.Z` contains:

- Node runtime + the host process source (compiled, frozen).
- SQLite + Honker (or just SQLite — see
  `investigations/01-honker-after-simplification.md`).
- The logging proxy.
- The dashboard server + static assets.
- Subprocess-management code.
- The migration CLI (`agent-host migrate <agent-dir>`).
- A default `ENTRYPOINT` that boots the host.

What it does **not** contain:

- Any harness binary (Claude Code, Codex, etc.). The user installs
  those in their own Dockerfile `FROM` the framework image.
- The user's `.claude/` or any agent definition. Those mount in at
  runtime from `/srv/agent/shared/` and `/srv/agent/agents/<name>/`.
- Any secrets. Bootstrap creds come from `/etc/agent/env`.

## Versioning rules (semver, enforced)

`agent.config.toml` has a `framework_version` field pinned to a
major.minor:

```toml
[agent]
framework_version = "1.4"
```

The framework image, on boot, reads this and:

| Situation | Behavior |
|-----------|----------|
| Image version matches `framework_version` exactly | Boot normally. |
| Image patch version is ahead of pin (`1.4.7` running `framework_version = "1.4"`) | Boot normally. Patches must be safe. |
| Image minor is ahead (`1.5.0` running `framework_version = "1.4"`) | Boot in **auto-migrate** mode: run SQLite schema migrations, emit a config diff for review (does not block boot), log a warning to the dashboard. Pin can stay at `1.4` until I confirm; then bump to `1.5`. |
| Image minor is behind (`1.3.0` running `framework_version = "1.4"`) | **Refuse to boot.** Log a hard error: "framework image too old, expected 1.4+, got 1.3.0." |
| Image major differs (`2.0.0` running `framework_version = "1.4"`) | **Refuse to boot.** Log: "incompatible major version, run `agent-host migrate /agent` before bumping the image tag." |

The pin in `agent.config.toml` is the source of truth for "what
version is this agent on right now." The image tag in the Dockerfile
is what *gets pulled*. They should match; mismatches are visible in
the dashboard's status panel.

## Per-agent independent versioning

Each `agents/<name>/Dockerfile` pins its own framework version. They
don't have to match:

```dockerfile
# agents/personal-dm/Dockerfile
FROM yourname/agent-host:1.4.2
RUN apt-get install -y gh vercel

# agents/public-bot/Dockerfile
FROM yourname/agent-host:1.5.1   # ← bumped to 1.5, personal-dm still on 1.4
RUN apt-get install -y gh
```

This is the staged-rollout primitive. Bump `public-bot` to 1.5,
watch it for a week, then bump `personal-dm`. If 1.5 breaks
`public-bot`, the blast radius is one agent.

`agent.config.toml`'s `framework_version` should also be bumped to
match — the Dockerfile gives you the binary; the config pin gives the
framework permission to act like 1.5. Bumping them together is the
norm; deliberately bumping only one is an escape hatch.

## Migrations

Two kinds of migrations, two behaviors:

| Kind | What | When it runs | Reviewability |
|------|------|--------------|---------------|
| **SQLite schema** | `ALTER TABLE`, new indexes, etc. | Automatically on framework boot, in a single transaction. Idempotent. | None — schema migrations are framework-internal and don't touch user data the user cares about. |
| **Config / dotfolder** | The shape of `agent.config.toml`, the OverlayFS layout, the channel adapter config. | **Only when invoked manually**: `docker run yourname/agent-host:X migrate /agent`. Emits a diff to stdout for review; the user applies it with `git apply` or by hand. | Full — every change is shown as a patch before it lands. |

The split exists because schema migrations should be invisible (they
serve the framework, not the user) and config migrations should be
loud (they touch files the user maintains in Git).

A breaking change to `agent.config.toml` between 1.x and 2.0 looks like:

1. User bumps the image tag in the Dockerfile to `2.0.0`.
2. Redeploys.
3. Framework refuses to boot: "major version mismatch."
4. User runs `docker run --rm -v $(pwd)/agents/personal-dm:/agent yourname/agent-host:2.0 migrate /agent`.
5. The migration tool prints a unified diff of the changes it would
   make to `agents/personal-dm/agent.config.toml`.
6. User reads the diff, applies it (`git apply` or hand-edit), commits.
7. User bumps `framework_version = "2.0"` in the config, commits.
8. Pushes; CI redeploys; framework boots.

The migration tool is idempotent: running it on an already-migrated
config emits an empty diff.

## Releases

The framework repo has its own release process, separate from the
user's monorepo:

1. PR lands on framework `main`.
2. Tag `vX.Y.Z`.
3. CI builds and pushes `yourname/agent-host:X.Y.Z` and
   `yourname/agent-host:X.Y` and `yourname/agent-host:X`.
4. CHANGELOG entry under semver discipline:
   - Patch: bug fixes, no behavior change, safe.
   - Minor: additive features, auto-migrations safe.
   - Major: breaking config or behavior; manual migration required.

The user pins to `X.Y` in their Dockerfile so patches flow through;
or pins to `X.Y.Z` if they want to bisect a regression.

## Image distribution

For personal use: GitHub Container Registry (`ghcr.io`) or Docker Hub.
Either is fine; the user's Dockerfile just specifies the path.
Authentication for pulls is a docker-login during VM bootstrap.

If this ever becomes a project other people use: the registry choice
is the operator's call; nothing in the framework cares.

## Refusing to break the user

The discipline that keeps versioning sane:

- `agent.config.toml` shape is a public surface. Renames, removed
  fields, changed semantics all require a major bump and a migration
  tool entry.
- Skills, MCP servers, CLAUDE.md format — *not* the framework's
  surface. Those are the harness's surface. The framework reads what
  the harness reads; it doesn't impose schema.
- The dashboard auth scheme, the SQLite schema, the channel adapter
  configs — all framework-internal. Schema migrations cover them.

If you find yourself writing a migration that asks the user to
re-do something they already had working, ask whether the breaking
change is actually worth it. Most of the time it isn't.

## Open sub-questions

- **Where do framework betas go?** A `yourname/agent-host:1.5.0-beta.1`
  tag pinnable in Dockerfile for early adopters. Bump-and-test on
  `public-bot` before stable release on both.
- **Auto-update vs. opt-in.** Lean opt-in (user bumps the tag).
  Auto-update on a personal install is the kind of thing that wakes
  you up at 3am.
- **Migration tool dry-run.** `agent-host migrate /agent --dry-run`
  should be the default behavior; `--apply` to actually edit files.
  Default-dry keeps people from getting bitten.
- **Rollback story.** Pin to the previous tag, redeploy. If the
  migration was schema-only and rolled forward, the rollback may need
  a counterpart down-migration. Framework SQLite schema migrations
  should ship with corresponding down-migrations to enable this; not
  doing so is a design tax I want to avoid.
