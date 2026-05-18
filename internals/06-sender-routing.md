# Sender Routing (local fork patch)

Study of the `/add-sender-routing` skill — a local-fork-only NanoClaw
customization that lets a single messaging group route different senders
to different agent groups. The closest existing mechanism in NanoClaw to
the trust-zone model in `ideas/trust-zones.md`.

## What it does

Adds a `sender_match` column to `messaging_group_agents` so each wiring
can declare an allowlist of platform user IDs (CSV, namespaced — e.g.
`"slack:U123,slack:U456"`). The router then does a two-pass filter on
fan-out: if any wiring matches the sender, only those wirings engage; if
none match, the `sender_match=NULL` catch-alls handle the message.

Practical use on this install: in public Slack channels, when **I** type,
the message routes to `clanq-dm` (full powers). When anyone else types,
it routes to `clanq-channels` (restricted).

This is the "trust on sender identity, not channel" pattern — bolted on
top of NanoClaw's per-agent-group containers.

## How it's wired

Source: `.claude/skills/add-sender-routing/`.

### Migration (DB)

`src/db/migrations/module-sender-match.ts`:

```ts
export const moduleSenderMatch: Migration = {
  version: 100,
  name: 'module-sender-match',
  up(db: Database.Database) {
    db.exec('ALTER TABLE messaging_group_agents ADD COLUMN sender_match TEXT;');
  },
};
```

One column. No index, because the table is tiny (one row per wiring,
typically <20 total per install).

### Type extension

`src/types.ts` — `MessagingGroupAgent` gets:

```ts
sender_match: string | null;
```

NULL means "no constraint" (catch-all).

### Router patch

`src/router.ts` — inserted after `getMessagingGroupAgents()` returns the
wired agents:

```ts
let agents = getMessagingGroupAgents(mg.id);

// Per-sender wiring filter (two-pass)
{
  const matched =
    userId === null
      ? []
      : agents.filter((a) => {
          const sm = a.sender_match;
          if (!sm) return false;
          return sm.split(',').map((s) => s.trim()).includes(userId);
        });
  agents = matched.length > 0 ? matched : agents.filter((a) => !a.sender_match);
}
```

The full SKILL.md at `.claude/skills/add-sender-routing/SKILL.md` documents
the install procedure, idempotency, rollback, and the way the patch
re-applies after upstream rebase.

## How a wiring is configured

To make `clanq-dm` Luis-only in a public Slack channel while
`clanq-channels` stays the catch-all:

```sql
-- New wiring for the public channel → clanq-dm, Luis only
INSERT INTO messaging_group_agents (
  id, messaging_group_id, agent_group_id,
  engage_mode, sender_scope, ignored_message_policy,
  session_mode, priority, sender_match, created_at
) VALUES (
  'mga-...', '<PUBLIC_MG_ID>', '<CLANQ_DM_AG_ID>',
  'mention', 'all', 'drop',
  'agent-shared', 10, 'slack:UXXXXXXXX', datetime('now')
);

-- Existing clanq-channels wiring has sender_match = NULL (catch-all)
```

`session_mode='agent-shared'` so the agent has the same memory whether I
DM it or @ it in a public channel.

## What it gets right

- **Sender as the routing axis.** Matches my actual trust model.
- **Two-pass with explicit precedence.** If matched, only matched
  wirings engage. Otherwise catch-all. Easy to reason about.
- **Locality.** The decision lives in one place in `router.ts`. Audit-
  friendly.
- **Tiny patch.** Five files touched, one new column, ~15 lines of router
  logic. Reversible.
- **Idempotent skill.** Survives upstream rebases.

## What it gets wrong (for the rewrite)

This is "the right idea on the wrong substrate." Specifically:

- **Routing happens after agent-group selection.** The router still asks
  "which agent groups are wired to this messaging group?" first, *then*
  filters by sender. In the rewrite, the primary lookup is
  `(sender_id, channel) → trust_zone`, with no detour through agent groups.
- **Trust still rides on `agent_group_id`.** The container is one per
  agent group, so the way to get "Luis gets different capabilities" is to
  spin up a second agent group with a different container config and wire
  Luis to it. That's two containers per persona instead of two containers
  per trust zone.
- **CSV-of-IDs in a column.** Works for small allowlists, doesn't scale to
  more senders, doesn't handle multi-platform identity collapse. The
  rewrite uses a `zone_assignments` table keyed on canonical user IDs.
- **Coupled to NanoClaw's routing model.** `engage_mode`, `session_mode`,
  `engage_pattern`, `ignored_message_policy` all still apply, layered on
  top. The rewrite collapses these into the trust zone + a few
  per-channel-override knobs.

## What carries forward to the rewrite

| From this patch | To the trust-zone model |
|-----------------|--------------------------|
| `sender_match` CSV column | `zone_assignments` table with `(canonical_user_id, zone_id, priority)` |
| Two-pass router filter (matched-first, catch-all-fallback) | Same precedence, but cleaner: priority-ordered SELECT with `'*'` row as catch-all |
| `agent-shared` session mode for same-memory-across-channels | Containers are long-lived in the rewrite, so this is the default — no toggle needed |
| Manual SQL configuration | `ncl zones assign --sender slack:UXXX --zone dm-trust` (via the new admin CLI over RPC) |

## What to lift verbatim

Honestly, very little. The mental model is the same — "sender drives
routing, with a catch-all fallback" — but the rewrite's data model is
different enough that the literal patch doesn't survive. What it does
prove: this routing model works for me in practice. I've been running it
for months, the behavior is predictable, and the public-Slack-as-DM
upgrade is exactly the UX I want.

## Notes

- Used in production on this install. The wiring sits in `data/v2.db` —
  `SELECT id, sender_match FROM messaging_group_agents WHERE sender_match
  IS NOT NULL;` to inspect.
- The skill's existence and contents are themselves an argument for the
  trust-zone rewrite: I had to bolt a sender-routing layer onto NanoClaw
  because its primary routing axis is the wrong one for me.
