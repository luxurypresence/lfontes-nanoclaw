# Investigation: trust-zone provisioning

## Question

How are per-zone containers actually built and configured in practice? Two
zones, `dm-trust` and `public-trust`, on one ~2 vCPU / 8 GB / 25 GB VM,
single tenant, Docker available. The model says "container = trust zone";
this note pins down what `docker build` and `docker run` actually look like,
where credentials come from, where mounts are declared, and how a new zone
gets added six months from now without a fragile manual ritual.

## Constraints (recap, brief)

- Single VM, single human. No multi-tenant. No HA.
- Capabilities are ambient *inside* a container, fixed at provisioning time
  (principle 2 of `design-principles.md`).
- Containers are long-lived (principle 1) — provisioning happens rarely,
  per-call cost is irrelevant; setup-time clarity matters.
- Host owns durability; containers own ephemera. The host can hold the
  credential store and inject at start time.
- Minimal moving parts (principle 7). One Node host, one SQLite, a few
  containers on a host-only bridge, Unix-socket RPC.

## Image strategy (options + recommendation)

| Option | What it is | Pros | Cons |
|--------|------------|------|------|
| **A. Single Dockerfile + build args** | One `Dockerfile`, two `docker build --build-arg ZONE=…`. Conditionals select tool set per zone. | One source of truth; diff between zones is grep-able. | Conditionals (`RUN if [ "$ZONE" = ... ]`) get gnarly fast; build cache fragments per zone. |
| **B. Per-zone Dockerfile** | `Dockerfile.dm-trust`, `Dockerfile.public-trust`, each verbose and standalone. | Maximally explicit; zero conditional logic. | Duplication; bumping a base dep means two edits; drift risk. |
| **C. Base image + per-zone wrapper image** | `nanoclaw-agent:base` then `FROM nanoclaw-agent:base` for each zone, adding tools. Credentials still injected at runtime. | Layering is what Docker is *for*; the wrapper is short (5-20 lines) and trivially auditable; build cache works well; new zone = new short Dockerfile. | Two-stage build to track; rebuilds cascade. |
| **D. Single base image + per-zone runtime config only** | One image, everything declared in compose: env, mounts, network. No per-zone build. | Simplest build pipeline; zero image proliferation. | All tools end up in one image (~larger); can't strip the `vercel` CLI out of `public-trust` even though we'd want to; credentials-only differentiation isn't enough when binary surface matters. |

**Recommendation: C (base + per-zone wrapper).** It's the only option that
honors "container = identity" structurally — `public-trust` has a *physically
smaller* binary surface than `dm-trust`, not a same-image-with-different-env
masquerade. The wrapper Dockerfiles are tiny (see §Concrete example); the
base image holds the agent runtime and OS deps. Build cache works.

D is tempting and I almost picked it. The reason I didn't: if a future
research-zone needs `nmap` or `tcpdump` or something genuinely sensitive,
I want it absent from `public-trust`'s filesystem, not merely unwired. Same
argument for `vercel` CLI — it has its own auth state in `~/.vercel/`, and
"just don't put credentials in" isn't as clean as "the binary isn't here".

## Credential injection (options + recommendation, with blast-radius assessment)

| Option | Blast radius if container compromised | Rotation | Complexity |
|--------|---------------------------------------|----------|------------|
| **A. Per-zone `.env.<zone>` file via Docker `--env-file`** | All zone creds exposed in `/proc/1/environ`; any process in container reads them. Long-lived. | Edit file, restart container. Trivial. | Trivial. |
| **B. OneCLI-style proxy** | No raw creds in container — only a CA cert + proxy URL. Proxy injects at HTTP boundary. Compromise = ability to *make calls* but not exfiltrate the secret. | Rotate in the proxy's vault; containers don't restart. | High. Needs a sidecar/host process, CA trust setup, HTTPS interception. |
| **C. Sealed-secret file mounted read-only** | File contents readable by any process in container. Same as A but the secret isn't in `environ` — slightly less leaky to subprocesses that print env. | Replace file, restart. | Low. |
| **D. Vault sidecar** | Sidecar holds creds, container queries over loopback. Compromise of agent process = ability to query, not exfiltrate the master key. | Rotate in vault. | High. Extra process per zone. |
| **E. Host RPC `request_credential(name)`** | Agent gets a *short-lived token* on demand. Compromise window bounded by token TTL. Audit log per request. | Rotate in host's vault. Tokens expire. | Medium. RPC verb already exists in principle 4. |

