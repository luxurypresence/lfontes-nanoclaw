# Research patterns

Recipes for common navigator investigations. Each pattern: when to use it, the steps, what to capture.

## Trace a request end-to-end

When: "How does `<endpoint or trigger>` flow through the system?"

Steps:

1. Locate the entry point — REST handler, GraphQL resolver, or queue consumer in the relevant repo.
2. Walk the call chain via `Explore` agent, prioritizing service boundaries.
3. Identify external touchpoints (DB, queue, external API).
4. Note the response/return shape and side effects.

Capture: a `domains/<slug>.md` with the flow as bullets and key files cited.

## Find the logic users of X

When: "Who uses `<function/class/flag>`?" or "What's the blast radius of changing X?"

Steps:

1. `rg "<symbol>" repos/<name> --type <ts|py|go>`.
2. Cross-repo: repeat per repo in scope. Or use `gh search code 'org:luxurypresence "<symbol>"'`.
3. Group by call-site role (caller of, definer of, test of).

## Map a feature flag's blast radius

When: "What does flag `<name>` gate?"

Steps:

1. `rg "<flag-name>" repos/`.
2. For each hit, classify: gate (early return), branch (conditional path), config-only (no behavior gate).
3. Trace the gated branches forward to side effects.

## Why was <X> built?

When: tracing intent / scope of an existing feature.

Steps:

1. `git log --follow <file>` to find introducing commits.
2. `gh pr view <pr-number>` for description and reviewers.
3. Search Linear by the PR title or commit message for the originating ticket.
4. Search Notion for "[Domain] Design" or PRD pages.
5. Slack search the originating channel for the decision discussion.

## Domain map (cold start)

When: first investigation in an area — produces the seed domain note.

Steps:

1. List candidate repos via `repo-map.md`.
2. `Explore` per repo with the topic phrase — gather entry points + references.
3. Synthesize: 3–6 key files, the flow, gotchas, and related Notion/Linear/Slack pointers.
4. `/navigator capture` → drafts the domain note.

## Anti-patterns

- Don't trust Slack over code. Code wins.
- Don't paraphrase a Notion doc as fact — link to it and cite the relevant section.
- Don't recurse forever through Explore. Cap at 2 levels of "what calls X" before re-scoping the question.
