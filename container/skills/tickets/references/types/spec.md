---
name: spec
description: Lightweight engineering artifact for work that doesn't need a PRD — bug fix, enhancement, refactor, small feature. Paste-ready for a Linear ticket.
---

# Spec

The catch-all when a PRD is overkill. `write-prd` produces a full PRD + spec for stakeholder-facing features; `spec` covers everything else — anything that lives in a single Linear ticket.

## Path

- Plan dir: `plans/YYYY-MM-DD--{slug}/`
- Output: `SPEC.md`

## On invocation

1. Take the slug (ask if missing).
2. If `SPEC.md` already exists, offer to view or start a new version.
3. Read any sibling `PRD.md` / `RESEARCH.md` first — link, don't restate.
4. Otherwise: talk through the situation and done-state, draft.

## Output shape

Three sections. Fixed. No buffet.

```markdown
# [Title]

## Context

≤ 3 sentences. State the situation — what's broken / unmet / motivating the refactor. Link to predecessor tickets and wiki pages rather than restating them. No justification walks ("this matches the cadence at which…"); the choice goes in Notes if it needs defending at all.

## Acceptance criteria

- [ ] Observable outcomes only. The system does X. After the change, Y is true.
- [ ] ≤ 5 bullets, ≤ 1 line each.
- [ ] No file paths, library names, algorithm choices, or "dispatched through X". If it constrains the implementation, it's a Note.

## Notes

Free-form bullets. One bucket, not seven. The reader is an engineer about to paste this into their team's tracker and start work — they need what changed, what done looks like, what'll bite them. Two short Notes beats six elaborated ones; one screen is the target, not a worst case. Drop the heading style, just write bullets:

- Schema refs (`core.contact_enrichment.<column>`), `file:line` pointers
- Gotchas / interactions with existing code paths
- Rate-limit / SLO constraints
- Rollout (flag name, canary plan, ramp)
- Migration order, data backfill
- Open questions
```

### AC format — match the work

- Checklist for backend, refactors, API additions, infra (default).
- Given/When/Then when behavior branches on state/input.
- Scenario prose for one or two complex flows.

## Leave out

- User stories ("As a…"). Linear: anti-pattern.
- Business case, success metrics, stakeholders. PRD's job, or Linear fields.
- Design rationale, alternatives considered. Link to the design doc.
- Wireframes inline. Link to Figma — embedded images rot.

## Finalize

Update `plans/index.md` (Type: `spec`). Frontmatter `notion:` left empty until pushed.
