# Adding MCP servers to agent groups

Per-group MCP wiring lives in `groups/<folder>/container.json#mcpServers`.
Already git-tracked → reproducible on fresh VMs. Each group is independent;
no built-in cross-group sharing (duplicate the entry if you want one server
in multiple groups).

## Config shape

```json
{
  "mcpServers": {
    "<name>": {
      "command": "<binary>",
      "args": ["..."],            // optional
      "env": { "...": "..." },    // optional, see "Auth" below
      "instructions": "..."       // optional, doc-as-prompt
    }
  }
}
```

`instructions` becomes a CLAUDE.md fragment (`.claude-fragments/mcp-<name>.md`)
imported into the composed system prompt at spawn — use it to tell the agent
when/how to use the server.

## How to add

Three paths:

1. **Manual edit** (recommended). Edit container.json, restart the session,
   commit. Gets you reproducibility for free.
2. **`add_mcp_server` tool from inside a session.** Agent requests; admin
   approves via DM; host writes container.json and kills the container.
   See `container/agent-runner/src/mcp-tools/self-mod.ts:81` and
   `src/modules/self-mod/apply.ts:75`.
3. **Pre-built skills** when they exist: `/add-gmail-tool`, `/add-gcal-tool`,
   `/add-ollama-tool`, `/add-atomic-chat-tool`. Use these first if applicable.

## Auth: three patterns

### Pattern A — stdio MCP server wrapping an HTTPS API

The MCP server is a stdio binary that internally calls an HTTPS API
(GitHub, Linear-stdio, Notion-stdio, Slack-stdio, etc.). Auth happens via
`Authorization` header at request time — OneCLI handles it transparently.

- Container is preconfigured with HTTPS_PROXY → OneCLI gateway + CA trust.
- MCP server makes its HTTPS call → OneCLI matches `hostPattern` (and
  optional `pathPattern`) against the vault → injects auth header →
  upstream sees authenticated call.
- **container.json's `env` field stays empty.** The token never enters the
  container or the agent's context.

Recipe:

```bash
# 1. Add secret to vault
onecli secrets create --name "<label>" \
  --type generic --host-pattern "<api-host>" \
  --header-name "Authorization" \
  --value-format "Bearer {value}" \
  --value "<token>"
# `onecli secrets create --help` shows current flags. As of v1.5.0 the
# `--type` enum is just `anthropic` | `generic`; for any non-Anthropic
# bearer auth use `generic` + `--header-name` + `--value-format` as above.

# 2. Wire the server — edit groups/<folder>/container.json
#    Add an entry under mcpServers (see Config shape above).

# 3. Grant the agent access to the new secret.
#    OneCLI agents start in `selective` mode — new secrets are NOT
#    auto-bound (CLAUDE.md "Gotcha: auto-created agents start in
#    selective secret mode"). Pick one:
onecli agents list
onecli agents set-secret-mode --id <agent-id> --mode all
# or pin specific secrets:
# onecli agents set-secrets --id <agent-id> --secret-ids <id1>,<id2>

# 4. Restart the agent's container so the next message picks up the
#    new mcpServers entry. Either send a message and live with one stale
#    turn, or force a kill:
docker ps --filter "label=nanoclaw-session"
docker rm -f <container-id>

# 5. Commit
git add groups/<folder>/container.json
git commit -m "feat(<folder>): add <name> MCP server"
```

### Pattern B — native HTTP/SSE remote MCP server (bridged via mcp-remote)

Some MCP servers are hosted as HTTP/SSE endpoints rather than stdio
binaries — MintMCP-hosted servers, Linear's cloud MCP, Atlassian MCP,
anything you'd add to Claude Code with `claude mcp add -t http <url>`.

The Claude Agent SDK / Claude Code's `--mcp-config` only accepts the stdio
shape (`{ command, args, env }`), so we use the
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) npm package as a
stdio↔HTTP bridge. It's pre-installed in the container image (pinned via
`ARG MCP_REMOTE_VERSION` in `container/Dockerfile`) so the runtime cost is
just the HTTP handshake, not an `npx` download.

> **Why pinned in the image, not `npx -y mcp-remote`:** first-time `npx`
> download + mcp-remote's OAuth-discovery step can exceed Claude Code's
> MCP-server registration window. When that happens, the session boots with
> no tools from the laggard server and stays that way for the life of the
> container — no recovery short of restart. Baking it in eliminates that
> race entirely.

Auth still flows through Pattern A's mechanism: bearer in the vault,
OneCLI's HTTPS proxy injects the header when mcp-remote calls the upstream.

