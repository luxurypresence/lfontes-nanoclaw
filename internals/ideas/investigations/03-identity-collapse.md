# Investigation: identity collapse

## Question

NanoClaw's `users` table keys on `<channel>:<handle>` — each platform
identity is its own row. The trust-zone router needs the opposite: many
platform identities collapsing to **one canonical human**, so that
`slack:U123`, `github:luisfontes`, `discord:luis#0001` all resolve to
`user:luis` → one zone assignment.

How is that data modeled, what's the lifecycle for new aliases, and what
does the operator UX look like?

## Constraints (recap, brief)

- Single tenant, single host (see `design-principles.md`).
- Two zones: `dm-trust` (me) and `public-trust` (catch-all). Maybe a third.
- Router is the only policy layer; it must answer `(platform_id, channel)
  → canonical_user_id → zone_id` in one hop, not a join chain.
- Unknown senders default to `'*'` catch-all → `public-trust`. Never fail
  closed to "rejected"; always degrade to lowest trust.
- No OAuth flow. Operator-driven linking, asserted by me.

## Schema proposal (with SQL DDL)

Two tables. `users` is the canonical row; `user_aliases` is the
many-to-one map from platform IDs to canonical users.

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,            -- 'user:luis', 'user:alice', 'user:anon-7f3a'
  display_name  TEXT NOT NULL,
  notes         TEXT,                        -- freeform — "Luis, primary operator"
  is_operator   INTEGER NOT NULL DEFAULT 0,  -- 1 for me (the first-party); 0 for everyone else
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE user_aliases (
  platform_id   TEXT PRIMARY KEY,            -- 'slack:T123:U456', 'github:luisfontes'
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  linked_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  linked_by     TEXT,                        -- 'operator' | 'auto' | 'migrated'
  source_note   TEXT                         -- optional context — "linked via ncl users merge"
);

CREATE INDEX idx_user_aliases_user_id ON user_aliases(user_id);

-- Audit trail of merge/split operations. Append-only.
CREATE TABLE user_link_events (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ts            TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  kind          TEXT NOT NULL,               -- 'create' | 'link' | 'unlink' | 'merge' | 'split'
  platform_id   TEXT,
  user_id       TEXT,
  prev_user_id  TEXT,                        -- for merge/split, the source/target
  note          TEXT
);
```

`platform_id` is a `PRIMARY KEY` on `user_aliases` — one platform identity
can map to exactly one canonical user. The constraint is enforced by the
DB. This prevents the "two canonical users claiming the same alias" edge
case from being a runtime question; it's a constraint violation at write
time.

The router's hot-path query stays single-statement:

```sql
SELECT u.id, u.is_operator
FROM user_aliases a JOIN users u ON u.id = a.user_id
WHERE a.platform_id = ?;
```

Followed by the `zone_assignments` lookup from `trust-zones.md` keyed on
`u.id` (canonical) instead of the raw `platform_id`.

## Lifecycle (new arrival, merge, split, unknown)

### New platform identity arrives

When the router sees a `platform_id` with no `user_aliases` row:

- **Do NOT auto-create a canonical user.** Auto-creating means every drive-
  by sender in a public channel allocates a row. The catch-all `'*'` zone
  assignment already handles unknown senders correctly without needing a
  canonical user; creating one buys nothing and grows the table forever.
- The router treats this as "unknown" → routes to `public-trust` via
  `sender_id = '*'`.
- A row is appended to `dropped_messages` / a `seen_unknown_senders` view
  (existing NanoClaw idea) so the operator can later run `ncl users link`
  on identities worth attributing.

If the operator wants attribution, they explicitly run:

```bash
ncl users link slack:T123:U456 --to user:alice
# or
ncl users new alice --alias slack:T123:U456 --display-name "Alice"
```

The second form creates the canonical user and the alias in one shot.

### Merge (operator: "this slack ID and that github ID are the same person")

Two cases:

1. **Both already canonical users.** Pick one to keep (`--into`), reassign
   all aliases of the other, delete the loser, log the event.

   ```bash
   ncl users merge user:alice-gh --into user:alice
   ```

   SQL:

   ```sql
   BEGIN;
   UPDATE user_aliases SET user_id = 'user:alice'
     WHERE user_id = 'user:alice-gh';
   INSERT INTO user_link_events (kind, user_id, prev_user_id, note)
     VALUES ('merge', 'user:alice', 'user:alice-gh', '...');
   DELETE FROM users WHERE id = 'user:alice-gh';
   COMMIT;
   ```

2. **Loose alias attaching to existing user.** Simpler — it's just
   `ncl users link`.

### Split

The operator realizes `slack:U123` and `github:bob` were wrongly merged
into `user:alice`. The audit log makes this recoverable.

```bash
ncl users split slack:T123:U456 --to user:bob --display-name "Bob"
```

This:
- Creates `user:bob` if `--to` doesn't exist.
- Reassigns the alias.
- Logs a `split` event with `prev_user_id = user:alice`.

If multiple aliases need to come off, repeat the command per alias. No
bulk split — the operator's intent should be explicit per alias.

Reversibility: every merge/split is recorded in `user_link_events`, so
"undo my last merge" is `ncl users split` against the recorded aliases.
The system doesn't auto-reverse; the operator re-runs the inverse.

### First-party (the operator) vs third-party

The operator's aliases are seeded during `/init-first-agent` or a new
`ncl users init-operator` step:

```bash
ncl users init-operator luis \
  --alias slack:T0LP:U_luis \
  --alias github:luisfontes \
  --alias discord:luis#0001 \
  --display-name "Luis"
