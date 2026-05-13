# Wiki capture workflow

Protocol the `wiki` skill runs to write session findings into canonical wiki pages. Direct invocation (`/wiki capture`) uses the defaults below; calling skills can override the parameters when pointing at this file from their own `capture` subcommand. There is no buffer / untriaged layer — capture writes directly to canonical pages, with the user picking the target per item.

The agent acts as wiki librarian, not append-only logger: every candidate is checked against existing entries (duplicates, contradictions) and against the conventions in `SKILL.md` (unsourced judgments, out-of-scope content) before write. Structural drift (bloated files, stale index) is flagged inline in the log for ad-hoc cleanup later.

## Parameters

- `targets` — list of canonical destinations capture may write to. Examples: `wiki/domains/<slug>.md`, `wiki/<area>/<file>.md`, skill-relative `references/<file>.md`. The user picks per item; if none fit, the user can `retarget` to a new file invented inline. Default on direct invocation: any path under `wiki/`, picked per-candidate based on content.
- `ref_verification` — what kinds of refs to grep-verify before writing. Default on direct invocation: grep-verify every `repos/<name>/path:line` ref.
- `session_summary_kind` — short string used in the `wiki/log.md` summary line. Default: `wiki` on direct invocation, or the calling skill's name when overridden.

## Workflow

Sweep the transcript for findings worth keeping, then review inline.

1. Re-read the session for candidate findings — anything flagged inline with 🔖, plus surprising results, recurring patterns, file:line references, useful Notion / Linear / Slack pointers.
2. Print a numbered list inline. Each entry: title + proposed target file (chosen from the active `targets` set) + full body, in the format the target file uses. Cap at 10 candidates with full body. If more, say: "Found N candidates — too many for one pass. Showing the top 10 by significance. Reply `more` for the rest, or filter."
3. Lint pass. For each candidate, scan the proposed target file and sibling pages in the same `wiki/<area>/` (e.g. a candidate going to `wiki/data/gotchas.md` scans `wiki/data/*.md`; a candidate going to `wiki/domains/<slug>.md` scans `wiki/domains/*.md`; a candidate going to a top-level `wiki/<file>.md` scans `wiki/*.md` non-recursive). Annotate each affected candidate inline:
   - `⚠ near-duplicate of "<title>" in <path>` — existing entry covers similar ground.
   - `⚠ contradicts "<title>" in <path>: existing says <X>, candidate says <Y>` — claim conflicts.
   - `⚠ violates content conventions` — name the specific convention from `SKILL.md` (out of scope, mirrors code, unsourced judgment, missing frontmatter, etc.). Surface in chat or drop.
4. If `ref_verification` applies, grep-verify those refs in every candidate body. Annotate broken refs inline with `⚠ NOT FOUND` so the user can correct in their reply.
5. Ask: "Reply with what to keep — `all`, `none`, a list (`1, 3`), or per-item edits. Verbs: `rewrite N as: …`, `retarget N to <path>`, `merge N into <existing-entry>`, `replace <existing-entry> with N`, `both N` (keep new alongside existing)." Reject by default; require explicit accept.
6. Apply: write accepted candidates to target files. Append one summary line to `wiki/log.md`: `## [YYYY-MM-DD] capture | <session_summary_kind> | <session-summary>`. If during the lint pass you noticed structural drift (target file bloated, sections sprawling, `wiki/index.md` stale relative to actual pages), append a follow-up bullet under that summary: `⚠ drift: <observation>`. The user reviews the log when convenient and acts ad-hoc. Confirm inline (`✓ wrote N entries to <target>`).
7. Skill-tweaks scan. Run the protocol at `skill-tweaks.md` (sibling reference). Surface any findings inline as a `## Skill tweak proposals` section in the capture report. Omit when no finding clears the bar — proposals are behavioral feedback, not knowledge capture, and stay out of `wiki/log.md`.

During a session, calling skills flag noteworthy findings inline with 🔖 and a one-line note. No real-time writes — `capture` sweeps flags at the end.
