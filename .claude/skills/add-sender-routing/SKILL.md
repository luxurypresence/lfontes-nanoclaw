---
name: add-sender-routing
description: Add per-wiring sender_match support to NanoClaw routing. Lets a single messaging group route different senders to different agent groups (e.g., Luis in a public channel goes to clanq-dm; everyone else goes to clanq-channels). Local fork-only feature; re-apply after upstream rebase.
---

# /add-sender-routing — Per-Sender Agent Routing

This skill adds a `sender_match` column to `messaging_group_agents` and changes the router fan-out to two-pass:

1. If any wiring on the messaging group has `sender_match` that includes the sender's userId, only those wirings engage.
2. Otherwise, wirings with `sender_match=NULL` (catch-all) handle the message.

This is a **local-fork-only** customization. Upstream NanoClaw does not have this feature. The skill is idempotent — safe to re-run after an upstream rebase wipes the patches.

## Files touched

| File | Change |
|------|--------|
| `src/db/migrations/module-sender-match.ts` | NEW — adds `sender_match TEXT` column |
| `src/db/migrations/index.ts` | Register the new migration (+1 import, +1 array entry) |
| `src/types.ts` | Add `sender_match: string \| null` to `MessagingGroupAgent` |
| `src/db/messaging-groups.ts` | Add `'sender_match'` to the `Pick<>` in `updateMessagingGroupAgent` |
| `src/router.ts` | Insert two-pass filter after `getMessagingGroupAgents` call |

## Phase 1: Pre-flight

Check whether the skill is already applied:

```bash
grep -q "moduleSenderMatch" src/db/migrations/index.ts && \
grep -q "sender_match" src/types.ts && \
grep -q "add-sender-routing skill" src/router.ts && \
echo "INSTALLED" || echo "NOT_INSTALLED"
```

If `INSTALLED`, skip to Phase 7 (Verify) — the skill has already been applied. If `NOT_INSTALLED`, continue.

If the migration file is present but the source patches are gone (post-rebase scenario), the skill will detect each missing piece individually below and re-apply only what's missing.

## Phase 2: Install the migration file

```bash
cp .claude/skills/add-sender-routing/resources/module-sender-match.ts src/db/migrations/module-sender-match.ts
```

Verify:

```bash
head -3 src/db/migrations/module-sender-match.ts
```

## Phase 3: Register the migration

If `grep -q "moduleSenderMatch" src/db/migrations/index.ts` is false, edit `src/db/migrations/index.ts` with the Edit tool:

**Edit 1** — add the import (anchor on the last numbered import):

```
old_string:
import { migration013 } from './013-approval-render-metadata.js';

new_string:
import { migration013 } from './013-approval-render-metadata.js';
import { moduleSenderMatch } from './module-sender-match.js';
```

**Edit 2** — add to the `migrations` array (anchor on the last entry):

```
old_string:
  migration013,
];

new_string:
  migration013,
  moduleSenderMatch,
];
```

Verify both:

```bash
grep -c "moduleSenderMatch" src/db/migrations/index.ts
```

Should print `2` (one import + one array entry).

## Phase 4: Extend the type

Edit `src/types.ts` with the Edit tool:

```
old_string:
  session_mode: 'shared' | 'per-thread' | 'agent-shared';
  priority: number;
  created_at: string;
}

new_string:
  session_mode: 'shared' | 'per-thread' | 'agent-shared';
  priority: number;
  /**
   * Per-wiring sender allowlist (CSV of namespaced user IDs, e.g.
   * "slack:U123,slack:U456"). NULL = no constraint (catch-all).
   * Installed by /add-sender-routing.
   */
  sender_match: string | null;
  created_at: string;
}
```

This anchor sits inside the `MessagingGroupAgent` interface — `created_at: string;` followed by `}` is unique to that struct. If `grep -q "sender_match: string | null" src/types.ts` already matches, skip this edit.

## Phase 5: Extend the update helper

Edit `src/db/messaging-groups.ts` to let `updateMessagingGroupAgent` write the new column:

```
old_string:
      'engage_mode' | 'engage_pattern' | 'sender_scope' | 'ignored_message_policy' | 'session_mode' | 'priority'

new_string:
      'engage_mode' | 'engage_pattern' | 'sender_scope' | 'ignored_message_policy' | 'session_mode' | 'priority' | 'sender_match'
```

If `grep -q "'sender_match'" src/db/messaging-groups.ts` already matches, skip.

## Phase 6: Patch the router

Edit `src/router.ts` to insert the two-pass filter after the `agents` fetch. The anchor is the comment + the `getMessagingGroupAgents` call.

```
old_string:
  // 3. Fetch wired agents in full (we already know the count is > 0; now
  //    we need their actual rows for fan-out).
  const agents = getMessagingGroupAgents(mg.id);

new_string:
  // 3. Fetch wired agents in full (we already know the count is > 0; now
  //    we need their actual rows for fan-out).
  let agents = getMessagingGroupAgents(mg.id);

  // [add-sender-routing skill] Per-sender wiring filter (two-pass):
  //   If any wiring has sender_match that includes this user, only those
  //   wirings engage; sender_match=NULL catch-alls sit out. If no wiring
  //   matches the sender, catch-alls handle the message normally.
  //   Local fork-only feature — re-applied via /add-sender-routing.
  {
    const matched =
      userId === null
        ? []
        : agents.filter((a) => {
            const sm = a.sender_match;
            if (!sm) return false;
            return sm
              .split(',')
              .map((s) => s.trim())
              .includes(userId);
          });
    agents = matched.length > 0 ? matched : agents.filter((a) => !a.sender_match);
  }
```

