---
name: add-slack-dm-threading
description: Make Slack DMs thread-per-conversation so each new top-level DM starts a fresh session and Clanq replies in-thread. Patches chat-sdk-bridge with a rewriteThreadId hook and the Slack channel adapter with a DM-specific rewriter that swaps empty thread_ts for the message ts. Local fork-only feature; re-apply after upstream rebase.
---

# /add-slack-dm-threading — Thread-per-conversation Slack DMs

By default, NanoClaw collapses every top-level Slack DM into one session that grows forever (eventually compacting and losing context). This is because `@chat-adapter/slack` intentionally sets `thread_ts = ""` for DM events without an existing thread (`dist/index.js` around line 1955), so every top-level DM encodes to the same `threadId`.

This skill makes top-level DMs unique by:

1. Adding a generic `rewriteThreadId(threadId, message, { isDM })` hook to the chat-sdk bridge — the channel adapter wrapper can override the thread id used for session resolution AND outbound delivery.
2. Plugging in a Slack-specific rewriter that, for DMs only, replaces an empty `thread_ts` with `message.id` (the Slack `ts`). Each top-level DM → new threadId → new per-thread session. Outbound `postMessage` decodes that threadId, picks up the `thread_ts`, and Slack auto-creates the thread on the user's message. Replies inside the thread carry a real `event.thread_ts` already, so the rewriter no-ops and the session continues.

This is **local-fork-only**. Upstream NanoClaw does not have this hook. The skill is idempotent — safe to re-run after an upstream rebase wipes the patches.

## Files touched

| File | Change |
|------|--------|
| `src/channels/chat-sdk-bridge.ts` | Add `rewriteThreadId` to `ChatSdkBridgeConfig` + apply in 4 chat handlers |
| `src/channels/slack.ts` | Pass a Slack DM rewriter to `createChatSdkBridge` |

The per-wiring `session_mode` flip (shared → per-thread) is **not** automated by this skill — wiring ids vary per install and "I want per-thread DMs" is an opinion, not a fact. The skill prints the right `ncl` command at the end so you can apply it where it makes sense.

## Phase 1: Pre-flight

Check whether the skill is already applied:

```bash
grep -q "rewriteThreadId" src/channels/chat-sdk-bridge.ts && \
grep -q "rewriteThreadId:" src/channels/slack.ts && \
echo "INSTALLED" || echo "NOT_INSTALLED"
```

If `INSTALLED`, skip to Phase 4 (Verify). The patches are already in place; nothing to do on the source side.

If only one of the two greps matches (partial state after a bad rebase), continue — each phase detects its own marker and skips work that's already there.

## Phase 2: Patch the bridge

Two edits to `src/channels/chat-sdk-bridge.ts`. Both have unique anchors; if a future upstream change breaks an anchor, the build error in Phase 4 will tell you which file to fix by hand.

**Edit 1** — add the config field. Anchor on the existing `fetchThreadContext` closing line:

```
old_string:
  fetchThreadContext?: (threadId: string, message: ChatMessage) => Promise<unknown[] | null>;
}

new_string:
  fetchThreadContext?: (threadId: string, message: ChatMessage) => Promise<unknown[] | null>;
  /**
   * Optional rewrite of the inbound threadId before session resolution. Lets a
   * channel reinterpret what counts as a "thread". Slack uses this to give
   * top-level DM messages (which the underlying adapter encodes with an empty
   * thread_ts) a thread id keyed on the message ts — so each new top-level DM
   * becomes its own per-thread session and Clanq's reply is posted in-thread.
   * `isDM` mirrors the bridge's own dispatch (true only for onDirectMessage).
   */
  rewriteThreadId?: (threadId: string, message: ChatMessage, context: { isDM: boolean }) => string;
}
```

Skip if `grep -q "rewriteThreadId?:" src/channels/chat-sdk-bridge.ts` already matches.

**Edit 2** — apply the rewrite in all four chat handlers. Anchor on the `onSubscribedMessage` block since it's the first handler:

