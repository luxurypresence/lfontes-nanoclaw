# Snowflake access for NanoClaw agents

**Status:** Research only. Not implemented. Blocked on org adding a network policy that allows PATs (requested 2026-05-01).

This doc captures the design discussion so we can pick it up cold when the unblock arrives. Once implementation lands, the working steps should crystallize into an `/add-snowflake-tool` skill (mirroring `/add-vercel`) and this doc should either be replaced by the skill's SKILL.md or kept as the "why" behind it.

## Goal

Give NanoClaw agents access to LP's Snowflake — read for `clanq-channels`, read-write for `clanq-dm` — with the same per-group scoping and OneCLI-vaulted credentials we use for GitHub, Linear, Notion, etc.

## Why the gh / vercel pattern doesn't fit

`gh` and `vercel` work because they send `Authorization: Bearer <pat>` on every request. OneCLI's HTTPS proxy rewrites that header on the wire, so the container only ever holds a placeholder.

Snowflake's CLI auth model is different:

- **Login** is `POST /session/v1/login-request` with credentials (password, JWT, or PAT) **in the JSON body**.
- **Key-pair auth** signs a JWT *locally* using a private key the CLI can read.
- Subsequent calls use a session token from the login response, not a long-lived bearer.

OneCLI only mutates request headers and query params (`onecli secrets create --header-name` / `--param-name`). It can't rewrite request bodies, can't sign JWTs, and can't inject env vars at container start. So if `snow` is the client, the secret material has to land *inside* the container.

The exception: PATs against Snowflake's REST/SQL API (`*.snowflakecomputing.com/api/v2/*`) accept `Authorization: Bearer <pat>` directly. That's the one OneCLI-friendly door — but only if our client speaks that API surface, not the CLI's native protocol.

## Auth options compared

| Option | Cred shape | OneCLI-friendly? | Status |
|---|---|---|---|
| Snowflake-managed Cortex MCP (`*.snowflakecomputing.com/api/v2/cortex/agents`) | PAT as Bearer | Yes — header injection works | **Out.** LP doesn't have Cortex provisioned. |
| Self-hosted `snowflake-labs-mcp` + PAT | PAT in MCP service env (used as `SNOWFLAKE_PASSWORD`) | Yes for the agent→MCP leg (bearer we issue ourselves); MCP→Snowflake auth happens off-container | **Target.** Blocked on PAT network policy. |
| `snow` CLI baked in container + PAT in `connections.toml` | PAT file or env in container | No — auth is body-based; OneCLI can't help | Possible if we need `snow` commands the MCP doesn't cover (snowpark, app deploy). Defer until needed. |
| `snow` CLI baked in + 1Password service-account fallback | `op` fetches password+TOTP at session start | Indirectly — `op` API calls go through OneCLI bearer, but the resulting Snowflake creds still land in container env | **Fallback** if PATs are forbidden outright. Heavier moving parts. |

## Target design (PAT + self-hosted snowflake-labs-mcp)

Reuses the HTTP-MCP pattern documented in `project_http_mcp_infra.md` (Auggie / Linear / Notion). The wiring:

```
agent container ──stdio──> mcp-remote ──HTTPS+OneCLI bearer──> snowflake-labs-mcp (host sidecar) ──Python connector──> Snowflake
                            (baked in image)                    (PAT in env)
```

### Steps when unblocked

1. **Verify Luis can mint a PAT.** Once the network policy lands:
   ```sql
   ALTER USER <luis> ADD PROGRAMMATIC ACCESS TOKEN <name>
     ROLE_RESTRICTION = '<role>'
     DAYS_TO_EXPIRY = 90;
   ```
   PATs ignore secondary roles, so the role on the PAT is the ceiling. Issue one PAT per access tier (RW for `clanq-dm`, RO for `clanq-channels`).
2. **Pick a service-config.yaml.** `snowflake-labs-mcp` reads a YAML that selects which databases/schemas/semantic-views to expose and which tool families to enable. Without Cortex, the useful tools are SQL execution, object management, and (if relevant) semantic view querying. Disable the Cortex tools so the agent's tool list stays clean.
3. **Stand up the MCP as a host sidecar.** Run `uvx snowflake-labs-mcp --service-config-file <yaml> --transport streamable-http --port <p>` under launchd (macOS) or systemd `--user` (Linux), with env:
   ```
   SNOWFLAKE_USER=<user>
   SNOWFLAKE_ACCOUNT=<acct>
   SNOWFLAKE_PASSWORD=<pat>     # PAT goes in the password slot; do not use --pat / SNOWFLAKE_PAT (deprecated)
   ```
   The PAT never touches an agent container. Two PATs → two MCP processes on different ports for per-group scoping.
