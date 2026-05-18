# Migration from Claude Code

The selling-point doc. The pitch: **your local Claude Code workflow runs in
the VM, with the same skills, subagents, MCP servers, and CLAUDE.md memory
you already have.**

Pi is the v1 harness (see `harness-selection.md`), and Pi's config format is
strikingly close to Claude Code's — same `settings.json` filename, same
skills convention, same MCP server shape via `mcp.json`. The importer is a
translation pass, not a transformation.

## The honest pitch

> "Bring your Claude Code config to your VM. Skills, subagents, MCP servers,
> and CLAUDE.md memory port verbatim. Settings get a curated subset. TUI-only
> things drop. The model picker is yours."

This is "your Claude Code workflow in the cloud," not "your Claude Code
binary in the cloud." Pi mimics Claude Code's surface but runs against any
model backend. For users who specifically want the literal Claude Code
binary running headlessly, that's the future `claude -p` harness path —
documented in `harness-selection.md`.

## Two paths: mount or import

Since we committed to subprocess-only harness integration (see
`design-principles.md` principle 10 and `harness-selection.md`), there
are actually two ways to bring your Claude Code config into a zone, and
the operator picks per zone:

| Path | What happens | When to use |
|------|--------------|-------------|
| **Mount** | Mount `~/.claude/` (or a copy of it) read-only into the container at the path the harness expects. Harness reads it directly, no translation. | When the harness format matches Claude Code's natively — i.e. **`claude -p` headless** uses `~/.claude/` as-is, **Pi** is close enough that mounting often works (with a thin override layer for Pi-specific keys). Operationally simplest. |
| **Import** | Run `ncl import-claude-code --to <zone>`. Translates `~/.claude/` into a zone-owned config that lives under `<data_dir>/zones/<zone>/`. The container mounts only that translated config. | When you want isolation between local and VM (changes in one don't affect the other), when you want to redact/route secrets through the credential-proxy, or for harnesses with their own config format (Codex, OpenCode, future additions). |

**Recommended default**:
- For **`claude -p`** zones → mount. The whole point of using `claude -p`
  is "literally Claude Code in the cloud"; mounting `~/.claude/` makes
  that one-to-one.
- For **Pi** zones → import. Pi's format is close but not identical, and
  the importer is where we redact secrets and warn about TUI-only keys.
  Mounting works too if you want to skip the translation tax — operator's
  call.
- For **other harnesses** → import (translate to that harness's format)
  or write your own mount-mapping if the formats happen to align.

The rest of this doc covers the import path. The mount path is mostly
"docker volume mount the right directory" plus a small set of zone-config
fields naming where each harness expects to find its config. Spec'd out
in `investigations/08-trust-zone-provisioning.md`.

## What ports verbatim

| From `~/.claude/...` | To VM equivalent | Notes |
|----------------------|------------------|-------|
| `skills/<name>/SKILL.md` | `<zone>/skills/<name>/SKILL.md` | Frontmatter convention is identical (`name`, `description`, `requires`, etc.). |
| `skills/<name>/resources/*` | `<zone>/skills/<name>/resources/*` | Helper files travel with the skill. |
| `agents/*.md` (subagents) | `<zone>/agents/*.md` | Pi has a managed-skills concept that absorbs subagents the same way. |
| MCP servers from `~/.claude.json` / `~/.claude/mcp_servers.json` | `<zone>/mcp.json` | One-to-one mapping: `command`, `args`, `env`. HTTP/streamable-HTTP servers translate cleanly. |
| `~/.claude/CLAUDE.md` (user-level memory) | `<zone>/CLAUDE.md` | Loaded the same way by Pi. |
| Per-project `CLAUDE.md` | Per-workspace `CLAUDE.md` under `<zone>/workspaces/<name>/` | If the operator wants project-specific memory in the VM. |

## What gets translated

| From | To | Translation |
|------|----|-------------|
| `~/.claude/settings.json` keys: `permissions`, `env`, `hooks`, `model`, `theme` | Pi `settings.json` (subset) | `permissions` maps to Pi's tool allowlist. `env` ports verbatim. `hooks` translate where Pi has equivalents (post-edit, pre-tool, etc.) and log a warning where it doesn't. `model` ports as-is. `theme` drops (TUI-only). |
| `statusLine` configuration | Drop | TUI-only. Will warn in the importer output. |
| `outputStyle` (e.g. compact) | Pi's output style enum if mappable | Likely drop or default. |
| Keybindings | Drop | TUI-only. |

## What gets dropped

- `~/.claude/projects/` JSONL session files. The VM has its own session
  storage in the container's local SQLite. There's no point importing prior
  Claude Code chat history; conversations live where they live.
- Plugin marketplace installs (`~/.claude/plugins/`). Pi has its own
  extension model; plugins don't port. The importer can list them in the
  output so the user knows what to re-enable manually.
- `.claude.json` per-project entries that aren't MCP servers (e.g., IDE
  diagnostics config). TUI-only.
- IDE integrations (`/ide`, the VS Code extension state). N/A in the VM.

## The importer CLI

A subcommand of the host's admin CLI (eventual name TBD; sketched as
`ncl` here for consistency with NanoClaw's naming):

```bash
ncl import-claude-code [--from ~/.claude] [--to <zone-name>] [--dry-run]
```

Behavior:
- **Default `--from`:** `~/.claude` (or `$CLAUDE_HOME` if set).
- **`--to <zone>`:** which trust zone to import into. Required when more than
  one zone exists; defaults to the only zone if there's just one.
- **`--dry-run`:** print what would be copied, what would be translated, what
  would be dropped. No side effects.
- **Idempotent:** running twice is safe. Existing files in the target zone
  with the same path are skipped unless `--overwrite` is passed (with a
  diff shown first).

Output format (sample):

```
=== Importing ~/.claude → zone "dm-trust" ===

Verbatim (4):
  ✓ skills/lp-research/                                → dm-trust/skills/lp-research/
  ✓ skills/clanq-tickets/                              → dm-trust/skills/clanq-tickets/
  ✓ agents/code-reviewer.md                            → dm-trust/agents/code-reviewer.md
  ✓ CLAUDE.md                                          → dm-trust/CLAUDE.md

Translated (2):
  ⇄ MCP server "notion"                                → dm-trust/mcp.json (notion entry)
  ⇄ settings.json:permissions.allow (12 entries)       → dm-trust/settings.json:tools.allow

Dropped (3):
  ✗ statusLine.command                                 (TUI-only)
  ✗ plugins/marketplace.json                           (Pi has its own extension model — re-enable manually)
  ✗ theme                                              (TUI-only)

Warnings (1):
  ⚠ hook "post-edit-prettier" — Pi has no equivalent hook; consider porting as a skill
```

## Format-translation specifics

### SKILL.md frontmatter

Claude Code's SKILL.md uses YAML frontmatter:

```yaml
---
name: lp-research
description: Find LP repo, branch, ticket context
---
```

Pi's frontmatter is functionally identical. Importer copies the file
verbatim. Edge case: Claude Code has a `requires` field convention that
some skills use; Pi will need that field interpreted (see
`investigations/02-skill-tool-declaration.md` for the zone-aware version
of this).

### MCP server config

Claude Code stores MCP servers in `~/.claude.json` (global) and per-project
in `.mcp.json` files. Shape:

```json
{
  "mcpServers": {
    "notion": {
      "command": "npx",
      "args": ["@notionhq/notion-mcp-server"],
      "env": { "NOTION_TOKEN": "secret_..." }
    }
  }
}
```

Pi expects `mcp.json` (no `Servers` wrapper key in the most recent docs):

```json
{
  "notion": {
    "command": "npx",
    "args": ["@notionhq/notion-mcp-server"],
    "env": { "NOTION_TOKEN": "secret_..." },
    "lifecycle": "lazy"
  }
}
```

Translation: unwrap, optionally add `lifecycle: "lazy"` as a default,
preserve everything else. **Importantly: do not copy raw secrets into the
zone config file.** The importer should detect environment-variable-shaped
values and either redact them (replacing with `"${ENV_VAR}"` references) or
route them through `request_credential` per
`investigations/08-trust-zone-provisioning.md`.

### settings.json keys

Claude Code's `settings.json` has accumulated a lot of keys. Importer
handles the subset that's meaningful headless:

| Claude Code key | Pi equivalent | Action |
|-----------------|---------------|--------|
| `permissions.allow` / `permissions.deny` | Pi tool allowlist | Translate |
| `env` | Pi `env` | Port |
| `hooks` | Pi `hooks` (or skill) | Port where equivalent exists |
| `model` | Pi `model` | Port |
| `mcpServers` | `mcp.json` | Move (see above) |
| `theme`, `statusLine`, `outputStyle`, keybindings | — | Drop, warn |

## Security: credentials must not leak through

The importer reads files that may contain plaintext secrets (`MCP_TOKEN`
values, OAuth tokens hardcoded in env blocks, API keys). It MUST:

1. Detect secret-shaped values in `env` blocks (heuristic: short hex/base64
   strings, known prefixes like `sk-`, `ghp_`, `xoxb-`).
2. Refuse to write those verbatim into the target zone's config.
3. Either route them through OneCLI-style credential proxy (if installed)
   or write a placeholder and prompt the operator to provide them via
   `ncl credentials set <name>`.

This isn't optional. The whole point of the trust-zone model is that
credentials are zone-bound, not skill-bound or config-bound.

## What the operator sees

After `ncl import-claude-code --to dm-trust` completes, the operator runs
their existing workflow. The Slack DM that arrives gets handled by an
agent that has all the same skills, subagents, MCP tools, and memory they
had in their local Claude Code. The model can be the same Sonnet 4.6
they were using, or different — that's a per-zone setting now.

The "first message after import" feels identical. That's the pitch.

## Open sub-questions

- **Plugin marketplace handling.** Claude Code has a growing plugin
  marketplace; Pi has its own extension model. Plugins don't auto-port.
  Should the importer scan for installed plugins and produce a "you'll
  want to re-enable these in Pi" list? Probably yes, at minimum.
- **Subagent semantics drift.** Claude Code subagents are invoked via the
  `Task` tool with a specific name. Pi's managed-skills cover the same
  ground but the invocation surface may differ. Need a one-pass test on a
  real subagent to confirm round-trip.
- **Hooks coverage.** Claude Code's hooks (pre-tool, post-tool, etc.) may
  or may not all have Pi equivalents. List the ones I use (`post-edit`,
  any in `~/.claude/hooks/`) and verify each.
- **Two-way sync.** Out of scope for v1, but: should changes made in the
  VM (e.g., a skill the agent self-installs) be exportable back to
  `~/.claude/` for local use? Probably "later, with explicit operator
  command" — not automatic.

## Why this is the right v1 selling point

Most personal-AI-agent projects ship with a blank slate. "Install our
framework, then configure it from zero." That's a huge activation cost,
and most people bounce.

A user who already has Claude Code configured — skills they wrote, MCP
servers they connected, agents they tuned — has invested real time in that
configuration. **Letting them lift it into a VM in one command means they
get value on day one.** The friction of "I have to recreate everything"
disappears. The framework feels like a continuation of their workflow,
not a replacement.

Pi-as-default + the format proximity makes this practical. With Agent SDK
as default, the importer would be harder; with Claude Code headless as
default, the host install footprint would be bigger. Pi is the sweet spot.