```
old_string:
      // Subscribed threads — every message in a thread we've previously
      // engaged. Carry the SDK's `message.isMention` through so mention-mode
      // wirings still fire on in-thread mentions.
      chat.onSubscribedMessage(async (thread, message) => {
        const channelId = adapter.channelIdFromThreadId(thread.id);
        await setupConfig.onInbound(
          channelId,
          thread.id,
          await messageToInbound(message, message.isMention === true, true),
        );
      });

      // @mention in an unsubscribed thread — SDK-confirmed bot mention.
      chat.onNewMention(async (thread, message) => {
        const channelId = adapter.channelIdFromThreadId(thread.id);
        await setupConfig.onInbound(channelId, thread.id, await messageToInbound(message, true, true, true));
      });

      // DMs — by definition addressed to the bot. Thread id flows through
      // so sub-thread context reaches delivery (Slack users can open threads
      // inside a DM). Router collapses DM sub-threads to one session via
      // is_group=0 short-circuit.
      chat.onDirectMessage(async (thread, message) => {
        const channelId = adapter.channelIdFromThreadId(thread.id);
        log.info('Inbound DM received', {
          adapter: adapter.name,
          channelId,
          sender: (message.author as any)?.fullName ?? (message.author as any)?.userId ?? 'unknown',
          threadId: thread.id,
        });
        await setupConfig.onInbound(channelId, thread.id, await messageToInbound(message, true, false));
      });

new_string:
      // Per-channel hook: rewrite the SDK's thread id before session resolution.
      // See ChatSdkBridgeConfig.rewriteThreadId.
      const rewrite = (threadId: string, message: ChatMessage, isDM: boolean): string =>
        config.rewriteThreadId ? config.rewriteThreadId(threadId, message, { isDM }) : threadId;

      // Subscribed threads — every message in a thread we've previously
      // engaged. Carry the SDK's `message.isMention` through so mention-mode
      // wirings still fire on in-thread mentions.
      chat.onSubscribedMessage(async (thread, message) => {
        const tid = rewrite(thread.id, message, false);
        const channelId = adapter.channelIdFromThreadId(tid);
        await setupConfig.onInbound(
          channelId,
          tid,
          await messageToInbound(message, message.isMention === true, true),
        );
      });

      // @mention in an unsubscribed thread — SDK-confirmed bot mention.
      chat.onNewMention(async (thread, message) => {
        const tid = rewrite(thread.id, message, false);
        const channelId = adapter.channelIdFromThreadId(tid);
        await setupConfig.onInbound(channelId, tid, await messageToInbound(message, true, true, true));
      });

      // DMs — by definition addressed to the bot. Thread id flows through
      // so sub-thread context reaches delivery (Slack users can open threads
      // inside a DM).
      chat.onDirectMessage(async (thread, message) => {
        const tid = rewrite(thread.id, message, true);
        const channelId = adapter.channelIdFromThreadId(tid);
        log.info('Inbound DM received', {
          adapter: adapter.name,
          channelId,
          sender: (message.author as any)?.fullName ?? (message.author as any)?.userId ?? 'unknown',
          threadId: tid,
        });
        await setupConfig.onInbound(channelId, tid, await messageToInbound(message, true, false));
      });
```

Then a smaller edit for the fourth handler (`onNewMessage`), which lives further down:

```
old_string:
      chat.onNewMessage(/[\s\S]*/, async (thread, message) => {
        const channelId = adapter.channelIdFromThreadId(thread.id);
        await setupConfig.onInbound(channelId, thread.id, await messageToInbound(message, false, true, true));
      });

new_string:
      chat.onNewMessage(/[\s\S]*/, async (thread, message) => {
        const tid = rewrite(thread.id, message, false);
        const channelId = adapter.channelIdFromThreadId(tid);
        await setupConfig.onInbound(channelId, tid, await messageToInbound(message, false, true, true));
      });
```

Skip either edit if `grep -q "const rewrite = (threadId" src/channels/chat-sdk-bridge.ts` already matches.

## Phase 3: Patch the Slack adapter

Edit `src/channels/slack.ts` — pass the rewriter into `createChatSdkBridge`. Anchor on the existing `fetchThreadContext` comment block, since `supportsThreads: true` appears multiple times in the file (once here, once in tests historically):

```
old_string:
    const bridge = createChatSdkBridge({
      adapter: slackAdapter,
      concurrency: 'concurrent',
      supportsThreads: true,
      // Slack only forwards the message Clanq was mentioned in. Without this
      // hook the agent has no view of the thread parent or earlier replies —
      // see chat-sdk-bridge.ts ChatSdkBridgeConfig.fetchThreadContext.
      // Requires the Slack app to have channels:history / groups:history
      // (and mpim:history for group DMs) for conversations.replies to succeed.
      fetchThreadContext: async (threadId, message) => {

new_string:
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
```

