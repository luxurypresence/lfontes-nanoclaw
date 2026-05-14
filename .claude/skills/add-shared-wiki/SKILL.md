---
name: add-shared-wiki
description: Wire the lfontes-mono wiki + skills tree into all nanoclaw agent groups. Mounts wiki/ at /workspace/extra/wiki (neutral path — agent doesn't see the lfontes-mono name); copies a curated subset of lfontes-mono/skills/ into nanoclaw/container/skills/ via a sync script and whitelists them in each group's container.json. Triggers on "add shared wiki", "set up shared wiki", "wire lfontes-mono", "shared wiki", "global wiki", "wiki for all groups".
---

# Add Shared Wiki

Wire the wiki + a curated subset of skills from `~/lfontes-mono/{wiki,skills}` into every nanoclaw agent group. The wiki stays mounted RW for live capture; skills get **copied** into nanoclaw via a sync script and loaded via the standard `skills` whitelist in `container.json` — no fork patch.

**Naming discipline.** Inside the container, the wiki is mounted at `/workspace/extra/wiki` (no `lfontes-mono` in the path) and reached via `$WIKI_ROOT`. The agent should not learn the wiki originates from a host repo called `lfontes-mono` — that name only confused Clanq into searching the wiki when asked about unrelated repo work. `$LFONTES_MONO_ROOT` is deliberately *not* set inside containers; it's a host-only convenience for skills that navigate the full lfontes-mono tree.

## What this builds

```
~/lfontes-mono/                              # canonical, untouched by this skill
  wiki/{index,log,conventions,capture,repo-map,auggie-anatomy}.md
       domains/<slug>.md
       data/{analytics-anatomy,core-schemas,gotchas,query-patterns}.md
  skills/{navigator,data,auggie,builder,work}/{SKILL.md, references/, ...}
  .claude/skills/<n> → ../../skills/<n>      # symlinks (already shipped)

~/nanoclaw/
  groups/<group>/container.json    # adds wiki mount + skills whitelist  (NEW)
  container/skills/<n>/            # SYNCED COPIES from lfontes-mono     (NEW, gitignored)
  scripts/sync-shared-skills.ts    # the sync script                     (already exists)
  .gitignore                       # add the synced skill dirs           (NEW)
```

Each container sees the wiki at `/workspace/extra/wiki/` (RW for capture). Skills load via the standard `~/.claude/skills/` mechanism from `nanoclaw/container/skills/`. `WIKI_ROOT=/workspace/extra/wiki` is baked into the agent image so SKILL.md path resolution works without per-group env plumbing.

## Preflight

```bash
test -d /home/exedev/lfontes-mono                            && echo OK || echo "lfontes-mono missing — abort"
test -d /home/exedev/lfontes-mono/wiki                       && echo OK || echo "wiki/ missing — user must run lfontes-mono migration first"
test -d /home/exedev/lfontes-mono/skills/navigator           && echo OK || echo "skills/navigator missing"
test -d /home/exedev/lfontes-mono/skills/data                && echo OK || echo "skills/data missing"
test -L /home/exedev/lfontes-mono/.claude/skills/navigator   && echo OK || echo "expected .claude/skills/navigator to be a symlink — abort"
test -d /home/exedev/nanoclaw                                && echo OK || echo "nanoclaw missing — abort"
test -f /home/exedev/nanoclaw/scripts/sync-shared-skills.ts  && echo OK || echo "sync script missing — restore from git history"
grep -q "ENV WIKI_ROOT=" /home/exedev/nanoclaw/container/Dockerfile && echo OK || echo "Dockerfile missing WIKI_ROOT ENV"
```

If any check fails, stop and explain. Each step below is idempotent — re-running on a partially-set-up install is safe.

## Step 1 — Mount allowlist

The validator runs `fs.realpathSync` on the host path before checking the allowlist. Allow `/home/exedev/lfontes-mono` with read-write enabled (covers the wiki subpath via prefix match):

```bash
cat ~/.config/nanoclaw/mount-allowlist.json   # show current
# Then merge in:
#   { "path": "/home/exedev/lfontes-mono", "allowReadWrite": true, "description": "lfontes-mono shared wiki" }
# via /manage-mounts skill, or by editing the file directly with the merged JSON.
```

If the entry already exists with `allowReadWrite: true`, skip.

## Step 2 — Move bundled nanoclaw skills aside (vetting)

The bundled `nanoclaw/container/skills/{agent-browser,frontend-engineer,gh-cli,self-customize,slack-formatting,vercel-cli,web-search,welcome}` ship with nanoclaw and aren't vetted by Luis. Move them aside so they don't accidentally load via `skills: "all"` and so we have a clean `container/skills/` to drop synced lfontes-mono skills into:

```bash
mkdir -p /home/exedev/nanoclaw/container/skills-bundled
mv /home/exedev/nanoclaw/container/skills/{agent-browser,frontend-engineer,gh-cli,self-customize,slack-formatting,vercel-cli,web-search,welcome} \
   /home/exedev/nanoclaw/container/skills-bundled/
```

Idempotent: skip if `container/skills-bundled/` already has them.

## Step 3 — Sync lfontes-mono skills into nanoclaw

```bash
cd /home/exedev/nanoclaw
pnpm tsx scripts/sync-shared-skills.ts
```

Copies `~/lfontes-mono/skills/{auggie,builder,data,navigator,work}/` → `nanoclaw/container/skills/`, excluding `last-check.json`. Re-run after `git pull` in lfontes-mono to refresh.

Add to `.gitignore` if not already present:

```gitignore
container/skills/auggie/
container/skills/builder/
container/skills/data/
container/skills/navigator/
container/skills/work/
container/skills/conventions.md
```

The synced copies aren't tracked; lfontes-mono stays the single source of truth.

## Step 4 — Per-group `container.json`

For each of `clanq-dm`, `clanq-channels`, `cli-with-luis`:

1. Append the wiki mount to `additionalMounts` (preserve existing entries):

   ```json
   {
     "hostPath": "/home/exedev/lfontes-mono/wiki",
     "containerPath": "wiki",
     "readonly": false
   }
   ```

   Container path is auto-prefixed with `/workspace/extra/`, so the wiki lands at `/workspace/extra/wiki/` — matching `$WIKI_ROOT`. Do not put `lfontes-mono` in the containerPath; the agent should not see the host repo name.

2. Set `skills` to a whitelist of which lfontes-mono skills should load:

   ```json
   "skills": ["navigator", "data", "work"]
   ```

   (Add `auggie` / `builder` if you want them. Keep tight; only enable what's reviewed.)

Do NOT mount the whole lfontes-mono repo or `lfontes-mono/skills` — skills are now consumed by copy, not by mount.

## Step 5 — Wiki references in canonical skills

Skills in `~/lfontes-mono/skills/<name>/SKILL.md` that point at wiki content should use `$WIKI_ROOT`:

| Environment | `$WIKI_ROOT` resolves to |
|-------------|-------------------------|
| Inside nanoclaw container | `/workspace/extra/wiki` (set by Dockerfile ENV) |
| Host Claude Code | unset by default — the git-fallback pattern `${WIKI_ROOT:-$(git rev-parse --git-common-dir 2>/dev/null \| xargs dirname)/wiki}` resolves to `~/lfontes-mono/wiki` when cwd is anywhere inside the repo |

Skills that navigate the full lfontes-mono repo (e.g. navigator's repo-scope rules, `/repos/<name>` clones) keep using `$LFONTES_MONO_ROOT` with the same git-fallback. Inside the container these vars stay unset, so any reference goes inert — which is the correct outcome: the container shouldn't traverse the host monorepo.

The split:
- `$WIKI_ROOT/...` — wiki content, works in both environments
- `$LFONTES_MONO_ROOT/...` — host-only navigation, breaks loud inside the container

After editing the canonical sources, commit in lfontes-mono — the synced copy in nanoclaw stays stale until next `pnpm tsx scripts/sync-shared-skills.ts`.

## Step 6 — Build, restart, verify

```bash
cd /home/exedev/nanoclaw
pnpm run build
./container/build.sh
launchctl kickstart -k gui/$(id -u)/com.nanoclaw                       # macOS
# systemctl --user restart nanoclaw-v2-<install-hash>.service          # Linux user unit
```

Verify in a fresh session inside any group:

```
echo $WIKI_ROOT                                        # /workspace/extra/wiki
echo $LFONTES_MONO_ROOT                                # (empty — not set inside containers)
ls $WIKI_ROOT/                                         # wiki content
ls ~/.claude/skills/                                   # navigator, data, work (whitelisted)
readlink ~/.claude/skills/navigator                    # /app/skills/navigator (the synced copy)
ls ~/.claude/skills/navigator/references/              # access-paths.md, patterns.md, tools.md
cat $WIKI_ROOT/index.md                                # content catalog
```

Skill resolution on the host (running Claude Code outside the container) relies on the git-fallback pattern in the SKILL.md files themselves — no shell rc edits required as long as cwd is somewhere inside `~/lfontes-mono`.

## Refresh workflow

When skills change in lfontes-mono:

```bash
cd /home/exedev/lfontes-mono && git pull
cd /home/exedev/nanoclaw && pnpm tsx scripts/sync-shared-skills.ts
./container/build.sh                                    # rebuild image so containers pick up new files
# restart service to roll into running containers
```

## What this skill does NOT do

- No auto-commit. Wiki writes leave the lfontes-mono tree dirty; the user commits when ready.
- No semantic / vector search infrastructure. `wiki/index.md` + ripgrep is the search layer.
- No autonomous wiki lint scheduler.
- No `repos/` mount. Navigator can read its own SKILL.md but can't yet traverse `repos/<name>` from inside the container.
- No replacement of Claude Code's host-side auto-memory at `~/.claude/projects/-home-exedev-nanoclaw/memory/`. That stays as is, complementary to the shared wiki.
- No mount of pm-shared-context elsewhere. The existing `shared` mount stays RO and untouched.

## Post-install

If a new agent group gets created later, re-run this skill — Step 4 (the per-group container.json work) is idempotent. Steps 1, 2, 3, 5 detect their work is done and skip.
