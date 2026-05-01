import type Database from 'better-sqlite3';

import type { Migration } from './index.js';

/**
 * Per-wiring sender allowlist for routing. When set, the wiring only engages
 * for messages from matching sender user IDs (CSV, namespaced — e.g.
 * "slack:U123,slack:U456"). NULL = no constraint (catch-all).
 *
 * Routing semantics (applied by router.ts fan-out):
 *   - If any wiring on the messaging group has a sender_match that includes
 *     the sender's userId, only those wirings engage.
 *   - Otherwise, wirings with sender_match=NULL handle the message.
 *
 * Installed by the local /add-sender-routing skill. Not part of upstream
 * NanoClaw — re-applied on every upstream rebase.
 */
export const moduleSenderMatch: Migration = {
  version: 100,
  name: 'module-sender-match',
  up(db: Database.Database) {
    db.exec('ALTER TABLE messaging_group_agents ADD COLUMN sender_match TEXT;');
  },
};