Recipe:

```bash
# 1. Add the bearer to the vault
onecli secrets create --name "<label>" --type generic \
  --host-pattern "<mcp-host>" \
  --header-name "Authorization" \
  --value-format "Bearer {value}" \
  --value "<token>"

# 2. Wire the server — edit groups/<folder>/container.json
#    {
#      "mcpServers": {
#        "<name>": {
#          "command": "mcp-remote",
#          "args": ["https://<mcp-host>/.../mcp"],
#          "env": {},
#          "instructions": "..."
#        }
#      }
#    }
# Note: `mcp-remote` resolves from PATH (`/pnpm/mcp-remote`). Don't wrap in
# `npx -y` — that re-introduces the registration race described above.

# 3. Grant the agent access to the new secret (selective-mode default).
onecli agents set-secret-mode --id <agent-id> --mode all

# 4. Restart the container so the new mcpServers entry is picked up
docker rm -f <container-id>
```

Bumping mcp-remote: edit `ARG MCP_REMOTE_VERSION` in
`container/Dockerfile`, run `./container/build.sh`, restart containers.

### Pattern C — servers that need secrets at startup (env vars)

Some servers read e.g. `STRIPE_API_KEY` from env at process start, before
any HTTPS call. OneCLI can't intercept startup-time env reads.

Today, NanoClaw passes `mcpServers[name].env` through verbatim from
container.json to the subprocess (`container/agent-runner/src/index.ts`,
~line 84) — **no `${VAR}` substitution from host env**. So env-based
secrets currently force one of:

1. **Plaintext in container.json** — DON'T DO THIS. container.json is
   git-tracked.
2. **Look for an HTTPS-based alternative.** Most popular APIs have an MCP
   server flavor that accepts auth via header (Pattern A or B).
3. **Patch the runner** to support `${HOST_ENV_VAR}` substitution and
   keep secrets in `.env` only. Small change in `container/agent-runner/
   src/index.ts` near the mcpServers loop. Worth doing the first time you
   actually need a Pattern B server.

## Approval gating (optional)

To require human approval per credentialed call (e.g., "agent must DM me
before calling Stripe"):

- Configure the rule in OneCLI's web UI at `http://127.0.0.1:10254`. The
  v1.5.0 CLI's `rules create --action` only supports `block` and
  `rate_limit`; `approve` is web-UI only as of this writing.
- Host side is already wired: `src/modules/approvals/onecli-approvals.ts`
  long-polls `GET /api/approvals/pending` and DM-routes via the
  `pickApprover` flow.

## Reproducibility checklist (fresh VM)

Container.json carries the wiring; vault carries the secrets.

| Thing | Survives `git clone`? |
|---|---|
| MCP server wiring (command/args/instructions) | ✓ |
| Secret values in OneCLI vault | ✗ re-import per VM |
| Per-agent secret allowlist (selective vs all) | ✗ re-set per VM |

Bootstrap order on a fresh VM:

1. `git clone` + standard NanoClaw setup (see `docs/reproducing-instance.md`).
2. Set up OneCLI vault — re-import or recreate every secret.
3. **Send the first message to each agent group** — this triggers
   `onecli.ensureAgent()` in `src/container-runner.ts` and creates the
   OneCLI agent record.
4. **Then** `onecli agents set-secret-mode --mode all` (or set-secrets) for
   each agent. Until you do this, MCP-server HTTPS calls return 401 even
   though everything else looks correct.

## Quick mapping cheatsheet

| Goal | Where to change |
|---|---|
| Wire a new MCP server in one group | `groups/<folder>/container.json` |
| Wire same server in all groups | duplicate the entry in each group's container.json |
| Wire a native HTTP/SSE MCP server | use `command: "mcp-remote"` with the URL as the only arg (Pattern B) |
| Bump `mcp-remote` version | `ARG MCP_REMOTE_VERSION` in `container/Dockerfile`, then `./container/build.sh` |
| Add credentials for an HTTPS API | `onecli secrets create ...` |
| Let one specific agent see a secret | `onecli agents set-secrets --id <agent> --secret-ids ...` |
| Let one agent see all secrets | `onecli agents set-secret-mode --id <agent> --mode all` |
| Approve before each credentialed call | OneCLI web UI rule (`approve` action) |
| Add MCP server interactively from a session | the agent calls `add_mcp_server` MCP tool → admin DM-approves |
| Document the server's purpose to the agent | `instructions` field on the mcpServers entry |
