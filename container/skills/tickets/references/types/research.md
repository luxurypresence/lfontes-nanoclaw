---
name: research
description: Investigate a system or area. Routes through navigator (codebase + Notion + Linear + Slack) and data-analyst (production data); Auggie as second opinion. Output is a RESEARCH.md doc.
---

# Research

Investigate something. Dispatch subagents. Write it up.

## Path

- Plan dir: `plans/YYYY-MM-DD--{slug}/`
- Output: `RESEARCH.md`

## On invocation

1. Take the slug (ask if missing).
2. If `RESEARCH.md` already exists in the dir, offer to view it or start a new version.
3. Otherwise: talk through the question, dispatch as needed, draft.

## Approach

Light back-and-forth, not a fixed interview. Adapt to what's known.

Tool routing:

- **navigator** (primary agent) — codebase, Notion docs, Linear tickets, Slack threads. Wired to all of them. Most research questions go here first.
- **data-analyst** — production data: counts, coverage, distributions, affected-row queries.
- **Explore** — quick local file lookup when navigator is overkill.
- **Auggie** — second opinion only. Reach for it after navigator has returned nothing on a topic that should exist somewhere, or to sanity-check a non-obvious finding. Never the first source.

Dispatch independent calls in parallel. Quantify findings (numbers, `file:line`) or move them to Open Questions — a claim without a source is a hypothesis.

## Output shape

`RESEARCH.md` adapts to what surfaced. Typical skeleton:

```markdown
---
notion:
last_updated: YYYY-MM-DD
---

# [Title]

## TL;DR

3-5 bullets. Lead with the headline finding.

## Context

Why this matters now. Triggering ticket / Slack / PRD if relevant.

## Current State

What exists today — schema, code paths (`file:line`), prod numbers.

## Findings

The interesting stuff. One heading per finding.

## Open Questions

What you couldn't resolve.
```

Add sections as the research warrants: Recommendations, Sources, ASCII diagrams, enforcement tables. Drop sections that have nothing to say. Style: direct, factual, no hedges.

## Finalize

Update `plans/index.md` (Type: `research`). Frontmatter `notion:` left empty until pushed.