4. **Front the MCP with a self-issued bearer** (any random string, vaulted in OneCLI):
   ```
   onecli secrets create \
     --name "Snowflake MCP (RW)" \
     --type generic \
     --value "<random>" \
     --host-pattern "127.0.0.1" \
     --path-pattern "/<rw-path>/*" \
     --header-name "Authorization" \
     --value-format "Bearer {value}"
   ```
   Repeat with a different secret + path for the RO bearer. Path-pattern disambiguation matters here — same host, two upstreams — exactly the MintMCP trick from `project_http_mcp_infra.md`.
5. **Wire each group's `container.json`** with `mcp-remote http://127.0.0.1:<port>/<path>` (the URL the bearer's host+path pattern matches).
6. **Set selective secret mode** on each agent so only the right bearer is injected:
   ```
   onecli agents set-secret-mode --id <agent-id> --mode selective
   onecli agents set-secrets --id <agent-id> --secret-ids <bearer-id>
   ```
7. **Restart running containers** so they pick up the new MCP server.
8. **Sanity check:** in a session, ask the agent to run a trivial `SELECT current_role(), current_warehouse()` via the MCP and confirm the role matches the PAT's role restriction.

### Operational notes

- **PAT lifetime.** Default 15 days, max 90. Pick 90 and document a manual rotation cadence (or schedule a routine that pings Luis when expiry approaches). Each user can hold ≤15 PATs (including disabled), so don't churn them.
- **Auth policy.** PATs require the user's authentication policy to include `PROGRAMMATIC_ACCESS_TOKEN`. Network policies on the role apply too — that's why this is blocked on the org-side network policy in the first place.
- **Role hygiene.** PATs bypass secondary roles. The single role on the PAT must own (or have grants to) every object the agent should touch. For RO, this typically means a dedicated `LP_AGENT_RO` role with `USAGE` on warehouses + `SELECT` on the relevant schemas. For RW, scope tightly — no `ACCOUNTADMIN`-style PATs.
- **Network egress from the host.** The MCP sidecar talks to Snowflake; the agent containers do not. Verify the host's egress rules permit `*.snowflakecomputing.com`.

## Fallback: 1Password service account + `snow` CLI

If PATs are forbidden:

- Add Python ≥3.10 + `pipx install snowflake-cli` to `container/Dockerfile`. Add `op` (1Password CLI) similarly.
- Create a 1Password **service account** with read access to the vault holding Luis's Snowflake creds.
- Vault the service-account token in OneCLI for `*.1password.com` with bearer header injection.
- At session start (or per-command), use `op run` or `op item get` to fetch password+TOTP into `SNOWFLAKE_PASSWORD` / appropriate env, then invoke `snow`.

Heavier than PATs because (a) the container image grows by Python + Node + extra CLIs, (b) every Snowflake call has an `op` round-trip, and (c) MFA TOTP rotation needs careful handling per session. Worth it only if the PAT path is firmly blocked.

## When this doc gets replaced

The first successful end-to-end run (a real MCP query against LP's Snowflake) is the trigger to:

1. Crystallize the exact commands that worked into `/add-snowflake-tool` (skill following the `/add-vercel` shape: preflight → install container skill → configure creds → wire MCP → restart).
2. Add a `container/skills/snowflake/SKILL.md` so the agent knows what tools it has and how to use them.
3. Either delete this doc or trim it down to a "design rationale" pointer next to the skill.

## References

- [Snowflake CLI installation](https://docs.snowflake.com/en/developer-guide/snowflake-cli/installation/installation)
- [Configuring Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-cli)
- [Managing Snowflake CLI connections](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections)
- [Programmatic access tokens](https://docs.snowflake.com/en/user-guide/programmatic-access-tokens)
- [Authenticating Snowflake REST APIs](https://docs.snowflake.com/en/developer-guide/snowflake-rest-api/authentication)
- [Snowflake-managed MCP server (Cortex)](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-mcp)
- [Snowflake-Labs/mcp on GitHub](https://github.com/Snowflake-Labs/mcp)
- Internal: `docs/adding-mcp-servers.md`, memory `project_http_mcp_infra.md`