# sets is_operator=1
```

After that, third-party aliases grow organically via `ncl users link`
when needed for trust-zone assignment.

`is_operator=1` is a hint, not a security boundary. The actual privilege
comes from `zone_assignments` pointing the operator user at `dm-trust`.
But it lets the CLI warn "you're about to unlink an operator alias —
are you sure?"

### Unknown sender

Covered above. `platform_id` not in `user_aliases` → router falls back to
`'*'` → `public-trust`. No DB writes on the read path. An out-of-band
audit row gets logged via `record_message` so the operator can see who's
been showing up.

## Operator UX

`ncl users` subcommands:

```bash
ncl users list                                    # all canonical users
ncl users get user:luis                           # details + all aliases
ncl users new alice --display-name "Alice"        # create canonical user, no aliases
ncl users link slack:T123:U456 --to user:alice    # attach alias
ncl users unlink slack:T123:U456                  # detach alias (user persists)
ncl users merge user:alice-gh --into user:alice   # combine two canonical users
ncl users split slack:T123:U456 --to user:bob     # peel an alias off into a new/existing user
ncl users delete user:alice                       # delete user + aliases (CASCADE)
ncl users init-operator luis --alias ... --alias ...  # seed first-party identity
ncl users history user:alice                      # show user_link_events for this user
ncl users unattributed                            # list platform_ids seen but not linked
```

Tied into existing `ncl` style (`src/cli/resources/users.ts` today is the
NanoClaw equivalent). The `unattributed` subcommand is the bridge from
"someone messaged me" → "do I want to attribute and zone-assign them?"

## Edge cases

- **Two canonical users claim the same alias.** Can't happen at write
  time — `platform_id` is `PRIMARY KEY`. `ncl users link` of an already-
  taken alias errors with a hint to use `merge` or `unlink` first.
- **Operator typo on a `platform_id`.** A mistyped alias just doesn't
  resolve at routing time → falls back to `public-trust`. Re-running with
  the correct ID self-heals. The audit log shows the stale link if
  cleanup is desired.
- **Platform ID format normalization.** Always namespace as
  `<platform>:<workspace-or-instance>:<user-id>`. Slack:
  `slack:T0LP:U_luis` (team + user). Discord: `discord:guild_id:user_id`
  or just `discord:user_id` if guild-scope isn't meaningful. GitHub:
  `github:luisfontes` (lowercase, no workspace). The router never
  normalizes on the fly — whatever the channel adapter emits is the
  canonical form, and the adapter is the one place that decides.
- **Bulk import.** If I'm migrating from NanoClaw's per-platform `users`
  table, a one-shot script reads each `<channel>:<handle>` row and
  attributes it to me (the operator) or leaves it unattributed.
- **Display-name drift.** Slack users rename themselves. `display_name`
  on `users` is operator-controlled, not auto-synced. If the operator
  wants real names, they update them.
- **Per-workspace aliases for the same human.** `slack:T0LP:U_luis` (my
  workspace) and `slack:TXX:U_luis` (a customer workspace) are different
  aliases that both point to `user:luis`. The schema supports this
  natively — `user_aliases` doesn't care which workspace an alias is
  from.

## Recommendation

Use the two-table model (`users` + `user_aliases`) with the audit log.
Don't auto-create canonical users on first contact; let attribution be
explicit. CLI surface is `ncl users {list,get,new,link,unlink,merge,
split,delete,init-operator,history,unattributed}`.

Reject the flat-multi-column-table option outright — it can't grow past
the platforms you knew about at schema time. Reject implicit collapse by
display name — Slack users rename themselves daily; it's not a key.
Reject OAuth-merge-flow — for personal use there's no third-party human
to assert the link in real time, and the operator merging via CLI is a
five-second action they already do for every other config change.

## Open sub-questions

- Do I want to expose `user_link_events` in a `ncl users history` style
  command, or is the `sqlite3` CLI good enough for a personal tool? Lean
  toward exposing it because merge/split is rare-but-impactful.
- Should the router cache the `platform_id → canonical_id` lookup in
  memory? The table is small (probably <100 rows ever); a `Map` populated
  at startup and invalidated on `users` writes is plenty.
- For zone assignments, do I store `(canonical_user_id, zone_id)` or also
  accept raw `platform_id`? Decision in `trust-zones.md`: canonical only.
  The router always collapses first, then assigns. Keeps the policy table
  small.
- Multi-operator (multi-tenant) is explicitly out of scope per principles.
  If it ever comes in, `is_operator` becomes a role on `user_roles`, not
  a column on `users`. Not designing for it now.
