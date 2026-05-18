# Investigation: webhook fan-out across N VMs

## Question

Each VM runs one agent. If two agents are wired to Slack (or Discord),
Slack/Discord need to know about two webhook URLs — one per VM. What's
the cleanest way to set that up, and what's the operational tax at v1?

This is the "per-VM channel setup" friction the v2-flat user flagged
in the conversation. Worth nailing down concretely.

## Constraints (recap, brief)

- One trust profile = one VM. Two agents wired to Slack = two VMs,
  each receiving its own webhooks.
- Each VM has its own public URL via exe.dev HTTPS.
- Slack supports multiple event-subscription URLs per Slack app
  workspace via *socket mode* or *multiple Slack apps*, not a single
  Slack app routing to multiple webhooks.
- Discord supports gateway connections (one bot, one gateway client)
  or webhook URLs (per-channel, one URL each). Different surface.
- The operator (me) installs Slack apps via the Slack admin UI. Each
  install is a real human action.

## Slack — options

### Option A. One Slack app per agent

Create one Slack app per agent. Each app has its own bot token,
webhook URL, and event subscription URL. Install each separately.

```
slack-app-personal-dm   →   webhook → https://personal-dm.exe.dev/slack/events
slack-app-public-bot    →   webhook → https://public-bot.exe.dev/slack/events
```

**Pros:** Each agent has its own Slack identity (different bot
username, avatar, scopes). Real trust separation — if `public-bot`'s
token leaks, it doesn't compromise `personal-dm`. Setup-time clarity:
the operator literally sees two apps in the Slack workspace admin.

**Cons:** Each new agent is a new app install ritual. Slack permits
this; it's just operator time. Also: two bots showing up in DMs/channels
is more clutter (mostly fine but worth noting).

### Option B. One Slack app, two installations

Slack apps can be "distributed" and installed multiple times (once per
workspace usually, but with some patterns once per agent). This works
only if the agents are in separate Slack workspaces — same workspace
can only install a given app once.

For our case: typically one Slack workspace, multiple agents. So
this option doesn't really apply unless we have multiple workspaces.

### Option C. One Slack app + a thin router on a shared URL

A single Slack app, one webhook URL, points to a router process I run
*outside* the agent VMs (e.g., on a tiny Cloudflare Worker or a third
VM). Router inspects the message and forwards to the right agent VM.

**Pros:** One Slack app to manage. Operator-side simpler.

**Cons:** Introduces a new piece of infrastructure that wasn't on the
v2-flat principle list. The router becomes a single point of failure
and a place where trust-routing decisions happen *outside* the VMs.
The whole point of "VM = trust zone" is that trust resolution happens
at the network boundary, not in some upstream router. Re-introducing
the router brings back centralization without v1's benefits.

### Option D. Socket mode per agent (no webhooks at all)

Slack supports *socket mode* where the agent opens a WebSocket
connection to Slack and receives events over it. No public webhook
URL needed.

**Pros:** No HTTPS routing for inbound Slack events. The agent's VM
just needs outbound to Slack.

**Cons:** Still one Slack app per agent (each socket session has its
own app token). The dashboard still needs HTTPS for outbound use. So
this saves the inbound webhook URL but not the operator-side app
juggling. Worth using if exe.dev's HTTPS terminator has issues, but
otherwise neutral.

## Recommendation: Slack

**Option A.** One Slack app per agent. Documented in the operator
handbook as "yes, you create a Slack app for each agent — this is
the trust boundary working as intended."

The setup ritual is:

1. Slack admin → Create New App → name it after the agent.
2. Add bot scopes (`chat:write`, `app_mentions:read`, `im:history`,
   etc.).
3. Install to workspace.
4. Copy bot token + signing secret into `deploy/env-templates/<agent>.env.example`.
5. Configure event subscription URL: `https://<agent>.exe.dev/slack/events`.
6. Run `deploy/bootstrap.sh <agent>` which provisions the VM and
   writes the env file to `/etc/agent/env`.

~15 minutes per new agent. Annoying at N=5; tolerable at N≤3.

## Discord — options

Discord's API is shaped differently:

### Option A. One bot per agent

Same pattern as Slack — one bot application per agent. Each has its
own gateway connection (the bot keeps a WebSocket open to Discord).

**Pros / Cons:** Mirror Slack option A. Per-agent identity is clear;
each is a new bot install.

### Option B. One bot, multi-server scoping

A single Discord bot can be invited to multiple servers and respond
differently per server. Could be one bot answering for "personal-dm"
in some servers and "public-bot" in others.

**Cons:** Doesn't fit the trust model. If both VMs need to receive
the same Discord events, they'd compete for the same gateway
connection (Discord allows multiple shards but not multiple
unrelated processes sharing one bot identity). Single bot = single
gateway client; the gateway has to live on one VM.

### Recommendation: Discord

Option A. One bot per agent. Same operator ritual as Slack.

For Discord-channel-specific posts where webhook URLs (not gateway
events) are the API surface, the per-channel webhook URLs can point
at the right VM directly.

## Dashboard chat — no fan-out needed

The dashboard is per-VM. The dashboard's chat is `localhost`. No
external fan-out concerns.

## Operator-side mitigations

To make N-agent Slack setup less painful:

1. **`agent.config.toml`'s `channels.slack-dm` section** holds the
   workspace + scopes + allow_senders for each agent. Operator
   reviews this when setting up an agent.
2. **`deploy/templates/slack-manifest.json`** — a Slack App Manifest
   that pre-fills scopes and event subscriptions. The operator runs
   `agent-cli generate-slack-manifest <agent>` and pastes the JSON
   into Slack's manifest UI. Saves time on per-app setup.
3. **`deploy/bootstrap.sh`** prompts for the Slack tokens during VM
   bootstrap and writes them to `/etc/agent/env` directly.

These bring the per-agent Slack setup down to ~5 minutes once tooling
is in place. Still not zero; deliberately so. Setting up a new agent
is a deliberate trust-creation action.

## What we lose vs. v1

v1 (container-per-zone) had one set of channel adapters on the host.
A single Slack app's events fanned out to the right container based
on the router's identity resolution. New container = no new Slack app.

v2-flat's "trust boundary is the VM" decision means new VM = new
Slack identity. The cost is real; the trade is that the VM model is
dramatically simpler everywhere else.

This is **the trade we accepted in principle 1**, made concrete.

## Recommendation

- Slack: one app per agent, with App Manifest tooling to soften the
  ritual.
- Discord: one bot per agent, same pattern.
- Other channels (Telegram, WhatsApp, etc.): same pattern.
- Single-channel adapters like email (Resend) or SMS (Twilio): per-VM
  endpoint, per-VM credentials.

The framework supports this by having `agent.config.toml.channels`
be self-contained: each agent declares which channels it speaks,
with which credentials. No cross-agent routing.

## Open sub-questions

- **Slack App Manifest API.** Slack offers programmatic app creation.
  Worth using if it doesn't require enterprise auth. Need to check.
- **Multiple Slack workspaces.** If I have a personal workspace and
  a work workspace, do I want both agents on both? Probably not —
  separate workspaces map naturally to separate agents.
- **Discord gateway sharding.** If we ever have >2500 Discord
  servers (we won't), gateway sharding becomes a concern. Not at v1.
- **Operator UX for "rotate Slack token".** Token rotates → operator
  edits `/etc/agent/env` and restarts the host. Document.
- **Shared address space for outbound.** Multiple agents might
  technically share an outbound email address or webhook target. If
  that becomes a real need, it's a *destination* not a *source* —
  fan-out is harder than fan-in. Not at v1.
