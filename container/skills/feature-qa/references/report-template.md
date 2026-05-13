# Report template

Copy this shape into `wiki/qa/<feature-slug>-YYYY-MM-DD.md` at the end of every run. Replace every `<…>` placeholder. Drop sections that are empty (e.g. no bugs ⇒ drop the Bugs section).

```markdown
---
feature: <feature-name>
slug: <feature-slug>
date: YYYY-MM-DD
verdict: <HEALTHY | MINOR_ISSUES | CRITICAL_BUGS>
test_company: <uuid>
reviewer: feature-qa
---

# <Feature name> — QA report

## Verdict

<HEALTHY | MINOR_ISSUES | CRITICAL_BUGS>. <One-sentence rationale.>

Happy-path capture: <path or link to final GIF>.

## Acceptance criteria

| #   | Criterion        | Result                | Notes           |
| --- | ---------------- | --------------------- | --------------- |
| 1   | <criterion text> | pass / fail / partial | <one-line note> |
| 2   | <criterion text> | pass / fail / partial | <one-line note> |

## Bugs

### B1 — <short title> [critical|major|minor]

- Where: <URL or component>
- Trigger: <steps in one line>
- Expected: <what should happen>
- Actual: <what happens>
- Evidence: <path to GIF or screenshot>
- Linked criterion: #<n> | none

### B2 — <short title> [severity]

…

## Console

<Summary in 1–3 bullets. Pre-existing noise gets one line up top; feature-triggered errors become bugs above.>

## Mobile

<One paragraph or 2–3 bullets on 375×667 behavior. Drop if mobile was out of scope.>

## Out of scope / not tested

<List the things the run deliberately skipped: destructive actions, integrations not wired on the test company, etc.>

## Recommendation

<One paragraph for the caller. What to do before ship, what's safe to defer.>
```

## Verdict block rules

- Verdict line is verbatim one of the three values — no synonyms. Downstream tooling reads it as an enum.
- Rationale is one sentence, not a paragraph. Detail belongs in Bugs and Acceptance criteria.

## Bug ID rules

- IDs are `B1`, `B2`, … in discovery order, not severity order.
- One bug per entry. If two issues share a screenshot, write two entries that both reference it.

## Filing into the wiki index

After writing the report, append a line to `wiki/index.md` under the `## QA` section:

```
- [<feature-name> (YYYY-MM-DD)](qa/<feature-slug>-YYYY-MM-DD.md) — <verdict>. <one-line rationale>.
```
