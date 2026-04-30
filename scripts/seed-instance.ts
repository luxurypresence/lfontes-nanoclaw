/**
 * Seed Luis's NanoClaw instance: agent groups, messaging groups, wiring,
 * owner role. Idempotent — safe to re-run on a populated DB; existing rows
 * are detected by natural key (folder, channel+platform_id, user_id+role)
 * and left alone.
 *
 * Use case: bootstrapping a fresh VM or rebuilding `data/v2.db` from scratch.
 * The on-disk per-group config (CLAUDE.local.md, container.json) is tracked
 * in git separately — this script only recreates the central-DB entities.
 *
 * Usage (from repo root, with project-pinned Node):
 *   mise exec node@22 -- pnpm exec tsx scripts/seed-instance.ts
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { runMigrations } from '../src/db/migrations/index.js';
import {
  createAgentGroup,
  getAgentGroupByFolder,
} from '../src/db/agent-groups.js';
import {
  createMessagingGroup,
  createMessagingGroupAgent,
  getMessagingGroupByPlatform,
  getMessagingGroupAgentByPair,
} from '../src/db/messaging-groups.js';
import { createUser } from '../src/modules/permissions/db/users.js';
import { grantRole, isOwner } from '../src/modules/permissions/db/user-roles.js';
import { initGroupFilesystem } from '../src/group-init.js';

interface AgentGroupSpec {
  name: string;
  folder: string;
}

interface MessagingGroupSpec {
  channel_type: string;
  platform_id: string;
  name: string;
  is_group: 0 | 1;
  unknown_sender_policy: 'strict' | 'request_approval' | 'public';
}

interface WiringSpec {
  folder: string;
  channel_type: string;
  platform_id: string;
  session_mode: 'shared' | 'per-thread' | 'agent-shared';
  engage_mode: 'pattern' | 'mention' | 'mention-sticky';
  engage_pattern: string | null;
}

interface OwnerSpec {
  user_id: string;
  kind: 'platform' | 'channel' | 'unknown';
  display_name: string | null;
}

const AGENT_GROUPS: AgentGroupSpec[] = [
  { name: 'Terminal Agent', folder: 'cli-with-luis' },
  { name: 'Clanq', folder: 'dm-with-luis' },
  { name: 'Clanq', folder: 'clanq-channels' },
];

const MESSAGING_GROUPS: MessagingGroupSpec[] = [
  {
    channel_type: 'cli',
    platform_id: 'local',
    name: 'Local CLI',
    is_group: 0,
    unknown_sender_policy: 'public',
  },
  {
    channel_type: 'slack',
    platform_id: 'slack:D0B0VTX5KMX',
    name: 'Luis',
    is_group: 0,
    unknown_sender_policy: 'strict',
  },
  {
    channel_type: 'slack',
    platform_id: 'slack:C0B0FK02MRV',
    name: '#bots',
    is_group: 1,
    unknown_sender_policy: 'public',
  },
];

const WIRING: WiringSpec[] = [
  {
    folder: 'cli-with-luis',
    channel_type: 'cli',
    platform_id: 'local',
    session_mode: 'shared',
    engage_mode: 'pattern',
    engage_pattern: '.',
  },
  {
    folder: 'dm-with-luis',
    channel_type: 'slack',
    platform_id: 'slack:D0B0VTX5KMX',
    session_mode: 'shared',
    engage_mode: 'pattern',
    engage_pattern: '.',
  },
  {
    folder: 'clanq-channels',
    channel_type: 'slack',
    platform_id: 'slack:C0B0FK02MRV',
    session_mode: 'per-thread',
    engage_mode: 'mention',
    engage_pattern: null,
  },
];

const OWNERS: OwnerSpec[] = [
  { user_id: 'slack:U0AELNA1HUZ', kind: 'platform', display_name: 'Luis' },
];

function id(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

const now = (): string => new Date().toISOString();

function main(): void {
  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(db);

  for (const spec of AGENT_GROUPS) {
    const existing = getAgentGroupByFolder(spec.folder);
    if (existing) {
      console.log(`[skip] agent group ${spec.folder} (${existing.id})`);
    } else {
      const newId = id('ag');
      createAgentGroup({
        id: newId,
        name: spec.name,
        folder: spec.folder,
        agent_provider: null,
        created_at: now(),
      });
      console.log(`[ok]   agent group ${spec.folder} (${newId})`);
    }
    initGroupFilesystem(getAgentGroupByFolder(spec.folder)!);
  }

  for (const spec of MESSAGING_GROUPS) {
    const existing = getMessagingGroupByPlatform(spec.channel_type, spec.platform_id);
    if (existing) {
      console.log(`[skip] messaging group ${spec.channel_type} ${spec.platform_id}`);
      continue;
    }
    const newId = id('mg');
    createMessagingGroup({
      id: newId,
      channel_type: spec.channel_type,
      platform_id: spec.platform_id,
      name: spec.name,
      is_group: spec.is_group,
      unknown_sender_policy: spec.unknown_sender_policy,
      created_at: now(),
    });
    console.log(`[ok]   messaging group ${spec.channel_type} ${spec.platform_id} (${newId})`);
  }

  for (const spec of WIRING) {
    const ag = getAgentGroupByFolder(spec.folder);
    const mg = getMessagingGroupByPlatform(spec.channel_type, spec.platform_id);
    if (!ag || !mg) {
      throw new Error(
        `wiring references missing entity: folder=${spec.folder} channel=${spec.channel_type} platform=${spec.platform_id}`,
      );
    }
    const existing = getMessagingGroupAgentByPair(mg.id, ag.id);
    if (existing) {
      console.log(`[skip] wiring ${spec.folder} <-> ${spec.channel_type} ${spec.platform_id}`);
      continue;
    }
    const newId = id('mga');
    createMessagingGroupAgent({
      id: newId,
      messaging_group_id: mg.id,
      agent_group_id: ag.id,
      engage_mode: spec.engage_mode,
      engage_pattern: spec.engage_pattern,
      sender_scope: 'all',
      ignored_message_policy: 'drop',
      session_mode: spec.session_mode,
      priority: 0,
      created_at: now(),
    });
    console.log(`[ok]   wiring ${spec.folder} <-> ${spec.channel_type} ${spec.platform_id} (${newId})`);
  }

  for (const owner of OWNERS) {
    try {
      createUser({
        id: owner.user_id,
        kind: owner.kind,
        display_name: owner.display_name,
        created_at: now(),
      });
      console.log(`[ok]   user ${owner.user_id}`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes('UNIQUE')) {
        console.log(`[skip] user ${owner.user_id}`);
      } else {
        throw err;
      }
    }
    // SQLite treats NULL as distinct from NULL in PRIMARY KEYs, so the
    // (user_id, role, agent_group_id) PK on user_roles does NOT prevent
    // duplicate global-scope owner rows. Check explicitly via isOwner().
    if (isOwner(owner.user_id)) {
      console.log(`[skip] owner role ${owner.user_id}`);
    } else {
      grantRole({
        user_id: owner.user_id,
        role: 'owner',
        agent_group_id: null,
        granted_by: null,
        granted_at: now(),
      });
      console.log(`[ok]   owner role ${owner.user_id}`);
    }
  }

  console.log('\nDone. Start the host: pnpm run build && /bin/node dist/index.js');
}

main();
