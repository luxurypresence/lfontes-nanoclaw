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
#    Run /init-onecli or follow docs/onecli.md. Vault state is on the host
#    filesystem outside this repo and must be re-imported per VM.

# 7. LP shared context — pre-clone the read-only LP repos that get mounted
#    into agent containers. Add more repos here as you start using them.
mkdir -p data/shared
gh repo clone luxurypresence/pm-shared-context data/shared/pm-shared-context
# (gh must already be authed on the host: `gh auth status`)

# 8. Mount allowlist — grant the host permission to mount data/shared/ into
#    containers. Empty allowlist = all additional mounts blocked. The path
#    is relative; the host resolves it against its cwd (project root).
mkdir -p ~/.config/nanoclaw
cat > ~/.config/nanoclaw/mount-allowlist.json <<'EOF'
{
  "allowedRoots": [
    {
      "path": "data/shared",
      "allowReadWrite": false,
      "description": "Host-cloned LP context repos, mounted read-only into agent containers."
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

## Adding a new agent group / channel later

After `/manage-channels` (or a manual `setup register` call) creates new
DB entities and group config files on this VM:

1. Update `scripts/seed-instance.ts` with the new entries in `AGENT_GROUPS`,
   `MESSAGING_GROUPS`, and `WIRING`. (Owner roles rarely change.)
2. `git add` the new `groups/<folder>/CLAUDE.local.md` and `container.json`.
3. Commit. The fresh-VM bootstrap will then include the new agent group.

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
```

## Adding more LP shared repos later

To pre-clone a second LP repo and have it appear under `/workspace/agent/shared/<repo>/`:

1. `gh repo clone luxurypresence/<repo> data/shared/<repo>` on the host.
2. Update `container/CLAUDE.md` with pointers into `shared/<repo>/<path>` so agents know what's in there.
3. No `container.json` or allowlist changes needed — the existing `data/shared` mount picks up new subdirectories automatically.
