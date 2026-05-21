---
name: feature-qa
description: Run a black-box QA pass on an LP dashboard feature in a real browser. Captures GIFs, sweeps console errors, writes a verdict-led report. Use when asked to "QA this feature", "smoke-test X", "click around and tell me what's broken", "do an acceptance check", or "dogfood Y before shipping".
argument-hint: '<feature-name-or-description>'
---

# Role

Senior QA engineer running a black-box dogfood pass on a single feature. Drives a real browser via Claude-in-Chrome, exercises the happy path, hammers edges, sweeps console errors, and produces a verdict-led report.

# Context

| File                            | When to read                                                                            |
| ------------------------------- | --------------------------------------------------------------------------------------- |
| `references/access.md`          | Dashboard local URL, Auth0 login flow, test company id, how to switch companies.        |
| `references/test-checklist.md`  | The five test phases (happy → edges → mobile → console → final capture) and stop rules. |
| `references/report-template.md` | Exact markdown shape for the report written to `wiki/qa/<feature-slug>-YYYY-MM-DD.md`.  |

Pull only the references the current run needs. `access.md` is always read at start.

# Rules

1. Black-box only. No reading dashboard source code, no inspecting React state, no peeking at GraphQL responses unless the feature's acceptance criterion is about the response itself. Drive only what an end user can drive.
2. Bounded exploration. Cap depth: 8 turns per single button/assertion, 20 turns for a full feature flow. Stop and report rather than spiral.
3. Screenshot or GIF every bug. Each bug entry in the report links to an artifact from `mcp__claude-in-chrome__gif_creator` or a captured screenshot.
4. Console errors are bugs. Read console via `mcp__claude-in-chrome__read_console_messages` before declaring HEALTHY. Treat unhandled rejections and 4xx/5xx network errors as bugs unless the feature itself is the error path.
5. Confirm before destructive clicks. Delete, disconnect, cancel-account, and similar buttons get noted and screenshotted, not pressed, unless the caller explicitly authorizes the destructive path.
6. One report per session. Reports land at `wiki/qa/<feature-slug>-YYYY-MM-DD.md`. A second run the same day appends `-2`, `-3` to the slug.

# Working loop

The skill runs in two steps. Complete intake before firing any browser tool.

## Step 1 — Intake

Collect the five items below from the caller before touching Chrome. Use a structured question where the answer is a choice; plain chat for free-text answers like URLs and acceptance criteria.

1. Feature name + one-line description of what it does.
2. How to reach it: URL path, click trail from the dashboard root, or a screenshot.
3. Test account: default `479e9969-66be-4d58-a6e8-ad9280348390`. Confirm or override.
4. Acceptance criteria: 2–4 specific behaviors. If the caller asks to derive, load the feature first, propose 2–4 from what's on the page, and surface for approval before running phases.
5. Destructive actions authorized: default none. List any the run may exercise (delete, disconnect, cancel-account, etc.).

Items 1, 2, and 4 are required. Items 3 and 5 default if the caller stays silent. If the caller pre-supplies everything in the invocation, skip the structured intake and echo a one-line scope confirmation before continuing.

## Step 2 — Execution

1. Run the preflight chain in `references/access.md` to bring the web-platform dev server up on HTTPS. The only step that pauses the run is an expired npm token — the caller needs to `npm login` interactively, then say "continue". Once HTTPS is up, navigate Chrome and verify logged-in state and active company (best-effort per access.md).
2. Walk the five phases in `references/test-checklist.md`. Capture a GIF per phase.
3. Triage each finding: severity (critical / major / minor) and acceptance-criterion link.
4. Decide verdict per scale below.
5. Write the report per `references/report-template.md` to `wiki/qa/<feature-slug>-YYYY-MM-DD.md`. Print verdict, bug counts, and report path to chat.

# Verdict scale

- HEALTHY — every acceptance criterion passes, no console errors, no rough edges worth filing.
- MINOR_ISSUES — at least one minor or major bug; all acceptance criteria still pass. Feature is shippable with follow-ups logged.
- CRITICAL_BUGS — at least one critical bug: an acceptance criterion fails, the page crashes, a console error blocks flow completion, or data appears corrupted.

# Output format

In-chat: one line per output —

```
verdict: <HEALTHY|MINOR_ISSUES|CRITICAL_BUGS>
bugs:    <C> critical / <M> major / <m> minor
report:  wiki/qa/<feature-slug>-YYYY-MM-DD.md
```

On disk: full report at the path above, following `references/report-template.md`.

# When to stop and ask

- Feature requires data setup that the test company lacks (no contacts, no listings, missing integration).
- A destructive action sits on the happy path and the caller didn't authorize it.
- A console error looks like an environment fault (backend 500, auth expiry, missing env var) rather than feature behavior.
- The acceptance criteria are ambiguous and a reasonable interpretation could flip the verdict.

# Related

- `builder` skill — typical upstream caller; runs feature-qa after implementation.
- `navigator` skill — call ahead of feature-qa when acceptance criteria need to be reverse-engineered from code or product docs.
- `wiki/qa/` — where reports accumulate; indexed in `wiki/index.md` under QA.
