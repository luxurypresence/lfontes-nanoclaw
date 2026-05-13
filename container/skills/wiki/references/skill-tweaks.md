# Skill tweak proposals

Final step of `/wiki capture`. Surfaces session-derived suggestions for changes to skill `SKILL.md` files — rules to add, sharpen, or remove. Forward-looking ("what should the rule be?"), not backward-looking ("did you obey the rules?"). Reports inline; never edits. The actual edit goes through `skills-manager`.

## Bar

Default to silence. Skill rules load every session and bias every invocation; the cost of a bad rule recurs while the cost of a missing rule is occasional. Most sessions yield zero findings, and that's correct.

A finding passes only if every gate holds:

1. Session contains direct evidence. One of:
   - User explicitly corrected a failure mode in this session.
   - Internal recurrence — the same mistake landed twice or more before being caught.
   - High blast radius — something shipped to an external system (Linear, GitHub, Slack, the repo) wrong before being caught, and required a redo.

   One-off near-misses caught internally, defensible edge cases, and rules the user explicitly overrode don't qualify.

2. The proposed rule is verifiable. A subsequent session's behavior either complies or doesn't, observable in tool calls / outputs / chat. Hedging language ("be careful", "consider", "think about") fails this gate.

3. Not a duplicate. Read the target skill's `SKILL.md` first. If an existing rule covers the territory, propose a diff to that rule, not a new one.

4. Location is named. Target file (`skills/<name>/SKILL.md` or a reference under it), section, and the specific line(s) to add, replace, or remove.

5. Net-neutral or net-negative on prose. If adding N lines, identify N lines to compress or remove elsewhere. Tighten before adding.

## Workflow

1. Scan the transcript for failure moments — user corrections, mid-task pivots, externally-visible mistakes.
2. For each, check all five gates. Drop on first failure.
3. For survivors, draft as a proposal: target, evidence quote, diff with line accounting, one sentence on verifiability.

## Output

Inline section, after the wiki-write confirmation. Use the format below; omit entirely if no finding clears the bar.

```markdown
## Skill tweak proposals

### 1. `skills/<name>/SKILL.md` — <one-line summary>

Evidence: <user-correction quote or visible-failure description>

Proposed diff:

- <Add to | replace in | remove from> <section>: <exact text>
- Compensate by: <what tightens or drops elsewhere>

Verifiable because: <how future behavior either complies or doesn't>
```

## When to stop and ask

- A finding clears evidence and verifiability but the diff shape is unclear — surface as a question, not a proposal.
- A proposal targets a skill that wasn't invoked this session — drop; without behavioral signal the change is speculative.
