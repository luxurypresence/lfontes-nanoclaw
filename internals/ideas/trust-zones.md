# Trust zones

The container model in detail. Refines principle 1 of `design-principles.md`.

## The model in one paragraph

A **trust zone** is a named bundle of (credentials, tool binaries, mounts,
optional skills). One Docker container per trust zone, long-lived, hosting
the agent runtime. The router maps every inbound message to exactly one
trust zone based on **sender identity** (with the channel as a fallback
input only). Once a message is in a zone's container, the agent has access
to everything in that zone — no further capability checks.

## My zones

Initial set, for me:

| Zone | Use case | Credentials | Notable tools | Skills |
|------|----------|-------------|---------------|--------|
| `dm-trust` | Me typing in DM, or me typing as me anywhere | gh PAT (rw), Slack bot token, vault access, all OAuth tokens | gh, vercel CLI, claude-code, agent-browser, full fs RW on `/workspace` | Full skill set |
| `public-trust` | Everyone else, public surfaces | gh PAT (read-only), no Slack send-as-me, no OAuth, no vault | gh (read-only), web-search, agent-browser (no scripting), fs RO on `/workspace` | Reduced skill set — read/research/help only |

That's the whole zone roster. If a third zone is ever needed (e.g.,
"trusted-collaborators"), it's another container with its own credential
set. Don't add a zone speculatively.

## Data model

Live in the central SQLite, exposed via the host RPC:

```sql
CREATE TABLE trust_zones (
  id            TEXT PRIMARY KEY,        -- 'dm-trust', 'public-trust'
  display_name  TEXT NOT NULL,
  description   TEXT,
  container_name TEXT NOT NULL,           -- docker container name
  rpc_token     TEXT NOT NULL,            -- the only credential the container has TO REACH THE HOST
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Sender → zone mapping. Catch-all is a row with sender_id = '*'.
CREATE TABLE zone_assignments (
  sender_id     TEXT NOT NULL,            -- 'slack:U123', 'github:luisfontes', or '*'
  zone_id       TEXT NOT NULL REFERENCES trust_zones(id),
  priority      INTEGER NOT NULL DEFAULT 0,  -- higher wins if multiple match
  PRIMARY KEY (sender_id, zone_id)
);

-- Channel override: if a channel is hard-restricted to one zone regardless
-- of sender (e.g., a "support inbox" that must stay public-trust even when
-- I'm the one replying). Optional; usually NULL.
CREATE TABLE channel_zone_overrides (
  channel_id    TEXT PRIMARY KEY,         -- 'slack:T123:C456'
  zone_id       TEXT NOT NULL REFERENCES trust_zones(id)
);
```

Router resolution order:
1. If the channel has a `channel_zone_overrides` row, use that zone. Done.
2. Look up the sender in `zone_assignments`. If found, use highest-priority match.
3. Fall back to `sender_id = '*'` (the catch-all row → `public-trust`).

This is deliberately simple. No expressions, no regexes, no rule engine.
Two tables, a clear precedence, and a default. If the resolution needs to
get more sophisticated, the router function gets a `case` block — but I'm
not going to design for that.

## Identity collapse

`slack:U123`, `github:luisfontes`, `discord:luis#0001` should all be one
human → one zone. See `investigations/03-identity-collapse.md` for the
data model that makes this work without scattering `OR sender_id=...` all
over the place.

Short answer: a `user_aliases` table that resolves any platform-specific
ID to a canonical user ID, and `zone_assignments` keys off the canonical
ID. The router does one lookup `platform_id → canonical_id` before the
zone resolution above.

## What's in a zone container

Provisioning surface (each zone has its own Dockerfile or compose service):

- **Base image** — same for all zones, the agent runtime + OS deps.
- **Layered credentials** — env-injected at container start from a
  zone-specific source. For my install, probably a per-zone `.env.zone`
  file the host loads and passes via Docker env, or OneCLI-style proxy
  injection. See `investigations/08-trust-zone-provisioning.md`.
