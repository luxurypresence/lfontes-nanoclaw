# Host surface

The host should do more than NanoClaw does. Not OpenClaw-config-hell more,
but enough that the operator has visibility, sane defaults, and a place to
look when something is off. Containers stay pure sandboxes; everything an
operator needs to *see* lives on the host.

## The premise

NanoClaw runs religiously minimal on host UX:
- No central config file. Configuration is done via direct SQL inserts
  into `data/v2.db`.
- No dashboard. Operator visibility is `tail -f logs/nanoclaw.log` plus
  ad-hoc `sqlite3` queries.
- Health checks live in `setup/verify.ts` and run only during install.
- The `ncl` admin CLI is the only structured surface, and it's
  intentionally barebones.

This is fine if the author is the only user and they have the entire
codebase in their head. It's hostile to anyone else, including future-me
six months from now.

The opposite extreme — OpenClaw — turns into a config matrix where every
knob is settable and discoverability becomes the actual problem. That
fails differently but no less badly.

## New principle

> **Host owns visibility, not just durability.**

Containers run code. The host *shows* the operator what the code did,
what configs drove it, what's broken right now. This is a small addition
to the existing principle 5 ("Host owns durability; containers own
ephemera") — durability and visibility are the same axis.

Add to `design-principles.md`.

## What the host gains

Three surfaces, in priority order.

### 1. Single declarative config file

One TOML file at the repo root: `nanoclaw.toml` (or whatever the project
ends up named). Holds:

```toml
[host]
data_dir = "./data"
log_dir  = "./logs"
log_level = "info"
listen_socket = "./data/host.sock"

[harness]
default = "pi"
pi_binary_path = "pi"   # uses $PATH if relative

[zones.dm-trust]
display_name = "DM trust (Luis)"
container_image = "agent-base:latest"
extra_tools = ["gh", "vercel"]
env_file = "./config/.env.dm-trust"
mount_workspace = "rw"
harness = "pi"   # override default if needed

[zones.public-trust]
display_name = "Public trust (catch-all)"
container_image = "agent-base:latest"
extra_tools = ["gh"]
env_file = "./config/.env.public-trust"
mount_workspace = "ro"

[channels.slack]
enabled = true
webhook_path = "/webhook/slack"
# secrets loaded from env, not the toml

[audit]
retention = "forever"  # or "90d", "365d", etc.
prune_command_only = true

[dashboard]
enabled = true
bind = "127.0.0.1:7654"
read_only = true
```

Rules:
- **Sane defaults dominate.** A blank `nanoclaw.toml` with only the
  required two zones populated should give a working install. Every
  other key has a hard-coded default in the code.
- **No nested config hell.** Two levels deep maximum. If a setting needs
  three levels, it should be a separate file (e.g., `zone.yaml` per zone)
  but that's a future-me problem.
- **Mutable via CLI, never via dashboard.** The dashboard reads; `ncl`
  writes. This prevents the project from sliding into UI-as-config-system.
- **Reload-on-change** when reasonable. Zone changes require container
  restart (already known). Log-level changes hot-reload.

Identity for the file location, not for SQL-as-config: SQL is great for
ephemeral state (sessions, messages, audit events) and terrible for
operator configuration (you can't `git diff` it, can't comment lines,
can't grep for the schema). The TOML is the source of truth for "how the
system is configured"; the DB is the source of truth for "what the system
has seen and done."

### 2. Read-only dashboard

A single HTTP endpoint on the host, bound to localhost by default. Plain
HTMX over server-rendered HTML — no JS framework, no build step. ~500
LOC total target.

Pages:

| Path | Content |
|------|---------|
| `/` | Overview: zone status (running/stopped), recent activity per zone, queue depth, last 10 audit events |
| `/zones/<id>` | Zone detail: config (from TOML), container status, recent messages, recent audit events, recent tool calls |
| `/audit` | Audit log search: filter by zone, event type, sender, channel, time window |
| `/messages` | Recent inbound/outbound across zones with deeplinks to source channels |
| `/queue` | Honker queue state: pending jobs, in-flight, failures |
| `/config` | Read-only render of `nanoclaw.toml` (with secrets redacted) |
| `/health` | JSON endpoint for external monitoring (uptime, last-success-per-zone, queue lag) |

Anti-features (do not build):
- **Config editing.** Use `ncl` or edit the TOML by hand. Editing config
  via web UI is the OpenClaw failure mode.
- **Action triggers.** No "send a test message" or "restart a zone"
  buttons. Read-only.
- **Custom dashboards / saved queries.** Resist all featurism. If you
  want a custom view, query the audit table with `ncl audit query
  ...`. The dashboard is for at-a-glance, not deep work.
- **Authentication.** Bound to localhost only. If you want it remote,
  you put it behind your own SSH/reverse-proxy. The dashboard doesn't
  ship auth.

### 3. Observability primitives

Three things the host emits that any external tool can consume:

- **Structured logs** (JSON lines) to `logs/host.log` and the dashboard's
  `/messages` page. Each log line has `zone_id`, `level`, `category`,
  `payload`.
- **Audit events** (see `investigations/06-audit-events.md`) in the
  audit table. Queryable via `ncl audit query` and the dashboard.
- **Prometheus-compatible metrics** at `/metrics` (optional, behind a
  config flag). Per-zone gauges (queue depth, last-success-age, error
  rate). For users who want to plug into Grafana.

The audit table is the load-bearing piece. Logs are noisy and ephemeral;
audit events are deliberately curated and durable. The dashboard surfaces
both, but the audit table is what an operator actually consults to
answer "what did the agent do?"

## Discipline rules

The line between "useful host UX" and "config hell" is real. These rules
hold it:

1. **One file for config, one DB for state.** No third surface (no
   "groups directory with YAML files", no "per-zone overrides in a
   subfolder"). If config needs more structure, the TOML grows; it doesn't
   sprout siblings.
2. **Dashboard is read-only.** Adding a mutate button is a sign the
   feature should be a CLI command, not a UI element.
3. **No knob until two people ask for it.** v1 ships with hardcoded
   defaults for everything except zones, channels, and audit retention.
   Other knobs only get added when an actual second person asks.
4. **No dashboard-only features.** Anything the dashboard surfaces must
   also be queryable via CLI. The CLI is the more durable interface; the
   dashboard is convenience.
5. **Containers know nothing about the host's view.** Audit emission is
   one-way: container → host. Containers don't read the audit log, don't
   read the dashboard state, don't read the TOML. The host owns visibility;
   that asymmetry is the whole point.

## What does *not* live on the host

Just to be clear about the line:

- Conversation history (lives in the container's local SQLite)
- Tool execution state (container)
- Skill content (container, per zone)
- Agent runtime configuration that the agent itself owns (Pi's
  `settings.json` inside the container)
- Anything the agent self-modifies (memory files, CLAUDE.md edits)

The host knows *about* these via audit events ("agent edited CLAUDE.md")
but doesn't store them.

## Implementation order

1. **TOML config** (week 1). Parser, validator, defaults, hot-reload for
   log level. Replace SQL-inserts-as-config.
2. **`/health` JSON endpoint** (week 1). Simple, useful from day one.
3. **Audit table + `ncl audit query`** (week 2). Comes from
   `investigations/06-audit-events.md`. Container-side emission via RPC.
4. **Dashboard MVP** (week 3-4). `/`, `/zones/<id>`, `/audit`. HTMX over
   server-rendered HTML. No JS framework.
5. **Metrics endpoint** (week 5, optional). Behind a config flag.

## Open sub-questions

- **TOML or YAML?** TOML is friendlier for hand-editing (comments,
  string ergonomics, no indentation traps). YAML is more familiar to
  operators from K8s. Default to TOML; reconsider if there's pushback.
- **Where do channel secrets live?** Probably an `.env` file the TOML
  references, not the TOML itself (secrets shouldn't be in version
  control). The dashboard's `/config` page renders the TOML with secret
  references resolved but values redacted.
- **Multi-host?** Out of scope. The whole design is single-host. If
  someone wants to run multiple, they run multiple installs and the
  dashboard is per-host.
- **Versioning the config schema.** If we ever change TOML field names,
  how does the upgrade go? Probably: ship a `ncl config migrate` command
  per version bump, like DB migrations. Not v1 work.
