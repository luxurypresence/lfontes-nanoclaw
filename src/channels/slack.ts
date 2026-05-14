/**
 * Slack channel adapter (v2) — uses Chat SDK bridge.
 * Self-registers on import.
 */
import { createSlackAdapter } from '@chat-adapter/slack';
import type { Message as ChatMessage } from 'chat';

import { readEnvFile } from '../env.js';
import { log } from '../log.js';
import { createChatSdkBridge } from './chat-sdk-bridge.js';
import { registerChannelAdapter } from './channel-registry.js';

/** Cap on prior thread messages fetched on first engagement. */
const SEED_LIMIT = 30;

registerChannelAdapter('slack', {
  factory: () => {
    const env = readEnvFile(['SLACK_BOT_TOKEN', 'SLACK_SIGNING_SECRET']);
    if (!env.SLACK_BOT_TOKEN) return null;
    const slackAdapter = createSlackAdapter({
      botToken: env.SLACK_BOT_TOKEN,
      signingSecret: env.SLACK_SIGNING_SECRET,
    });
    const bridge = createChatSdkBridge({
      adapter: slackAdapter,
      concurrency: 'concurrent',
      supportsThreads: true,
      // Top-level Slack DM messages arrive with an empty thread_ts (the
      // adapter's intentional DM flattening at @chat-adapter/slack
      // dist/index.js:1955). That collapses every top-level DM to one shared
      // threadId, so per-thread session mode degenerates into one session
      // forever. Rewrite to use the message ts so each top-level DM gets its
      // own session AND Clanq's reply posts in-thread (postMessage decodes
      // thread_ts from the threadId, and Slack auto-creates the thread).
      // In-thread DM replies arrive with a real thread_ts → no rewrite needed.
      rewriteThreadId: (threadId, message, { isDM }) => {
        if (!isDM) return threadId;
        try {
          const decoded = slackAdapter.decodeThreadId(threadId);
          if (decoded.threadTs) return threadId;
          return slackAdapter.encodeThreadId({ channel: decoded.channel, threadTs: message.id });
        } catch {
          return threadId;
        }
      },
      // Slack only forwards the message Clanq was mentioned in. Without this
      // hook the agent has no view of the thread parent or earlier replies —
      // see chat-sdk-bridge.ts ChatSdkBridgeConfig.fetchThreadContext.
      // Requires the Slack app to have channels:history / groups:history
      // (and mpim:history for group DMs) for conversations.replies to succeed.
      fetchThreadContext: async (threadId, message) => {
        // Top-level channel post starting its own thread → message is the
        // thread root, no history to seed. Slack thread ids decode to
        // {channel, threadTs}; threadTs equals the root message's ts.
        try {
          const decoded = slackAdapter.decodeThreadId(threadId);
          if (decoded.threadTs === message.id) return null;
        } catch {
          // Unexpected id shape — fall through and try a fetch anyway.
        }
        try {
          const result = await slackAdapter.fetchMessages(threadId, { direction: 'forward', limit: SEED_LIMIT });
          const prior = result.messages.filter((m) => m.id !== message.id);
          if (prior.length === 0) return null;
          return await Promise.all(prior.map(toSeedEntry));
        } catch (err) {
          log.warn('Slack fetchThreadContext failed', { threadId, err });
          return null;
        }
      },
    });
    bridge.resolveChannelName = async (platformId: string) => {
      try {
        const info = await slackAdapter.fetchThread(platformId);
        return (info as { channelName?: string }).channelName ?? null;
      } catch {
        return null;
      }
    };
    return bridge;
  },
});

/**
 * Project a Slack thread message into the compact shape the formatter renders.
 * Downloads attachment data (mirrors the bridge's per-message behavior) so
 * session-manager can stage prior-message files to disk and the agent can
 * Read them — without this the agent only sees filenames for files shared
 * before it was tagged.
 */
async function toSeedEntry(m: ChatMessage): Promise<Record<string, unknown>> {
  const sender = m.author?.fullName || m.author?.userName || m.author?.userId || 'Unknown';
  const attachments = await Promise.all(
    (m.attachments ?? []).map(async (a) => {
      const entry: Record<string, unknown> = {
        type: a.type,
        name: a.name,
        mimeType: a.mimeType,
        size: (a as unknown as Record<string, unknown>).size,
      };
      if (a.fetchData) {
        try {
          const buffer = await a.fetchData();
          entry.data = buffer.toString('base64');
        } catch (err) {
          entry.error = err instanceof Error ? err.message : String(err);
          log.warn('Failed to download thread-context attachment', { messageId: m.id, name: a.name, err });
        }
      }
      return entry;
    }),
  );
  return {
    id: m.id,
    sender,
    senderId: m.author?.userId,
    text: m.text ?? '',
    time: m.metadata.dateSent.toISOString(),
    attachments: attachments.length > 0 ? attachments : undefined,
  };
}
