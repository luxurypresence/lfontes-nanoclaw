# Credentials

Host owns the credentials file; injects per-container subsets at
spawn time. No vault. Containers don't read the host's env file
because they can't (different filesystem). Same threat model
properties as v2-flat with stricter isolation between agents.

## The threat model (and what we're not defending against)

What we **are** defending against:

- A skill that accidentally reads `~/.env` or scans the filesystem
  and writes results to a log.
- A misbehaving MCP server in `agent-A` that scans its container's
  files looking for secrets — it finds only `agent-A`'s injected
  env, not `agent-B`'s.
- A buggy harness that prints `process.env` to the channel.

What we are **not** defending against:

- A deliberately malicious harness or MCP server. If you install
  one, it has the keys you injected. Don't install malicious
  binaries.
- A compromised host process. If `host` is owned, the game is over.
- Network egress / exfiltration. Out of scope.

Bar: **each container sees only its own credentials, never another
agent's. Credentials are not on disk in any path the harness can
read.**

## How credentials get from disk to harness

The chain:

```
Operator's password manager
        ↓ (bootstrap.sh, one-time)
/etc/agent/env on the VM      (root:root, 0600)
        ↓ (read at host startup, in-memory only)
Host process memory
        ↓ (filtered per-agent at docker run)
Per-container --env-file (tmpfs, deleted after spawn)
        ↓ (docker engine injects into container's process env)
Container's process env
        ↓ (the shim spawns harness with its own env)
Harness process.env
        ↓ (harness writes to subprocess env when spawning tools like `gh`)
Tool subprocess (gh, vercel, ...) sees credential
```

Credentials never touch disk in any container-readable path.

## `/etc/agent/env` shape

Owned `root:root`, mode `0600`. Only the `host` user can read it.

```
# Host-side framework credentials
DASHBOARD_AUTH_HASH=$argon2id$...
SLACK_BOT_TOKEN=xoxb-personal-dm-bot-token
SLACK_BOT_TOKEN_PUBLIC_BOT=xoxb-public-bot-token
SLACK_SIGNING_SECRET=...
DISCORD_BOT_TOKEN_PERSONAL_DM=...

# Anthropic / OpenAI / etc. — for harnesses
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...

# Tool credentials — to be injected into specific agent containers
GH_TOKEN_RW=ghp_...           ← only into personal-dm
GH_TOKEN_RO=ghp_...           ← only into public-bot
VERCEL_TOKEN=...              ← only into personal-dm
```

By convention, env-var names follow a discipline:

- **Framework-side names** (used by host code): no prefix
  (`SLACK_SIGNING_SECRET`).
- **Per-agent overrides** (used by host to pick which token to use
  per agent): `<NAME>_<AGENT_UPPER>`. e.g.,
  `SLACK_BOT_TOKEN_PUBLIC_BOT` would override `SLACK_BOT_TOKEN` for
  `public-bot`.
- **Tool credentials injected into containers** (used by harness):
  the names the tools expect — `GH_TOKEN`, `VERCEL_TOKEN`,
  `ANTHROPIC_API_KEY`.

## Per-container injection

Each agent's `agent.config.toml` declares which env vars get
injected:

```toml
[env]
inject = [
  "ANTHROPIC_API_KEY",
  "GH_TOKEN_RW => GH_TOKEN",       # rename: source name → target name
  "VERCEL_TOKEN",
]
```

The arrow syntax means "read `GH_TOKEN_RW` from `/etc/agent/env`,
inject into the container as `GH_TOKEN`." This lets us have
different PATs per agent under the same standard tool name. For
`public-bot`:

```toml
[env]
inject = [
  "ANTHROPIC_API_KEY",
  "GH_TOKEN_RO => GH_TOKEN",       # read-only PAT, same target var name
]
```

Same `gh` tool, different tokens, no per-agent skill code changes.

## Spawn-time mechanics

When the host spawns an agent container:

```ts
const agentEnv = pickAndRenameEnv(
  loadedEnv,                       // host's in-memory /etc/agent/env
  agentConfig.env.inject,          // injection list from agent.config.toml
);

// Write to a tmpfs file (so it's not in the host's filesystem persistently).
const tmpEnvPath = `/run/agent-host/env-${agentName}-${Date.now()}`;
await Bun.write(tmpEnvPath, formatEnvFile(agentEnv));

await Bun.spawn([
  "docker", "run", "--rm", "-i",
  "--name", `agent-${agentName}`,
  "--entrypoint", "/usr/local/bin/agent-container",
  "--env-file", tmpEnvPath,
  ...mountArgs,
  imageName,
  "--harness", agentConfig.harness.kind,
]);

// Delete tmpfs file after docker has read it.
await unlink(tmpEnvPath);
```

