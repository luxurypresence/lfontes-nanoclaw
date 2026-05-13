---
name: write-prd
description: Create a PRD through AI-guided interview
---

# Write PRD

## Philosophy

- **Markdown-first** — all outputs as `.md` files, git-friendly and machine-parseable
- **Clarity helps, rigidity hurts** — aim for specificity; accept ambiguity in early-stage ideas
- **Requirements over implementation** — PRDs define _what_ to build and _why_, not _how_
- **Guidelines, not rules** — user needs always win over process

Company context: Luxury Presence — marketing/website software for luxury real estate agents (14,000+ agents, $300B+ annual sales).

## Path Conventions

- Plan directory: `plans/YYYY-MM-DD--{slug}/`
- Output: `PRD.md` (+ `uploaded/` if PM shares files)
- Full date prefix enables correct chronological sorting within a month
- Slug is kebab-case (e.g., `smart-actions-improvements`)

---

## On Invocation

1. Ask for a project slug
2. Calculate path: `plans/YYYY-MM-DD--{slug}/` using today's date
3. If PRD.md already exists there, offer to view it or start a new version
4. Otherwise, run the interview below

---

## Interview

### Setup

1. Create directory: `plans/YYYY-MM-DD--{slug}/`
2. Tell user: "Let's create your PRD. This takes about 10-15 minutes."

### Step 1: Context + Solution

Present the priming prompt:

```
We'll build a PRD with these sections:

**Core**: Background & Context, Proposed Solution, Scope, Success Metrics, Open Questions
**Optional** (you choose later): User Stories, UI/UX Overview, Edge Cases

If you have supporting materials (docs, screenshots, Slack threads), share them anytime.

---

**Context** — What problem or opportunity are we addressing?
- Why is this important? Why now?
- Why is this good for the business? For users?

**Proposed Solution** — What are you proposing?
- What does it look like? Where in the product?
- Why this approach? What alternatives did you consider?
```

After PM responds:

- Store full response for later reference
- If files shared, save to `uploaded/` and acknowledge
- Briefly acknowledge 2-3 key points: "Got it — so this addresses [problem] by [solution], driven by [need]."
- Proceed to Step 2

### Step 2: Clarifying Questions

Analyze Step 1 response and ask **5-7 targeted questions in one message** covering gaps in:

- **Context**: Why now? Who's affected? Evidence?
- **Solution**: Scope boundaries? Alternatives?
- **Metrics**: How to measure success?
- **Dependencies**: Teams, systems, constraints?
- **Timeline**: MVP vs later? What defines "done"?
- **Spirit**: Quick fix or major initiative?

Open with 1-2 sentences acknowledging key points, then ask all questions at once.

After PM responds: **no follow-up round** — move directly to Step 3.

### Step 3: Summary + Risks + Assumptions + Approval

Present a consolidated summary for single-point approval:

```
**What we're solving:** [1-2 sentences]

**Proposed solution:** [1-2 sentences]

**Key scope items:**
- In: [3-4 bullets]
- Out: [2-3 bullets]

**Success metrics:** [2-3 metrics]

---

I also identified some potential risks, assumptions, and open questions:

**Risks:**
- [3-5 AI-generated risks specific to this PRD context]

**Assumptions:**
- [3-5 AI-generated assumptions]

**Open questions:**
- [3-5 AI-generated questions]

---

Does this capture everything correctly? Add, remove, or modify as needed.
```

**AI generation guidance**: Base risks on complexity/dependencies/scope mentioned. Base assumptions on user behavior/data/tech implied. Base questions on gaps and unresolved dependencies. Make examples specific to the PRD, not generic. If Steps 1-2 were minimal, generate fewer (3 instead of 5).

If changes needed → revise and re-present. If approved → proceed to Step 3.5.

### Step 3.5: Optional Sections

Ask PM:

```
Before I generate the PRD, add any optional sections?

- **User Stories** — Narrative scenarios of user interactions
- **UI/UX Overview** — Interface location, interactions, error states
- **Edge Cases** — Unusual scenarios and system behavior

List the ones you want, or say "skip".
```

For each selected section:

1. **AI-generate** content from Steps 1-3 context
2. **Present** with accept / improve / reject options
3. If rejected, conduct fallback mini-interview (below)

**User Stories**: Generate 2-5 stories in format "As a [persona], I [need/want] [capability], so that [benefit]."

- Fallback: "Describe key scenarios: who is the user, what are they trying to do, what happens step-by-step?"

**UI/UX Overview**: Generate sections for Location, Key Interactions, Error States, Visibility/Debugging.

- Fallback: "Where does this live? Key interactions? Error states? Debugging features?"

**Edge Cases**: Generate 2-6 cases with Scenario + User Experience for each.

- Fallback: "What tricky scenarios need handling? For each: the situation, what the user sees, how they recover."

---

## Generate PRD.md

Save to `plans/YYYY-MM-DD--{slug}/PRD.md`.

**Template:**

```markdown
# [Title]

## TL;DR

[1-2 sentences, solution-focused, ~20-30 words. Problem is implicit.]

## Context

[2-4 short paragraphs (2-3 sentences each): current state → business impact → benefits.
Direct, factual tone — "basic" not "broken", "table-stakes" not "sophisticated".]

## Proposal

[2-4 short paragraphs (2-3 sentences each): high-level solution → key capabilities → rollout.]

**Success Metrics:**

- **[Metric 1]**: [Target]
- **[Metric 2]**: [Target]
- **[Metric 3]**: [Target]

## User Stories

[If selected. Format:]

**User Story 1:**
As a [persona], I [need/want/can't/don't] [capability], so that [benefit].

**User Story 2:**
As a [persona], I [need/want/can't/don't] [capability], so that [benefit].

## UI/UX Overview

[If selected.]

### Location

[Where in the product]

### Key Interactions

[Primary user interactions and workflows]

### Error States

[Validation rules and error handling UX]

## Edge Cases & Error Handling

[If selected. Format:]

### [Edge Case Title]

**Issue**: [Scenario description]
**Behavior**: [How system handles it]

## Requirements

### In Scope

- [Bullets]

### Out of Scope

- [Bullets]

### Phasing

[Only if PM mentioned phases]

- **Phase 1 (MVP)**: ...
- **Phase 2**: ...

### Assumptions & Constraints

- [Key assumptions]

## Open Questions

- [Questions]
```

**Style**: Active voice, professional. Core sections ~500-800 words. Optional sections add 200-500 words each. Paragraphs 2-3 sentences, not walls of text.

## Finalize

1. Update `plans/index.md` (Type: `prd`). Frontmatter `notion:` left empty until pushed.

### Quality Suggestions

Provide 1-3 optional suggestions (not blockers). Focus on the most impactful:

- Vague metrics without targets ("fast" → specific response time)
- Undefined user types or roles
- Unspecified integrations

Present as:

```
A few areas that could be clearer (optional):
- [Suggestion 1]
- [Suggestion 2]

Want to clarify any of these now? Your choice!
```

### Close

```
PRD created at plans/YYYY-MM-DD--{slug}/

Next steps:
- Review PRD.md and refine if needed
- Share with engineering for technical review
- Use Auggie for codebase/data research when ready
```