If `grep -q "add-sender-routing skill" src/router.ts` already matches, skip.

## Phase 7: Build, migrate, restart

Back up the central DB before the migration runs. ALTER ADD COLUMN is wrapped in a transaction by the migration runner, so partial-apply isn't really a concern — but a snapshot is cheap insurance and makes rollback a one-line restore:

```bash
cp data/v2.db "data/v2.db.pre-sender-routing.$(date +%Y%m%d-%H%M%S).bak"
ls -lh data/v2.db.pre-sender-routing.*.bak | tail -1
```

Keep the backup path in mind — if anything looks wrong after restart, restore with `cp <backup> data/v2.db` and restart the service.

Build the host (catches type errors from the patches):

```bash
mise exec node@22 -- pnpm run build
```

If the build fails, inspect the error — most likely a Phase 4–6 anchor didn't match (upstream changed). Read the offending file, find the equivalent location, and apply the edit by hand. The change is small enough that a manual fix is straightforward.

Restart the service so the migration runs and the new router code loads:

```bash
systemctl --user restart nanoclaw-v2-37e6d0ec.service
```

Tail logs briefly to confirm the migration applied:

```bash
sleep 3 && tail -50 logs/nanoclaw.log | grep -i "migration\|sender-match"
```

You should see `Migration applied { name: 'module-sender-match' }`.

## Phase 8: Verify

Confirm the column exists:

```bash
sqlite3 data/v2.db "PRAGMA table_info(messaging_group_agents);" | grep sender_match
```

Should print one row with `sender_match | TEXT` (cid varies).

Confirm the schema_version row was inserted:

```bash
sqlite3 data/v2.db "SELECT name FROM schema_version WHERE name='module-sender-match';"
```

## Done — How to use it

To wire `clanq-dm` as the Luis-only handler in a public-channel messaging group while `clanq-channels` stays the catch-all:

1. **Wire `clanq-dm` to the public messaging group** (in addition to its existing DM wiring). Use `/manage-channels` or insert directly:

   ```bash
   sqlite3 data/v2.db <<'EOF'
   INSERT INTO messaging_group_agents (
     id, messaging_group_id, agent_group_id,
     engage_mode, engage_pattern, sender_scope, ignored_message_policy,
     session_mode, priority, sender_match, created_at
   ) VALUES (
     'mga-' || lower(hex(randomblob(4))),
     '<PUBLIC_CHANNEL_MG_ID>',
     '<CLANQ_DM_AGENT_GROUP_ID>',
     'mention', NULL, 'all', 'drop',
     'agent-shared',  -- shares the session with the DM wiring; same memory
     10,
     'slack:UXXXXXXXX',  -- your namespaced Slack user ID
     datetime('now')
   );
   EOF
   ```

2. **Set `clanq-channels`'s wiring `sender_match=NULL`** (the default — no change needed if it's already NULL).

3. **Lookups for IDs**:

   ```bash
   # Find your namespaced user ID
   sqlite3 data/v2.db "SELECT id FROM users WHERE id LIKE 'slack:%' AND display_name LIKE '%Luis%';"

   # Find the public-channel messaging group ID
   sqlite3 data/v2.db "SELECT id, name, platform_id FROM messaging_groups WHERE channel_type='slack';"

   # Find agent group IDs
   sqlite3 data/v2.db "SELECT id, name FROM agent_groups;"
   ```

### Editing later

To change `sender_match` on an existing wiring:

```bash
sqlite3 data/v2.db "UPDATE messaging_group_agents SET sender_match='slack:UXXXXXX,slack:UYYYYYY' WHERE id='<MGA_ID>';"
```

Or NULL to drop the constraint:

```bash
sqlite3 data/v2.db "UPDATE messaging_group_agents SET sender_match=NULL WHERE id='<MGA_ID>';"
```

## Rollback

To undo this skill's changes:

1. Restore the DB from the Phase 7 backup (simplest — undoes both the ALTER and the schema_version row in one step):

   ```bash
   systemctl --user stop nanoclaw-v2-37e6d0ec.service
   ls -lt data/v2.db.pre-sender-routing.*.bak | head    # pick the right snapshot
   cp data/v2.db.pre-sender-routing.<timestamp>.bak data/v2.db
   ```

   Or, if the backup is gone, drop the column manually (requires SQLite 3.35+):

   ```bash
   sqlite3 data/v2.db "ALTER TABLE messaging_group_agents DROP COLUMN sender_match;
                       DELETE FROM schema_version WHERE name='module-sender-match';"
   ```

2. Revert the source patches via git (they're uncommitted by default, or in your top-of-rebase commit):

   ```bash
   git restore src/router.ts src/types.ts src/db/messaging-groups.ts src/db/migrations/index.ts
   rm src/db/migrations/module-sender-match.ts
   ```

3. Rebuild and restart:

   ```bash
   mise exec node@22 -- pnpm run build
   systemctl --user restart nanoclaw-v2-37e6d0ec.service
   ```

## Notes

- The skill does **not** auto-commit. After running, review the diff with `git diff` and commit yourself (the customization-as-commits-on-top-of-upstream pattern this fork uses).
- After every upstream rebase that drops these patches, re-run `/add-sender-routing`. The pre-flight in Phase 1 makes it a no-op if everything is already in place.
- `agent-shared` `session_mode` on the public-channel `clanq-dm` wiring means the agent has the same memory whether you DM it or @-mention it in a public channel. If you'd rather keep public-channel context separate from DM context, use `per-thread` or `shared` instead.
- Tests are not included by this skill. Worth adding a unit test in `src/host-core.test.ts` covering the two-pass filter (matched-sender → only specific wirings engage; unmatched-sender → only catch-alls engage).
