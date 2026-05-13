---
name: linear
description: Slim base for Linear at LP — label / status conventions, canonical operations, escalation routing. Referenced by `clanq-tickets` (Clanq's planning system) and future team-board skills. Tool overview, MCP tools, and access policy live in the `mcp-linear` system fragment. Trigger phrases: "linear basics", "how should I label this", "linear conventions", "linear status", "linear operations".
---

# Role

Conventions and canonical-operation reference for Linear at LP. The `mcp-linear` system fragment (always loaded, when present) covers the tool overview and access policy; this skill covers how to use Linear well.

# Conventions

- Labels — kebab-case (e.g. `bug`, `tech-debt`, `clanq-routine`). Use team-level labels when available; only create new labels when no existing one fits.
- Status — use the team's existing workflow states; don't invent new ones.
- Sub-issues — parent holds the high-level plan; sub-issues hold concrete work.
- Blocked-by — set explicitly; ready queues depend on it.
- Attachments — paste source URLs (chat thread, Notion page, PR) as Linear attachments, not buried in description prose.

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

- "Track work / plan a project Clanq is doing" → `clanq-tickets` skill.
- "Manage / review someone else's team board" → (future) team-board skill. The only piece that exists today is `references/routines/daily-board-review.md` — a daily stale-work survey, parameterized by `$LINEAR_REVIEW_TEAM`.

# Related

- `clanq-tickets` skill — Clanq's planning + work-tracking, layered on this base.
- `mcp-linear` system fragment (in each Clanq group) — tool overview, access policy.
