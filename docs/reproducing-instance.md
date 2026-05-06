# Reproducing this instance on a fresh VM

This fork is a single-instance deployment of NanoClaw (Luis's). The repo
captures everything needed to spin up an identical instance on a new VM:
agent personalities, container config, channel wiring, owner role.

## What's tracked vs what isn't

**Tracked in git:**

- `groups/<folder>/CLAUDE.local.md` — per-agent system prompt
- `groups/<folder>/container.json` — per-agent tool config (MCP servers, packages, mounts, skills allowlist, group/assistant name)
- `setup/register.ts` — fork-only patch adding `--unknown-sender-policy`
- `scripts/seed-instance.ts` — replay script for central-DB entities
- `.env.example` — env-var template

**Not tracked (per-VM runtime state):**

- `data/` — central DB (`v2.db`), per-session DBs, and host-cloned LP context repos under `data/shared/`. Recreated by the seed script + the LP shared-context bootstrap step + at runtime.
- `logs/` — host logs.
- `groups/<folder>/CLAUDE.md` — composed at every container spawn from `.claude-shared.md` + `.claude-fragments/`.
- `groups/<folder>/.claude-shared.md`, `.claude-fragments/` — composer-managed.
- `.env` — secrets and instance-local config (Slack tokens, OneCLI URL, TZ, etc.).
- OneCLI agent vault — credentials live separately, see step 4 below.
- `~/.config/nanoclaw/mount-allowlist.json` — host-side mount permission boundary. Required for `additionalMounts` in `container.json` to work. Recreate per VM (see bootstrap step below).

## Bootstrap recipe

Order matters — DB seeding has to come after dependencies are installed but before the host starts.

```bash
# 1. Clone the fork
git clone git@github.com:luxurypresence/lfontes-nanoclaw.git
cd lfontes-nanoclaw

# 2. Install host deps (pinned to Node 22 via .node-version + mise.toml)
pnpm install --frozen-lockfile

# 3. Container deps (separate Bun workspace)
cd container/agent-runner && bun install && cd -

# 4. Build the agent container image
./container/build.sh

# 5. Configure secrets
cp .env.example .env
# Edit .env to set:
#   SLACK_BOT_TOKEN, SLACK_SIGNING_SECRET — from api.slack.com/apps
#   ONECLI_URL                            — typically http://127.0.0.1:10254
#   ASSISTANT_NAME                        — global default (overridden per-group)
#   TZ                                    — system timezone

# 6. Initialize OneCLI vault (Anthropic creds, OAuth tokens, etc.)
#    Run /init-onecli or follow docs/onecli.md. Vault state is in Docker
#    volumes (onecli_pgdata, onecli_app-data) outside this repo and must
#    be re-imported per VM. See "OneCLI vault topology" below for the
#    specific secrets + per-agent allowlists this instance needs.

# 7. LP shared context — pre-clone LP repos that get mounted into agent
#    containers. Add more repos here as you start using them.
mkdir -p shared
gh repo clone luxurypresence/pm-shared-context shared/pm-shared-context
# (gh must already be authed on the host: `gh auth status`)

# 8. Mount allowlist — grant the host permission to mount shared/ into
#    containers. Empty allowlist = all additional mounts blocked. The path
#    is relative; the host resolves it against its cwd (project root).
mkdir -p ~/.config/nanoclaw
cat > ~/.config/nanoclaw/mount-allowlist.json <<'EOF'
{
  "allowedRoots": [
    {
      "path": "shared",
      "allowReadWrite": true,
      "description": "Host-cloned LP repos (pm-shared-context plus working clones). Read-write so agents can clone/pull/edit."
    }
  ],
  "blockedPatterns": [],
  "nonMainReadOnly": true
}
EOF

# 9. Seed the central DB (idempotent — agent groups, messaging groups,
#    wiring, owner role)
mise exec node@22 -- pnpm exec tsx scripts/seed-instance.ts

# 10. Build host TypeScript
pnpm run build

# 11. Start the host (pick the right service flavor)
launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist   # macOS
systemctl --user start nanoclaw                            # Linux
# Or run inline for testing:
/bin/node dist/index.js
```

## OneCLI vault topology

The vault (secrets, agents, allowlists, rules) lives in Docker volumes
`onecli_pgdata` and `onecli_app-data` — VM-local, not git-tracked. This
section is the source of truth for what needs to be in the vault for this
instance to function. Update this table *before* running the OneCLI
commands so it never lags reality.

### Secrets

| Name | Type | Host pattern | Path pattern | Injection | Source for value |
|---|---|---|---|---|---|
| `Anthropic` | `anthropic` | `api.anthropic.com` | — | (built-in `x-api-key`) | Anthropic console |
| `Auggie MCP (MintMCP)` | `generic` | `app.mintmcp.com` | `/o/luxury-presence/s/auggie-prd-api/*` | `Authorization: Bearer {value}` | MintMCP gateway → `auggie-prd-api` |
| `Notion MCP (MintMCP)` | `generic` | `app.mintmcp.com` | `/o/luxury-presence/s/com-notion-mcp/*` | `Authorization: Bearer {value}` | MintMCP gateway → `com-notion-mcp` |
| `Linear — Full Access` | `generic` | `mcp.linear.app` | — | `Authorization: Bearer {value}` | Linear → Settings → Account → Security & Access (full scope) |
| `Linear — Read Only` | `generic` | `mcp.linear.app` | — | `Authorization: Bearer {value}` | Linear → Settings → Account → Security & Access (read-only scope) |

For non-Anthropic bearer entries the canonical flag set is `--type generic
--header-name Authorization --value-format "Bearer {value}"`. The legacy
`--type bearer` shown in older docs no longer exists.

**Path patterns disambiguate secrets that share a host.** Both Auggie and
Notion live behind `app.mintmcp.com` (LP's MintMCP gateway routes multiple
upstream MCPs through one host); each gets its own `--path-pattern` so
OneCLI injects the correct bearer per upstream. Do the same any time you
add another MintMCP-hosted MCP server.

### Per-agent allowlists

All three agents run in `secretMode: selective`. Two secrets share the
`mcp.linear.app` host pattern (Linear full vs. read-only), so the
per-agent allowlist (set via `onecli agents set-secrets --secret-ids ...`)
is what determines which Linear key each agent gets injected.

|  | `cli-with-luis` | `clanq-dm` | `clanq-channels` |
|---|---|---|---|
| `Anthropic` | ✓ | ✓ | ✓ |
| `Auggie MCP (MintMCP)` | ✓ | ✓ | ✓ |
| `Notion MCP (MintMCP)` | ✓ | ✓ | ✓ |
| `Linear — Full Access` | ✓ | ✓ | — |
| `Linear — Read Only` | — | — | ✓ |

**Why the Linear split:** `clanq-channels` serves public Slack channels
(e.g. `#bots`). The read-only Linear key prevents anyone in those channels
from asking Clanq to file/edit/comment on Linear under the operator's
identity. DM and CLI agents are operator-only and get full access.

**Each agent should have at most one secret per (host pattern, path
pattern) tuple in its allowlist.** OneCLI's matching behavior with
multiple matches is undefined; keep the allowlist scoped. When two MCP
services share a host (like the MintMCP gateway), use distinct path
patterns on each secret so they don't both match the same request.

### Replay on fresh VM

```bash
# A. Create the secrets — values come from your password manager / source pages
onecli secrets create --name "Anthropic" --type anthropic \
  --host-pattern "api.anthropic.com" --value "<anthropic-key>"

onecli secrets create --name "Auggie MCP (MintMCP)" --type generic \
  --host-pattern "app.mintmcp.com" \
  --path-pattern "/o/luxury-presence/s/auggie-prd-api/*" \
  --header-name "Authorization" --value-format "Bearer {value}" \
  --value "<auggie-mintmcp-key>"

onecli secrets create --name "Notion MCP (MintMCP)" --type generic \
  --host-pattern "app.mintmcp.com" \
  --path-pattern "/o/luxury-presence/s/com-notion-mcp/*" \
  --header-name "Authorization" --value-format "Bearer {value}" \
  --value "<notion-mintmcp-key>"

onecli secrets create --name "Linear — Full Access" --type generic \
  --host-pattern "mcp.linear.app" \
  --header-name "Authorization" --value-format "Bearer {value}" \
  --value "<linear-full-key>"

onecli secrets create --name "Linear — Read Only" --type generic \
  --host-pattern "mcp.linear.app" \
  --header-name "Authorization" --value-format "Bearer {value}" \
  --value "<linear-readonly-key>"

# B. Send the first message to each agent group so onecli.ensureAgent()
#    registers them. (Otherwise `onecli agents list` is empty.)

# C. Collect IDs
onecli agents list   # find each agent's OneCLI id by `identifier` (matches NanoClaw agent_groups.id)
onecli secrets list  # find each secret's id by name

# D. Pin allowlists per the matrix above
CLI_ID=...      # ag-...-q7bzc9 (Terminal Agent / cli-with-luis)
DM_ID=...       # ag-...-3evq8l (Clanq / clanq-dm)
CH_ID=...       # ag-...-w619cf (Clanq / clanq-channels)
ANTHROPIC=...
AUGGIE=...
NOTION=...
LIN_FULL=...
LIN_RO=...

for AID in "$CLI_ID" "$DM_ID"; do
  onecli agents set-secret-mode --id "$AID" --mode selective
  onecli agents set-secrets --id "$AID" --secret-ids "$ANTHROPIC,$AUGGIE,$NOTION,$LIN_FULL"
done
onecli agents set-secret-mode --id "$CH_ID" --mode selective
onecli agents set-secrets --id "$CH_ID" --secret-ids "$ANTHROPIC,$AUGGIE,$NOTION,$LIN_RO"
```

### Drift check

```bash
for AID in "$CLI_ID" "$DM_ID" "$CH_ID"; do
  echo "=== $AID ==="
  onecli agents secrets --id "$AID"
done
```

Cross-reference the returned IDs against `onecli secrets list` by name.

## Adding a new agent group / channel later

After `/manage-channels` (or a manual `setup register` call) creates new
DB entities and group config files on this VM:

1. Update `scripts/seed-instance.ts` with the new entries in `AGENT_GROUPS`,
   `MESSAGING_GROUPS`, and `WIRING`. (Owner roles rarely change.)
2. `git add` the new `groups/<folder>/CLAUDE.local.md` and `container.json`.
3. **Add a column to the OneCLI per-agent allowlist matrix** above. At
   minimum the new agent needs `Anthropic`; mark whichever MCP secrets
   apply per the `mcpServers` block in its `container.json`. Then on this
   VM, run `onecli agents set-secret-mode --mode selective` and
   `onecli agents set-secrets --secret-ids ...` for the new agent — the
   matrix is the source of truth for what to set.
4. Commit. The fresh-VM bootstrap will then include the new agent group.

## Adding a new MCP server / secret later

When wiring a new MCP server (e.g. Hex, GitHub, Notion, another HTTP MCP):

1. Add the secret to the OneCLI vault — `onecli secrets create --type
   generic --host-pattern <host> --header-name Authorization --value-format
   "Bearer {value}" --value "<token>"` (or `--type anthropic` for Anthropic
   keys). See `docs/adding-mcp-servers.md` for the full pattern A/B/C
   recipes.
2. **Add a row to the Secrets table** above with name, type, host pattern,
   injection format, and where the value comes from.
3. **Add a row to the Per-agent allowlists matrix** and mark ✓ / — for
   each agent. Default to ✓ for all groups unless there's a concrete
   safety reason to scope down (see the Linear full/read-only split).
4. Update each opted-in group's `groups/<g>/container.json` with the
   `mcpServers.<name>` entry.
5. For each opted-in agent on this VM, re-run `onecli agents set-secrets
   --secret-ids ...` with the **full allowlist including the new secret**.
   `set-secrets` replaces the list entirely; it does not append. Look the
   list up from the matrix.
6. Restart any running containers so the new MCP wiring is read at spawn:
   `docker ps --filter "label=nanoclaw-install=<install-hash>"` →
   `docker rm -f <id>`.
7. Commit container.json + the doc updates together.

**Avoid two secrets on the same host pattern in the same agent's
allowlist** — OneCLI's multi-match behavior is undefined. If you need
different access levels per agent (like Linear), split into two secrets
and use the matrix to pin one per agent.

## What gets you the same Slack bot, not just the same wiring

The seed reproduces the **NanoClaw side** of the install: which agent group
handles which channel, with what session/engage/policy modes. It does not
reproduce the **Slack app**:

- The Slack app at api.slack.com/apps (bot scopes, event subscriptions,
  signing secret, install) is workspace-bound and external to this repo.
- A new VM pointing at the same Slack app will route messages from the same
  Slack channels to the rebuilt agent groups, because `platform_id` values
  in `MESSAGING_GROUPS` (e.g. `slack:D0B0VTX5KMX`, `slack:C0B0FK02MRV`) are
  Slack-side IDs that don't change.
- A new Slack workspace would require a new app install and updated
  platform IDs.

## Sanity check after bootstrap

```bash
# Entities exist
sqlite3 data/v2.db "SELECT folder FROM agent_groups; SELECT channel_type, platform_id FROM messaging_groups;"

# Owner role wired
sqlite3 data/v2.db "SELECT user_id, role FROM user_roles WHERE role='owner';"

# Group folders are in place with system prompts + container config
ls groups/cli-with-luis/CLAUDE.local.md groups/cli-with-luis/container.json
ls groups/clanq-dm/CLAUDE.local.md      groups/clanq-dm/container.json
ls groups/clanq-channels/CLAUDE.local.md groups/clanq-channels/container.json

# LP shared context cloned and reachable
ls data/shared/pm-shared-context/CLAUDE.md

# Mount allowlist permits data/shared
jq '.allowedRoots[].path' ~/.config/nanoclaw/mount-allowlist.json

# OneCLI vault matches the topology table
onecli secrets list   # all secrets in the matrix above present by name
onecli agents list    # all 3 agents present, each in `secretMode: selective`
for AID in $(onecli agents list 2>/dev/null | jq -r '.data[].id'); do
  echo "=== $AID ==="
  onecli agents secrets --id "$AID"
done
# Cross-reference returned secret IDs against `onecli secrets list` to
# confirm each agent's allowlist matches the matrix.
```

## Adding more LP shared repos later

To pre-clone a second LP repo and have it appear under `/workspace/extra/shared/<repo>/`:

1. `gh repo clone luxurypresence/<repo> shared/<repo>` on the host.
2. Update `container/CLAUDE.md` with pointers into `shared/<repo>/<path>` so agents know what's in there.
3. No `container.json` or allowlist changes needed — the existing `shared` mount picks up new subdirectories automatically.
