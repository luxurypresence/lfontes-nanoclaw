---
name: linear
description: Reference for working with Linear at LP — access, labels, statuses, citation format. Referenced by `tickets` and team-board skills.
---

# Tools and access

Linear is LP's issue tracker. The MCP server exposes the standard Linear tools (issues, projects, teams, comments, status updates, labels, cycles). Access level is governed by which Linear API key OneCLI injects per channel — write attempts under a read-only key will return 401/403. When citing tickets, prefer the Linear ID (e.g. `ENG-1234`) plus a one-line title.

# Conventions

- Labels — kebab-case (e.g. `bug`, `tech-debt`, `clanq-routine`). Use team-level labels when available; only create new labels when no existing one fits.
- Status — use the team's existing workflow states; don't invent new ones.
- Sub-issues — parent holds the high-level plan; sub-issues hold concrete work.
- Blocked-by — set explicitly; ready queues depend on it.
- Attachments — paste source URLs (chat thread, Notion page, PR) as Linear attachments, not buried in description prose.

# Writing tickets

Tickets stand alone. The reader doesn't have your worktree, your QA report, or your terminal scrollback.

- Inline the repro, severity, and acceptance criteria in the ticket body. Don't write "see RESEARCH.md" or "see the QA report" — the engineer can't open them.
- Cite code with GitHub URLs (`https://github.com/luxurypresence/<repo>/blob/<branch>/<path>#L<line>`) pinned to the repo's default branch. Relative paths (`repos/...`, `wiki/...`, `plans/...`) don't render in Linear.
- Attach canonical sources (PR, public Notion page) when they add what inline text can't.

# Canonical operations

- Create issue — title, description (markdown supported), team, optional assignee/labels.
- Update issue — comments for progress; attachments for new artifacts; status transitions per the team's workflow.
- Search — most-specific filter first (team + label + status, then text). Keep result sets small.
- Get with children — pulling a parent issue pulls sub-issues in one call; don't fetch them separately.

# Auth note

Access depends on which Linear key the channel has. For LP at writing:

- `cli-with-luis`, `clanq-dm` — RW on the LP workspace via the org-wide key.
- `clanq-channels` — read-only on the org-wide key.
- All Clanq groups — RW on team `CLQ` via a separate CLQ-scoped key (when wired).

If a write returns 401/403, the channel doesn't have a write-capable key for that team — surface the failure, don't retry.

# Routing

- "Track work / plan a project" → `tickets` skill.
- "Manage / review someone else's team board" → (future) team-board skill. The only piece that exists today is `references/routines/daily-board-review.md` — a daily stale-work survey, parameterized by `$LINEAR_REVIEW_TEAM`.

# Related

- `tickets` skill — persistent planning + work-tracking, layered on this base.
