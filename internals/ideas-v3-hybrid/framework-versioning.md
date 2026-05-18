# Framework versioning

One version number, three artifacts. `@yourname/agent-host@1.4.2` on
npm and `yourname/agent-{claude,codex,opencode}-base:1.4.2` on the
Docker registry, all cut from the same Git tag. The user pins one
version (npm package); their Dockerfiles `FROM` matching base image
tags.

## The version number

Semver, applied to the framework as a whole:

| Level | What changes |
|-------|--------------|
| **Patch** (`1.4.2`) | Bug fixes, internal refactors. Safe to bump without re-reading docs. |
| **Minor** (`1.4.0` → `1.5.0`) | Additive features. New CLI subcommands. New NDJSON event types (the shim emits them, the host ignores unknown ones). Auto-migrations run cleanly. |
| **Major** (`1.x` → `2.0.0`) | Breaking changes to `agent.config.toml`, the NDJSON protocol, the shim contract, or the user's monorepo structure. Manual migration required. |

The discipline that holds this together: **agent.config.toml shape,
the NDJSON protocol, and the entrypoint contract are public
surfaces. Internal SQLite schema is private.** Bumping the SQLite
schema is a minor (auto-migration); changing `agent.config.toml`
keys is a major.

## What the user pins

In `package.json`:

```json
{
  "dependencies": {
    "@yourname/agent-host": "^1.4.0"
  }
}
```

`^1.4.0` means "any 1.x ≥ 1.4.0." pnpm-lock.yaml has the exact
version installed. The lockfile is what CI installs from
(`pnpm install --frozen-lockfile`).

In `agents/<name>/Dockerfile`:

```dockerfile
FROM yourname/agent-claude-base:1.4.2
```

Pinned to the exact tag. The user can also use `:1.4` (latest 1.4.x)
or `:1` (latest 1.x), but pinning patch is safer because Docker
doesn't have a lockfile.

## Version compatibility rules

At `agent-host start`, the host checks:

| Check | Behavior on mismatch |
|-------|---------------------|
| Host (npm package) major matches base images major across all agents | Refuse to start if any agent's base image is on a different major. Error: `"agent <name>'s base image is 2.x; framework is 1.x — bump one or the other."` |
| Host minor ≥ base image minor (for every agent) | Allow, warn. The host can drive older shims (backward compat). |
| Host minor < base image minor (for any agent) | Refuse. The host can't drive newer shims (forward compat is the user's responsibility). Error: `"bump @yourname/agent-host to >= 1.5 or rebuild agent <name>'s image with :1.4.x"`. |
| Host patch vs base image patch | Allow any combination. Patches are safe within minor. |
| `agent-host doctor` | Reads package.json + parses every `agents/*/Dockerfile` to verify these rules; prints the matrix. |

These rules are intentionally strict on majors (the protocol may
have changed) and lenient on patches (bug fixes don't break
anything).

## Release pipeline

A new release of the framework:

1. Land changes on `main`. CI runs unit tests, typecheck, lint,
   protocol compatibility tests (covered in
   `investigations/02-container-shim-protocol.md`).
2. Cut tag `v1.4.2` in the framework repo.
3. CI runs two parallel workflows:
   - `release-npm.yml`: bumps `package.json`'s version, builds TS,
     `pnpm publish` → `@yourname/agent-host@1.4.2`.
   - `release-base-images.yml`: builds each
     `container/Dockerfile.<harness>-base` with `--build-arg
     VERSION=1.4.2`, pushes with tags `:1.4.2`, `:1.4`, `:1`,
     `:latest`.
4. CHANGELOG entry hand-written between cut + push.

A failed release in either pipeline halts: a published-on-npm-but-
not-on-docker version is worse than no version. CI gates on both
succeeding before declaring "released."

## Migrations

Two kinds, two behaviors:

### SQLite schema migrations

Run automatically on `agent-host start` (and explicitly on
`agent-host migrate`). Numbered SQL files in the npm package's
`migrations/` directory:

```
node_modules/@yourname/agent-host/migrations/
├── 001_initial.sql
├── 002_audit_indexes.sql
├── 003_add_http_log.sql
└── ...
```

Single transaction per migration. Idempotent (records applied
versions in `schema_migrations`). Roll-forward only — if a
migration is buggy, fix-forward with a new migration.

Down migrations exist when feasible (drop column, remove index) but
the framework doesn't auto-run them. Rollback to a previous npm
version means pinning the previous version and re-deploying;
the previous migration set is what runs.

### Config / `agent.config.toml` migrations

Only run when invoked manually:

```bash
pnpm agent-host migrate --config
```

Reads every `agents/*/agent.config.toml`, applies any
shape-translation rules baked into the current framework version,
prints a unified diff per file, asks the operator to apply (`git
apply` or hand-edit).

Why manual: config lives in Git. The framework doesn't auto-rewrite
files the operator maintains. The operator sees what would change
and decides.

