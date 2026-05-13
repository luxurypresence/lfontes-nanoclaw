---
name: clanq-tickets
description: Clanq's persistent planning and work-tracking. External memory for plans, in-flight work, decisions, and outcomes — durable across turns, sessions, and channels so a multi-day project doesn't lose context and two threads don't duplicate work. Backend today is the Clanq Linear board (team `CLQ`); the skill is about the process. Trigger phrases: "create a ticket", "track this", "what am I working on", "open clanq tickets", "log this work", "plan in CLQ", "clanq board", "resume <project>".
---

# Role

External memory for Clanq's plans and work. Tickets persist plan state, decisions, progress, and outcomes across turns and sessions. Backend today is Linear team `CLQ`; backend specifics sit in `# Backend notes`.

# Context

| File                          | When to read                                                                            |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| `references/templates.md`     | Writing a ticket body — project plan, investigation, routine-output skeletons.          |
| `linear` skill                | Linear MCP basics, citation format, label / status conventions.                         |

# Threshold

Rule of thumb: anything that requires a plan or would benefit from a todo list gets a ticket. The ticket is the plan — open it at the start of the work, not after the fact. Decide at the moment you decide to plan; usually that's at the start of a session, sometimes mid-session when scope reveals itself.

- Ticket: any investigation (the plan is what to look at), file generation, multi-step work, scheduled-routine output, anything where you'd otherwise reach for a markdown todo.
- No ticket: one-shot Q&A, lookups answered in a single query or read, quick edits that don't need planning.
- When in doubt, open one. Cheap to close quickly. Many tickets is fine — that's what CLQ is for.

# Rules

1. Search before creating. Look for an existing open ticket on the same thread or task before opening a new one.
2. Ticket as plan. Description is the plan, comments are progress, PRs and docs are attachments. Don't keep a parallel plan in the chat thread.
3. Cite as `<ID> — <one-line title>` with link. One line per ticket touched.
4. Close when done. One-paragraph outcome comment, status → done.
5. Load lean. Pull the current ticket and its direct dependencies — never the full backlog.
6. Read-only fallback. If the channel can't write, draft the ticket inline as a chat reply for Luis to file. Don't retry.

# Working loop

1. Threshold check. No → do the work and move on.
2. Search the board for an existing open ticket on this thread or task. If found, read description + recent comments before acting.
3. Create or update with a template from `references/templates.md`. Attach the originating thread URL.
4. Execute — comments for progress, attachments for artifacts, sub-tasks when work fans out.
5. Close with a one-paragraph outcome.

# Dependencies

Use the backend's native primitives when work fans out:

- Sub-tasks — parallel pieces of one parent. Hierarchy in the tracker, not in chat.
- Blocked-by — set explicitly when one ticket waits on another.

# Output format

One line per ticket touched, with link:

- Created: `CLQ-42 — <title> (created, <template>)`
- Updated: `CLQ-42 — <title> (status: <state>)`
- Closed: `CLQ-42 — <title> (closed, <one-clause outcome>)`

# When to stop and ask

- About to close without a clear outcome to summarize.
- Auth fails on a channel where writes were expected.

# Backend notes — Linear / CLQ

- Board: `CLQ` at https://linear.app/luxurypresence/team/CLQ/all.
- Auth: a Linear key with RW on `CLQ` (distinct from the org-wide LP key; available even in groups whose org-wide key is read-only).
- Threading: attach the chat URL as a Linear attachment and include a `Thread:` line in the description.
- For MCP basics, citation format, and status conventions, see the `linear` skill.

# Related

- `linear` skill — base reference for Linear MCP and conventions.
- `work` skill — Luis's local plan dispatcher; complementary.
- `wiki/` — promote a ticket's outcome via the relevant skill's `capture` when the finding generalizes.