Skip if `grep -q "rewriteThreadId:" src/channels/slack.ts` already matches.

## Phase 4: Build and restart

Build the host (catches type errors from drifted anchors):

```bash
mise exec node@22 -- pnpm run build
```

If the build fails, an anchor likely didn't match — upstream changed the file. Read the offending region, find the equivalent location, and apply the edit by hand. The change is small enough that a manual fix is straightforward.

Restart so the new bridge code is loaded:

```bash
systemctl --user restart nanoclaw-v2-37e6d0ec.service
```

Tail logs briefly to confirm the Slack bridge re-initialized cleanly:

```bash
sleep 3 && tail -30 logs/nanoclaw.log | grep -i "slack\|bridge"
```

You should see `Chat SDK bridge initialized { adapter: 'slack' }` with no errors.

## Phase 5: Flip the DM wiring to per-thread (manual)

The patches are inert without a per-thread `session_mode` on the DM wiring. Apply it per install, where it makes sense.

Find the DM wiring:

```bash
mise exec node@22 -- bin/ncl wirings list --json | jq '.[] | select(.session_mode != "per-thread")'
```

Or via SQL — list Slack DM wirings (the ones on `is_group=0` messaging groups):

```bash
sqlite3 -header -column data/v2.db "
  SELECT mga.id AS wiring_id, mg.platform_id, mg.name, mga.session_mode
  FROM messaging_group_agents mga
  JOIN messaging_groups mg ON mg.id = mga.messaging_group_id
  WHERE mg.channel_type = 'slack' AND mg.is_group = 0;
"
```

Flip the wiring (substitute your id):

```bash
mise exec node@22 -- bin/ncl wirings update <wiring-id> --session-mode per-thread
```

Or via SQL fallback if the ncl socket is unreachable (e.g., the host hasn't restarted yet to expose the socket):

```bash
sqlite3 data/v2.db "UPDATE messaging_group_agents SET session_mode='per-thread' WHERE id='<wiring-id>';"
```

The router re-reads wirings per inbound message, so the change takes effect immediately.

## Verify behavior end-to-end

1. Send a fresh top-level DM to the bot. Clanq's reply should appear **threaded** under your message.
2. Send a follow-up *inside* that thread. Same session — the bot has the prior context.
3. Send another top-level DM. New thread, new session — the bot does not have the previous DM's context.

If (1) lands flat (not threaded), the rewriter didn't fire — re-check Phase 3's anchor.

If (1) is threaded but (3) reuses the prior session, the wiring is still `shared` — re-check Phase 5.

## Rollback

Revert the source patches via git (uncommitted on first run, or in your top-of-rebase commit after a re-apply):

```bash
git restore src/channels/chat-sdk-bridge.ts src/channels/slack.ts
```

Flip the wiring back:

```bash
mise exec node@22 -- bin/ncl wirings update <wiring-id> --session-mode shared
```

Rebuild and restart:

```bash
mise exec node@22 -- pnpm run build
systemctl --user restart nanoclaw-v2-37e6d0ec.service
```

Existing per-thread sessions stay in the `sessions` table but become orphaned (no future message will resolve into them). The host's idle-session sweep cleans them up over time; if you want to drop them sooner, `sqlite3 data/v2.db "DELETE FROM sessions WHERE agent_group_id='<dm-agent-group-id>' AND messaging_group_id='<dm-mg-id>' AND thread_id IS NOT NULL;"` (run after the wiring rollback).

## Notes

- The skill does **not** auto-commit. After running, review the diff with `git diff` and commit yourself (this fork uses customizations-as-commits-on-top-of-upstream).
- After every upstream rebase that drops these patches, re-run `/add-slack-dm-threading`. Phase 1 makes it a no-op if everything is already in place.
- The `rewriteThreadId` hook is intentionally generic — other channel adapters could use it for similar adapter-quirk workarounds. Today only Slack consumes it.
- Group-channel behavior is unchanged: the router already auto-promotes group-chat Slack messages to `per-thread` via the `mg.is_group !== 0` clause in `src/router.ts` `deliverToAgent`. This skill only changes DMs.