- **Layered tool binaries** — installed by Dockerfile or post-start setup
  script. Read-only PATs vs read-write PATs are the canonical example.
- **Mounts** — read-only or read-write `/workspace` depending on zone.
  No cross-zone mounts ever.
- **Skill set** — same skills directory in every zone, but the skill
  declaration may opt out of zones (`available_in: [dm-trust]`) or the
  router may filter at prompt-assembly time.

## What's *not* in a zone

- **The host's DB.** Containers never see central SQLite. Everything goes
  through RPC.
- **Other zones' credentials.** Strict per-container env injection.
- **The host filesystem outside the zone's declared mounts.** Plain Docker
  isolation does this for free.

## Routing example

I send "deploy the dashboard" in a public Slack channel where Clanq is wired.

```
event: slack:T123:C456 from slack:U_luis
  ↓ router
  channel_zone_overrides[slack:T123:C456] = NULL  (no override)
  user_aliases[slack:U_luis] = user:luis
  zone_assignments WHERE sender_id IN ('user:luis', '*') ORDER BY priority DESC
    → user:luis → dm-trust (priority 10)
    → *        → public-trust (priority 0)
  pick: dm-trust
  ↓ wake or signal dm-trust container
  ↓ enqueue message in host queue, scoped to dm-trust's worker
  ↓ container claims via RPC, runs Claude SDK, deploys
```

Someone else writes "deploy the dashboard" in the same channel:

```
event: slack:T123:C456 from slack:U_someone_else
  ↓ router
  user_aliases[slack:U_someone_else] = NULL  (unknown identity)
  zone_assignments WHERE sender_id IN ('slack:U_someone_else', '*')
    → only the '*' catch-all → public-trust
  pick: public-trust
  ↓ wake or signal public-trust container
  ↓ container can answer "what's the dashboard?" but has no deploy creds
```

Same channel, same message text, different zones — because trust is
identity-driven.

## Idle wake

Containers stay running. When idle they should drop close to zero CPU.
When a message lands, the host signals the container's worker via RPC
(or the container long-polls — see `investigations/04-idle-wake.md`).

Lifecycle:
- **Cold start:** host `docker start` at boot or first message ever.
- **Warm:** container is up, agent runtime is idle. Latency: just the
  Claude SDK call.
- **Cycle context:** restart the agent runtime *inside* the container
  without restarting Docker. See `investigations/05-process-cycle.md`.
- **Shutdown:** only on explicit operator action or host shutdown.

## Compared to NanoClaw

| NanoClaw | This design |
|----------|-------------|
| One container per **session** | One container per **trust zone** |
| Container is spawned on first message, exits idle | Container is long-lived, idles in place |
| Routing key: `(agent_group, messaging_group, thread)` | Routing key: `(sender_id, channel)` → zone |
| Capability bundle: `agent_groups.container_config` | Capability bundle: `trust_zones.*` |
| Sender-identity routing: bolted on via `/add-sender-routing` (per-wiring `sender_match` column) | Sender-identity routing: the primary axis |
| ~50 containers if you have 50 active conversations | 2 containers, period |
| Container has its own SQLite, mounted by host | Container has its own SQLite, host never touches it |
| Capabilities scoped per agent group | Capabilities scoped per zone |

See `../06-sender-routing.md` for how the fork already partially expresses
this model on top of NanoClaw, and what would need to move to make it the
primary axis.

## Open sub-questions

Most of these are tracked as their own investigation files:

- How are zone Dockerfiles structured? Shared base + layered overlays?
  Compose? See `investigations/08-trust-zone-provisioning.md`.
- How does the host signal an idle container? See
  `investigations/04-idle-wake.md`.
- How do skills declare which zones they're available in? See
  `investigations/02-skill-tool-declaration.md`.
- How do multi-platform identities collapse to one canonical user? See
  `investigations/03-identity-collapse.md`.