**Recommendation: A as the floor, E for any credential I'd actually be
upset about leaking.**

Reasoning, opinionated:

- **A is fine for low-blast-radius creds** — read-only PAT in
  `public-trust`, the Slack bot token (it's already a bot, scoped, and any
  blast is the same blast Slack itself permits). Putting it in `--env-file`
  and moving on is the right amount of effort.
- **E is where the architecture pays off.** Principle 4 already says RPC
  exposes intents — `request_credential` is one of those intents. For the
  rw GitHub PAT, the Vercel deploy token, anything that could ruin my week
  if leaked: agent calls `request_credential("github_rw")` over the
  Unix-socket RPC, host checks "is the caller `dm-trust`?" against the
  zone↔credential ACL in the central SQLite, returns a token with a 15-min
  TTL. Container never persists it. Compromise window = TTL. Rotation =
  update one row in the central DB.
- **B (OneCLI proxy) is excellent but heavy** — it's what upstream NanoClaw
  uses. For *this* personal rewrite, I'd rather invest the complexity
  budget in E, which is just "another RPC verb" instead of "a transparent
  HTTPS proxy with a CA cert distribution problem". If I ever want
  per-call audit of *every* outbound HTTP call (not just credential
  fetches), B becomes worth it.
- **C and D are middle options** I don't need at this scale.

Concretely: `.env.dm-trust` and `.env.public-trust` hold the *bootstrap*
credentials (Slack bot token for the dm-trust agent, read-only PAT for
public-trust, the RPC token for talking to the host). Anything more
sensitive than that is fetched via `request_credential` at use time.

## Tool layering

The canonical example: `gh` CLI with a write PAT in `dm-trust`, read-only
PAT in `public-trust`. Same binary, different credential.

`gh` reads `GH_TOKEN` (and `GITHUB_TOKEN` as fallback) from env. Easy and
ergonomic, but parks the secret in `environ`. Two ways to do it:

1. **Bootstrap-cred path (simple):** put `GH_TOKEN=ghp_…` in
   `.env.<zone>`. `gh` Just Works. Use for read-only PAT.
2. **RPC-cred path (real):** the agent runs a small wrapper script `gh`
   that calls `request_credential("github")` over RPC, exports the
   returned token into its own subshell's env, then `exec`s the real
   `gh` binary. Token lives only for the duration of that subshell. Use
   for the write PAT.

Config-file mounts (`~/.config/gh/hosts.yml`) work too but bake the
credential into a file on disk — same blast radius as a secret file mount,
no real win over env. I'd rather have the env vs RPC split above.

For tools that don't take env-var auth (e.g., `vercel` which uses
`~/.vercel/auth.json`): the wrapper script approach is the same, it just
writes the credential to a tempfile under `/run/zone-creds/$$/` and
cleans up via `trap`. Tempfile lives for one invocation.

## Mount declarations

Single source of truth: the **central SQLite**, in a `trust_zone_mounts`
table the host reads when constructing `docker run` args. Compose files
are derived, not authoritative — they're regenerated by `ncl zones sync`
whenever the table changes, so an operator can read the compose file but
shouldn't hand-edit it.

```sql
CREATE TABLE trust_zone_mounts (
  zone_id   TEXT NOT NULL REFERENCES trust_zones(id),
  host_path TEXT NOT NULL,
  container_path TEXT NOT NULL,
  mode      TEXT NOT NULL CHECK (mode IN ('ro', 'rw')),
  PRIMARY KEY (zone_id, container_path)
);
```

Why DB-as-source vs compose-as-source: principle 5 (host owns durability)
and principle 7 (minimal moving parts). The host already has the SQLite;
adding a table is cheaper than introducing a YAML-as-source layer the
host has to parse. The compose file is regenerated output, the way
`groups/<name>/container.json` is regenerated output in upstream
NanoClaw.