Common cases:
- Renamed key: framework's migration prints `- old_key = ...` `+
  new_key = ...`.
- Removed key: prints `- removed_key = ...`.
- New required key: prints `+ new_key = "<default>"`.

The migration tool is idempotent. Re-running on already-migrated
files emits an empty diff.

## Per-agent versioning (and what it doesn't get you)

The user's Dockerfile is per-agent. Different agents can have
different `FROM yourname/agent-<harness>-base:X.Y.Z` tags:

```dockerfile
# agents/personal-dm/Dockerfile
FROM yourname/agent-claude-base:1.4.2
RUN apt-get install -y gh vercel

# agents/public-bot/Dockerfile
FROM yourname/agent-claude-base:1.5.0   # ← different version
RUN apt-get install -y gh
```

This works, **as long as** both versions are compatible with the
host's version (per the rules above). You can:

- Bump one agent to a newer base image first to test the upgrade.
- Hold an agent on an older base image if a newer one has a
  regression specific to that agent's tool surface.

You **cannot**:

- Have one agent on a different major than the host.
- Run a host upgrade that breaks an agent's pinned older base image.

The discipline: the framework treats per-agent base image tags as a
*deploy ordering knob*, not a "different agents run different
frameworks" model. The host is shared.

## What about per-agent harness versioning

The harness binary lives in the base image. Bumping Claude Code from
1.2 to 1.3 means rebuilding `yourname/agent-claude-base` with the
new binary — which is a framework release (a minor or patch). All
agents on `yourname/agent-claude-base:1.5.0` get the same Claude
Code version.

If an operator wants pinned-different harness versions per agent,
they roll their own base image:

```dockerfile
# Operator's custom base for personal-dm
FROM yourname/agent-claude-base:1.5.0 AS framework
FROM debian:slim
COPY --from=framework /usr/local/bin/agent-container /usr/local/bin/
RUN curl -sSL https://get.claude.com/install.sh | sh -s -- --version 1.2.3
ENTRYPOINT ["/usr/local/bin/agent-container"]
```

Out-of-the-box: all agents on one VM share one harness version
per harness kind. Roll your own if you need otherwise.

## A breaking-change story (concrete)

Suppose `v2.0.0` renames `agent.config.toml`'s `[harness].flags` →
`[harness].args`. The user has half a dozen agents.

1. Tag `v2.0.0` is cut. CI publishes npm + base images.
2. Operator updates `package.json`:

   ```bash
   pnpm update @yourname/agent-host@^2.0.0
   ```

3. Operator pushes. CI deploys. `agent-host start` refuses:

   ```
   refusing to start: agents/personal-dm/agent.config.toml has [harness].flags,
   expected [harness].args. Run `pnpm agent-host migrate --config`.
   ```

4. Operator runs locally:

   ```bash
   pnpm agent-host migrate --config
   ```

   Output:

   ```
   --- agents/personal-dm/agent.config.toml
   +++ agents/personal-dm/agent.config.toml (after migration)
   @@ -3,7 +3,7 @@
    [harness]
    kind = "claude"
   -flags = ["--dangerously-skip-permissions"]
   +args  = ["--dangerously-skip-permissions"]

   Apply this diff? [Y/n] y

   --- agents/public-bot/agent.config.toml
   ...
   ```

5. Operator reviews, applies. Bumps base image tags in each
   `Dockerfile` to `2.0.0`. Commits, pushes.
6. CI deploys. `agent-host start` succeeds.

End-to-end ~5 minutes of operator time for a major bump.

## Refusing to break gratuitously

The discipline that keeps versioning sane:

- `agent.config.toml` keys are a public surface. Renames go through
  a major bump and a migration tool entry.
- The NDJSON protocol between host and shim is a public surface.
  New event types are additive (minor); renamed types are breaking
  (major).
- The base image's `ENTRYPOINT` and the `/usr/local/bin/agent-container`
  path are part of the contract. Don't move them.
- Skills, MCP servers, CLAUDE.md format — *not* the framework's
  surface. Those are the harness's surface. The framework reads what
  the harness reads; it doesn't impose schema.

If a proposed change asks the operator to re-do something they
already had working, ask whether the breaking change is actually
worth it. Usually it isn't.

## Open sub-questions

- **Beta channel.** `:next` or `:beta` tags on Docker; `@yourname/agent-host@1.5.0-beta.1`
  on npm. Operator opts in by pinning the beta tag.
- **Auto-bump tooling.** Renovate / Dependabot integration in the
  user's monorepo. Standard.
- **Renaming the npm package.** If the project name ever changes,
  the user's `package.json` needs a one-line edit. Document.
- **Rollback semantics.** Pin previous version, redeploy. SQLite
  schema migrations may need down-migration in this case; ship
  reversible migrations where feasible.
- **Migration tool dry-run.** Default behavior of `agent-host
  migrate --config` should print the diff and require explicit
  confirmation. Add `--apply` flag for non-interactive use.
