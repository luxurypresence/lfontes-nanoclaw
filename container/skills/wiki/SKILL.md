---
name: wiki
description: Custodian of `wiki/`. Sweeps session findings into canonical pages and lints for drift. Use at end of session or when asked to "save findings", "capture this", "wiki capture", "wrap up", or "lint the wiki".
argument-hint: '[capture | lint]'
---

# Role

Single owner of `wiki/`. Sweeps the session for flagged candidates, reviews them with the user, writes to canonical pages, appends an audit line. Other skills don't write to `wiki/` directly — they emit 🔖 flags and hand off to this skill.

# Context

| File                         | When to read                                                                               |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| `references/capture.md`      | The capture protocol — sweep, review, lint, write. Read on every `capture` invocation.     |
| `references/skill-tweaks.md` | Skill-tweak proposal protocol — final step of capture. Read on every `capture` invocation. |
| `references/lint.md`         | The lint protocol — read-only drift checks. Read on every `lint` invocation.               |
| `wiki/index.md`              | Catalog of existing pages — read to identify near-duplicates and where new entries land.   |
| `wiki/log.md`                | Audit trail of past capture events. Append a summary line per capture write.               |

`ls wiki/` to discover the rest of the structure (`domains`, `data`, `qa`, `sop`, top-level files).

# Rules

1. No silent writes. Every candidate is reviewed inline; the user accepts per item before any write.
2. Dedup + conflict lint per candidate. Scan the proposed target file and sibling pages in the same `wiki/<area>/`.
3. Apply the conventions below during the lint pass. Surface candidates that violate in chat — drop or rewrite.
4. Append one summary line to `wiki/log.md` on every capture invocation. Note drift observations inline under that summary when seen.
5. Don't edit non-wiki files. Skill-reference promotions are a separate flow.

# Conventions

Content rules for everything under `wiki/`. Apply to both capture writes and direct edits.

1. Scope: LP knowledge only — product, codebase, data, ops. Meta-knowledge about agent tooling (Claude Code, Auggie, MCP, shell, dotfiles) belongs in personal notes, not here.

2. Don't mirror the code. Anything `rg` / `fd` can find in a local clone stays out — file-pointer lists, per-function refs, schema dumps, code walkthroughs. Keep cross-cutting relationships, ownership / routing facts, gotchas with a `path:line` anchor, behavior-affecting constants, and structural rationale. Heuristic: if a bullet helps someone who already has the repo open answer something `rg` alone wouldn't, keep it.

3. Capture what is, not what should be. Surprising behavior is captured as neutral fact ("X is hardcoded to Y"), not critique. Judgments — fix this, deprecate that — need an attributable source (person, doc, Slack, Linear) and a date when known. Surface unattributable judgments in chat; never author them in the wiki.

4. Frontmatter required. Every content file carries:

   ```yaml
   ---
   name: <kebab-slug> # cross-ref handle; usually matches filename without `.md`
   description: <one-line> # same one-liner as in `wiki/index.md`
   last_verified: YYYY-MM-DD # checked against reality on this date
   ---
   ```

   Specialized areas add fields: `wiki/domains/*` → `domain`, `repos`; `wiki/qa/*` → `feature`, `slug`, `verdict`, `test_company`, `reviewer`; `wiki/sop/*` → `status`, `audience`. Skip on `wiki/index.md` and `wiki/log.md` — meta-files.

5. `last_verified` is not "edited". Update it only when you've re-checked the content against reality. "Edited" comes from git; "verified" is the human signal lint depends on. Lint flags pages where `last_verified` is older than the file's last git commit.

# Working loop

Default action is `capture`. Run the protocol at `references/capture.md` — it covers the sweep, the lint pass, and the write.

# Subcommands

## `capture` — sweep session findings into canonical wiki pages

Run the workflow at `references/capture.md`. Defaults when invoked directly (no calling-skill parameters):

- `targets`: any canonical path under `wiki/` — picked per candidate based on content (domain notes → `wiki/domains/`, schema / query findings → `wiki/data/`, QA reports → `wiki/qa/`, SOPs → `wiki/sop/`, repo-level → top-level `wiki/<file>.md`).
- `ref_verification`: grep-verify every `repos/<name>/path:line` ref.
- `session_summary_kind`: `wiki`.

## `lint` — read-only drift checks against `wiki/`

Run the workflow at `references/lint.md`. Reports broken cross-links, stale path references, oversized files, and `wiki/log.md` drift. Never edits — output is an in-chat markdown report; the user decides which findings to act on.

# When to stop and ask

- No findings flagged and nothing in the transcript looks worth keeping — confirm before running an empty sweep.
- A candidate conflicts with an existing wiki entry in a way the lint pass can't resolve mechanically (factual contradiction, not phrasing).

# Related

- `skills-manager` skill — skill authoring conventions and routing to `skill-creator`.
- Calling skills — emit 🔖 flags during work; this skill sweeps and writes. `feature-qa` is an exception: it writes its QA report straight to `wiki/qa/` as its native output, not via capture.