`/run/` is tmpfs (RAM-backed) on Linux. The env file lives there
for milliseconds — long enough for `docker run` to read, then gone.
The file is `root:root 0600` while it exists; only root can read it.
Defense-in-depth.

(Alternative: pass `-e KEY=value` flags on the command line. This
puts secrets in `/proc/<pid>/cmdline` for a moment, which is
readable by other processes. The `--env-file` approach avoids that.)

## Per-agent credential isolation (concrete)

`personal-dm`'s container has:
- `ANTHROPIC_API_KEY`
- `GH_TOKEN=<rw-pat>`
- `VERCEL_TOKEN`

`public-bot`'s container has:
- `ANTHROPIC_API_KEY`
- `GH_TOKEN=<ro-pat>`

If `public-bot`'s harness runs `printenv`, it sees only those two
env vars. The rw-pat doesn't exist in its process space. Container
filesystem isolation means it can't `cat /etc/agent/env` either —
that file isn't on its filesystem.

If a skill on `public-bot` tries `find / -name '.env'`, it finds
nothing relevant in its container.

## Logging proxy (observability, not credential substitution)

The framework runs a ~50-LOC HTTP forward proxy on the host. The
host sets `HTTP_PROXY`/`HTTPS_PROXY` in each container's injected
env, pointing at `host.docker.internal:<port>` (or the equivalent
host-network address).

The proxy forwards in plain reverse-proxy mode — **no HTTPS
interception, no CA cert management, no body inspection.** Logs to
SQLite per request:

```sql
CREATE TABLE http_log (
  id          INTEGER PRIMARY KEY,
  ts          TEXT NOT NULL,
  agent       TEXT NOT NULL,        -- which agent's call
  method      TEXT NOT NULL,
  host        TEXT NOT NULL,
  path        TEXT NOT NULL,
  status      INTEGER,
  duration_ms INTEGER,
  bytes_in    INTEGER,
  bytes_out   INTEGER
  -- explicitly NOT recorded:
  --   request body / response body
  --   request headers (credentials)
  --   response headers
);
```

Enough to power "what is this agent doing" in the dashboard. Not
enough to recover sensitive content. Per-agent attribution because
the proxy knows which container connected (different IP on the
Docker bridge, or different `Host` header — implementation detail).

## Rotation

To rotate a secret:

1. Update the secret in the password manager.
2. Run on the laptop:

   ```bash
   pnpm agent-host rotate-secret GH_TOKEN_RW=ghp_new...
   ```

3. The CLI SSHs to the VM, edits `/etc/agent/env` in place,
   `agent-host cycle personal-dm` (or whichever agents inject this
   secret).

Cycling the agent restarts its container with the new env. No host
restart needed unless the rotated secret is a host-side one
(SLACK_*).

Rotation frequency in practice: low (manual). For frequent rotation,
the future logging-proxy upgrade can inject substituted values at
request time without container restart.

## Bootstrap

`agent-host bootstrap` reads the operator's local secrets file (path
supplied as an arg) and writes it to `/etc/agent/env` on the VM:

```bash
agent-host bootstrap --vm my-agents.exe.dev --env ~/secrets/my-agents.env
```

The local file (`~/secrets/my-agents.env`) is in the password
manager's export format or a hand-maintained file. **Never** in the
repo. `.gitignore` lists `*.env` to catch accidents.

## What we explicitly don't do

- **No central credential service.** Each VM has its own
  `/etc/agent/env`. Cross-VM credential sharing would mean a central
  store, which is the kind of "one more piece of infra" we're
  avoiding.
- **No vault with rotating tokens.** The logging proxy is the
  upgrade path if/when this becomes worth it (request-time
  substitution + audit per credential use).
- **No `request_credential` RPC verb.** v1 had it; v3-hybrid doesn't.
  Env injection at spawn time covers the use case for a single-user
  install.
- **No "let the agent ask for credentials."** Skills get what they
  get. If a skill needs a credential the agent's container doesn't
  inject, the operator adds it to `agent.config.toml`'s `inject`
  list, restarts the container.

## Open sub-questions

- **Where do operator-side secrets live on the laptop?** Bitwarden /
  1Password export script is the cleanest. The operator runs a
  `agent-host bootstrap --env` against the exported file.
- **Recovery if `/etc/agent/env` is lost.** Restore from password
  manager. Only piece that requires out-of-band recovery.
- **Logging proxy: HTTP or HTTPS interception?** HTTP only. TLS
  interception means CA cert management. The metadata is enough.
- **Per-call audit for credential use.** Add later via the proxy:
  log every outbound call that uses a specific credential. v1 just
  logs the URL.
- **Secret detection in `agent-host new-agent`.** Should the CLI
  scan `shared/.claude/` and `agents/<name>/overrides/` for
  secret-shaped strings (`sk-*`, `ghp_*`, `xoxb-*`) before deploy,
  warning the operator if found? Worth it. ~20 LOC.