`dm-trust` gets `host_path=/srv/workspace, container_path=/workspace,
mode=rw`. `public-trust` gets the same `host_path` and `container_path`
with `mode=ro`. The same directory tree visible read-write to one zone
and read-only to the other is the entire point.

## Adding zones post-install

Command: `ncl zones create --name <new-zone> --base <existing>`.

What it does, in order:

1. **Insert** a row into `trust_zones` with a generated `container_name`
   and a fresh `rpc_token` (random 32 bytes hex).
2. **Copy mounts** from the base zone into `trust_zone_mounts`, prompting
   to flip any `rw` to `ro` (or vice versa).
3. **Copy credential ACLs** from the base into `zone_credentials` (the
   table that drives `request_credential` ACL), prompting for which
   bootstrap creds the new zone needs.
4. **Prompt** for any new credentials the operator wants to provision —
   added to the central credential store, ACL'd to the new zone.
5. **Write** a per-zone Dockerfile by copying the base zone's Dockerfile
   to `containers/<new-zone>/Dockerfile`, ready to hand-edit if a tool
   surface needs adjusting.
6. **Build** the image: `docker build -t nanoclaw-agent-<new-zone>
   containers/<new-zone>/`.
7. **Regenerate** `docker-compose.yml` from the DB.
8. **Start** the container: `docker compose up -d <new-zone>`.
9. **Emit audit event:** `zone.created` with the operator, base, and
   resulting credential set.

Step 5 deliberately leaves the Dockerfile as a hand-edit artifact: if you
want a *new* tool surface, you edit the Dockerfile; if you just want
different *credentials*, the DB rows are enough and the Dockerfile is a
no-op copy of the base. The 95% case is "different creds, same tools",
and that case requires no Dockerfile change.

## Concrete example: dm-trust + public-trust docker-compose.yml

Directory layout:

```
containers/
  base/Dockerfile               # nanoclaw-agent:base — runtime + OS deps
  dm-trust/Dockerfile           # FROM nanoclaw-agent:base, adds gh + vercel
  public-trust/Dockerfile       # FROM nanoclaw-agent:base, adds gh only
.env.dm-trust                   # bootstrap creds, host-only readable (chmod 0600)
.env.public-trust
docker-compose.yml              # generated from central SQLite
data/host.sock                  # Unix-socket RPC endpoint
```

`containers/base/Dockerfile` (excerpt):

```dockerfile
FROM oven/bun:1.1-debian
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl jq sqlite3 git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY agent-runtime/ /app/
RUN bun install --frozen-lockfile
ENTRYPOINT ["bun", "run", "/app/index.ts"]
```

`containers/dm-trust/Dockerfile`:

```dockerfile
FROM nanoclaw-agent:base
RUN curl -sSL https://github.com/cli/cli/releases/download/v2.55.0/gh_2.55.0_linux_amd64.tar.gz \
      | tar -xz --strip-components=2 -C /usr/local/bin gh_2.55.0_linux_amd64/bin/gh
RUN curl -sSL https://vercel.com/install.sh | sh
COPY tools/gh-wrapper /usr/local/bin/gh-rpc   # wrapper that calls request_credential
```

`containers/public-trust/Dockerfile`:

```dockerfile
FROM nanoclaw-agent:base
RUN curl -sSL https://github.com/cli/cli/releases/download/v2.55.0/gh_2.55.0_linux_amd64.tar.gz \
      | tar -xz --strip-components=2 -C /usr/local/bin gh_2.55.0_linux_amd64/bin/gh
# no vercel, no rpc-wrapper — read-only PAT comes via env
```

`docker-compose.yml` (generated):

