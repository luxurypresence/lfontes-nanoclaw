# Credentials

Subprocess env injection, Unix-user split, no vault. Same threat
model as a secrets vault would give us for a single-user personal
install, with dramatically less infrastructure.

## The threat model (and what we're not defending against)

What we **are** defending against:

- A skill that accidentally reads `~/.env` and writes it to a log.
- A misbehaving MCP server that scans the harness's home directory.
- Plain operator mistake: credentials leaking into the harness's
  conversation context because they were on disk in a path the
  harness explored.

What we are **not** defending against:

- A malicious harness that the operator deliberately installed. If
  Claude Code itself is compromised, the credentials passed via
  subprocess env are visible in its process memory. There's no defense
  against that short of "don't use a compromised harness."
- A compromised host process. If `host` is owned, the game is over;
  it holds the cleartext env at runtime.
- Network egress / exfiltration. Out of scope. The harness needs to
  call the LLM API and any tool API; we don't try to monitor those.

The bar is: **the harness should not see credentials it didn't ask
for, and credentials should not exist on disk in a path the harness
can read.**

## The Unix user split

Two users on the VM:

| User | What it runs | Can read `/etc/agent/env`? |
|------|--------------|---------------------------|
| `host` | The Node framework process (host process, dashboard, logging proxy) | **Yes** — the env file is its source of truth. Reads at startup, holds in process memory. |
| `agent` | The harness subprocess (Claude Code, Codex, etc.) and anything it spawns | **No** — file is `root:root` mode `0600`. Reads fail with permission denied. |

The host process invokes the harness as a subprocess with:

```ts
spawn("claude", args, {
  uid: AGENT_UID,
  gid: AGENT_GID,
  env: {
    ANTHROPIC_API_KEY: secrets.anthropic,
    GH_TOKEN: secrets.gh_rw,
    // ... whatever the harness needs
  }
});
```

The harness sees the credentials in its own `process.env`. They live
in its process memory; they are not on disk anywhere it can read.

## `/etc/agent/env` shape

```
# Owned root:root, mode 0600. Read by `host` at startup.

# Anthropic / OpenAI / etc. — for the harness's LLM calls
ANTHROPIC_API_KEY=sk-ant-...

# Channel adapter tokens — for the host's channel-side
SLACK_BOT_TOKEN=xoxb-...
SLACK_SIGNING_SECRET=...

# Tool credentials — passed through to harness subprocess
GH_TOKEN=ghp_...
VERCEL_TOKEN=...

# Dashboard auth
DASHBOARD_AUTH_HASH=$argon2id$...
```

Two categories:

- **Channel/framework-side** (`SLACK_*`, `DASHBOARD_*`): held by the
  host, never passed to the harness.
- **Harness-side** (`ANTHROPIC_API_KEY`, tool credentials): held by
  the host, passed through to the harness via subprocess env.

The split is policy on the host, not OS-level. A bug in the host code
that passed `SLACK_SIGNING_SECRET` into the harness's env would expose
it to the harness; this is the "bug-shaped threat" we accept.

## Bootstrap and rotation

Bootstrapping a new VM:

1. Operator writes `.env.<agent>` locally (from password manager).
2. `deploy/bootstrap.sh <agent>` SSH's to the VM and writes the file
   to `/etc/agent/env` with the right ownership and mode.
3. The file is **not** in the repo. Not in Git, not in CI logs, not
   anywhere reproducible.

Rotation:

1. Operator updates the secret in their password manager.
2. Operator runs `deploy/rotate-secret.sh <agent> KEY=value`.
3. Script SSH's, edits the env file in place, `systemctl restart agent-host`.

The host re-reads the env at startup and re-spawns the harness with
the new env. Rotation is restart-required by design — passing live
env updates into a running subprocess is messy and not worth it for
the rotation frequency we'll actually have.

## Per-agent credential isolation

Each VM has its own `/etc/agent/env`. `personal-dm`'s VM doesn't
have access to `public-bot`'s credentials, and vice versa.
Cross-agent credential leakage requires either (a) someone putting
the same secret in two `.env` files (operator error), or (b) a
compromised SSH key that lets you reach both VMs (out of model).

When provisioning `public-bot`, the operator writes a *separate*
`.env` with the read-only PAT and the bot-scoped Slack token. There
is no central credential store that both VMs read from.

## Logging proxy (observability, not credential substitution)

A ~50-line Node script that the harness's HTTP traffic flows through:

```
harness ── HTTP request ──> logging proxy ── HTTP request ──> internet
                                  │
                                  ▼
                          (log to SQLite)
                          (method, host, path, status, ts, agent_id)
```

Implementation: the host sets `HTTP_PROXY` / `HTTPS_PROXY` in the
harness's env, pointing at the local proxy. The proxy forwards in
plain reverse-proxy mode — **no HTTPS interception, no CA cert
distribution, no body inspection.** Just enough metadata to power
the dashboard's "what is this agent doing?" view.

This is the v1-of-future-credential-substitution placeholder. If we
ever want to:

- Substitute placeholder env vars (`{{GH_TOKEN}}` in MCP configs)
  with real values at request time.
- Audit which credential was used for which outbound call.
- Implement per-call human approval for sensitive endpoints.

...then the proxy is where that logic goes. None of it changes the
harness's view (the harness still sees env vars), so adding it later
is a proxy-only refactor.

## Tool credentials and harness ergonomics

The common case: a tool that reads its credential from env. `gh`
reads `GH_TOKEN`. `vercel` reads `VERCEL_TOKEN`. These flow through
trivially:

```
host (uid=host) reads /etc/agent/env
  -> spawn(claude, ..., env: { GH_TOKEN: ..., VERCEL_TOKEN: ... }, uid=agent)
    -> harness sees both in process.env
      -> harness invokes `gh repo clone ...` as a child
        -> gh reads GH_TOKEN from its own env
```

For tools that don't take env-var auth (e.g., write to
`~/.vercel/auth.json`): the host could write a tempfile into a
tmpfs-mounted directory the harness can read, but this starts to
look like the OneCLI-vault complexity we just rejected. Prefer
env-var-friendly tools; for the rare exception, write the file once
during bootstrap with `agent` ownership.

## Open sub-questions

- **Where do the `.env.<agent>` files live on the operator's
  laptop?** A password manager (Bitwarden, 1Password) export script
  is the cleanest. Not in the repo.
- **What happens if `/etc/agent/env` is missing on boot?** Host
  refuses to start, logs to the systemd journal, dashboard returns
  503. Loud failure.
- **What about runtime secret rotation without restart?** Out of
  scope for v1. If it becomes a real need, a `SIGHUP` handler on the
  host re-reads env and respawns the harness.
- **Logging proxy: HTTP only, or do we ever need TLS interception?**
  Lean HTTP only. TLS interception means CA cert distribution and
  cert-pinning failures. The metadata we can capture without
  intercepting (method + host + path + status) is enough for the
  dashboard view we actually want.
- **`request_credential` RPC?** v1 had an RPC verb where the agent
  could ask for a short-lived token. Punt. With Unix-user isolation
  and "harness sees creds it needs at spawn time," the workflow is
  simpler. Bring it back if a real use case shows up.
