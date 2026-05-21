---
name: tickets
description: Open and track a Linear ticket on team `CLQ` for any non-trivial work — investigations, builds, refactors, multi-step plans — so the plan survives context loss. Skip for one-shot Q&A, single-file edits, and quick lookups.
---

# Role

External memory for plans and work. Tickets persist state, decisions, progress, and outcomes across turns and sessions. Linear holds the tracking shell; some ticket types also produce a longform doc under `plans/`.

# Context

| File                                 | When to read                                                                   |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| `references/types/project-plan.md`   | Multi-session work with sub-tasks or cross-dependencies.                       |
| `references/types/investigation.md`  | A research question whose answer fits in the Linear body.                      |
| `references/types/research.md`       | A research question that warrants a local `RESEARCH.md`.                       |
| `references/types/spec.md`           | An engineering change worth a paste-ready spec — bug, refactor, small feature. |
| `references/types/write-prd.md`      | A stakeholder PRD.                                                             |
| `references/types/routine-output.md` | A scheduled routine run.                                                       |
| `linear` skill                       | Linear MCP basics, citation format, label / status conventions.                |

Pull only the type file the current work needs.

# Threshold

Open a ticket before starting work that matches any of:

- Would plan with an in-turn task list at 3+ items (Claude Code: `TaskCreate` / TodoWrite).
- Spans multiple files, packages, or repos.
- Is an investigation rather than a one-shot lookup.
- Likely to span sessions, or could be resumed later.
- User frames the request with "plan", "design", "research", "investigate", "build", "refactor", "implement", or similar project-shaped language.

Don't open a ticket for: one-shot Q&A, single-file edits, lookups answered in a single query or read, fixes you can describe in one sentence. When in doubt, open one — cheap to close quickly.

The harness's in-turn task list handles the live checklist inside a ticket's execution — tickets are the durable layer (in Claude Code: `TaskCreate` / TodoWrite).

# Rules

1. Search before creating. Look for an existing open ticket on the same thread or task before opening a new one.
2. Ticket as plan. Description is the plan, comments are progress, PRs and docs are attachments. Don't keep a parallel plan in the chat thread. While still investigating, edit the description in place; once execution starts, append comments.
3. Cite as `<ID> — <one-line title>` with link. One line per ticket touched.
4. Close when done. One-paragraph outcome comment, status → done.
5. Load lean. Pull the current ticket and its direct dependencies — never the full backlog.
6. Read-only fallback. If the channel can't write, draft the ticket inline as a chat reply for the user to file. Don't retry.

# Working loop

1. Threshold check. No → do the work and move on.
2. Search the board for an existing open ticket on this thread or task. If found, read description + recent comments before acting.
3. Pick the ticket type from `references/types/`. Read its file.
4. Open the Linear ticket following the type file. The type file covers the Linear body shape and, if applicable, the local doc path and template.
5. Execute — comments for progress, attachments for new artifacts, sub-tasks when work fans out.
6. Close with a one-paragraph outcome.

# Resuming

When asked what's open or to resume a plan: cross-reference open CLQ tickets (status not-done, not blocked by another open ticket) with the Recent table in `plans/index.md`. List matches with status + last-active date; let the user pick. Linear carries the source of truth for status; `plans/index.md` carries the local-doc pointer.

# Dependencies

Use the backend's native primitives when work fans out:

- Sub-tasks — parallel pieces of one parent. Hierarchy in the tracker, not in chat.
- Blocked-by — set explicitly when one ticket waits on another.

# Fanning out execution

When 2+ tickets run in parallel from this thread, dispatch via Claude Code agent teams: `TeamCreate` to open the team, one `Agent` call per ticket with the shared `team_name`, communicate via `SendMessage`. Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Single-ticket investigations use an in-thread subagent (`Agent` with `subagent_type`).

# Output format

One line per ticket touched, with link:

- Created: `CLQ-42 — <title> (created, <type>)`
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
- `wiki/` — promote a ticket's outcome via the relevant skill's capture flag when the finding generalizes.