```yaml
services:
  dm-trust:
    image: nanoclaw-agent-dm-trust:latest
    container_name: nanoclaw-dm-trust
    restart: unless-stopped
    env_file: .env.dm-trust          # bootstrap creds + RPC token only
    environment:
      ZONE_ID: dm-trust
      RPC_SOCKET: /host/host.sock
    volumes:
      - /srv/workspace:/workspace:rw
      - ./data/host.sock:/host/host.sock   # Unix-socket RPC
      - dm-trust-session:/var/agent        # ephemeral session SQLite
    networks: [zone-net]
    read_only: false                  # /workspace is rw for this zone
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 2g
    cpus: 1.0

  public-trust:
    image: nanoclaw-agent-public-trust:latest
    container_name: nanoclaw-public-trust
    restart: unless-stopped
    env_file: .env.public-trust
    environment:
      ZONE_ID: public-trust
      RPC_SOCKET: /host/host.sock
    volumes:
      - /srv/workspace:/workspace:ro    # read-only — the whole point
      - ./data/host.sock:/host/host.sock
      - public-trust-session:/var/agent
    networks: [zone-net]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 1g
    cpus: 0.5

networks:
  zone-net:
    driver: bridge
    internal: true                  # no internet from this bridge; egress is via
                                    # the proxy-or-host-mediated network only
    # If outbound LLM/web access is needed direct, change to: internal: false
    # and bind a separate egress network. Keeping internal:true defaults to
    # "deny egress" and forcing /add-network on each zone that earns it.

volumes:
  dm-trust-session:
  public-trust-session:
```

`.env.dm-trust`:

```
RPC_TOKEN=<32-byte-hex-from-trust_zones.rpc_token>
SLACK_BOT_TOKEN=xoxb-...
GH_TOKEN=ghp_readonly_fallback_...   # the rw PAT is fetched via RPC, not here
```

`.env.public-trust`:

```
RPC_TOKEN=<32-byte-hex>
GH_TOKEN=ghp_readonly_...
```

Notes on the compose file:

- **`internal: true`** on the bridge is opinionated — it forces every new
  zone to think about egress. The agent runtime reaches the LLM API via
  the host (which is on a different interface), not directly. Flip it for
  zones that genuinely need direct outbound.
- **`cap_drop: [ALL]`** and **`no-new-privileges`** are cheap defenses
  against a compromised container trying to escalate. Doesn't replace the
  trust model, just shrinks the worst case.
- **`mem_limit` + `cpus`** stop a runaway agent from starving the other
  zone or the host. The numbers are sized for the 2 vCPU / 8 GB box.
- **Session volume is a named volume**, not a bind mount — the host
  *deliberately* doesn't read it (principle 5).

## Recommendation (overall)

- **Image: option C** — base image + per-zone wrapper images.
- **Credentials: A as floor, E (`request_credential` RPC) for anything
  high-blast-radius.** `.env.<zone>` holds bootstrap creds and the RPC
  token; the agent fetches the actually-dangerous ones over RPC with a
  short TTL.
- **Mounts and zone config: central SQLite is source of truth;
  `docker-compose.yml` is regenerated output.**
- **New zone:** one `ncl zones create` command, copies from a base zone,
  prompts for credential deltas, hand-editable Dockerfile.

The whole provisioning surface stays under 200 lines of YAML and
Dockerfile for the two-zone case. If it gets longer than that, something
has slipped past principle 7 and needs to be argued for explicitly.

## Open sub-questions

- **Image rebuilds on tool bumps.** When I bump `gh` from 2.55 to 2.56,
  do I rebuild both wrappers and restart both containers, or is there a
  staged rollout? For one operator and two zones, just rebuild both.
- **Egress policy.** Is `internal: true` actually workable, or does the
  agent runtime need direct outbound to `api.anthropic.com`? If yes,
  there's a per-zone egress network with a denylist. Probably its own
  investigation (`09-egress-policy.md`).
- **Wrapper script ergonomics.** `gh-rpc` swaps env then exec-s; what
  about tools that re-read env on every subcommand (so subshells need
  the export)? Probably fine, but needs a smoke test before I rely on it.
- **Token TTL for `request_credential`.** 15 min is a guess. Should
  long-running operations (a slow `gh repo clone`) renew, or fail and
  retry with a fresh token? Renew is friendlier; fail-and-retry is
  simpler. Lean fail-and-retry.
- **Bootstrap rotation.** The `RPC_TOKEN` in `.env.<zone>` is the one
  credential that can't be fetched via RPC (chicken/egg). How is *that*
  rotated? Probably: regenerate the row in `trust_zones`, rewrite the
  `.env.<zone>` file, `docker compose up -d` to restart the zone. One
  manual step per rotation, infrequent.
