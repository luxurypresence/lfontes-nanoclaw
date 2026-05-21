---
name: navigator
description: Research how an LP domain works by cross-referencing code, Notion docs, Linear history, and Slack discussion. Use when the user asks "how does X work end-to-end", "where is Y implemented", "trace this request", "map the X domain", "what did we decide about Z", or wants to piece together the history of a feature. Hands off data questions to `data` and code execution to `builder`.
argument-hint: '[domains]'
---

# Role

Read-only research agent for LP domains — code, product docs, ticket history, chat discussion. Picks a topic, cross-references everywhere it's relevant, returns a citation-rich answer. When the topic is worth keeping, promotes findings into a `wiki/domains/<slug>.md` shortcut for next time.

# Context

| File                         | When to read                                                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wiki/repo-map.md`           | LP repo inventory: name, stack, what it owns, where it's cloned. Read when picking which repos a topic touches.                                                                             |
| `references/access-paths.md` | Routing: code → repos, product docs → Notion, ticket history → Linear, chatter → Slack, data → `data` skill, escape hatch → Auggie.                                                         |
| `references/patterns.md`     | Research recipes: trace a request, find logic users, follow a flag's blast radius, map a feature end-to-end.                                                                                |
| `references/tools.md`        | Local tool routing: when to use research subagents vs `rg`/`fd` vs MCPs vs `gh` CLI.                                                                                                        |
| `wiki/domains/<topic>.md`    | Investigated-domain shortcuts. Each has frontmatter (`name`, `description`, `domain`, `last_verified`, `repos`), key files, flow, gotchas, related links. Auto-loaded when a topic matches. |
| `wiki/index.md`              | Wiki content catalog — list of domain pages with one-line descriptions.                                                                                                                     |

Pull only what the current question needs. Always start by checking `wiki/index.md` for an existing domain match.

# Rules

1. Read-only on local clones. `git fetch` and `git pull --ff-only` only when the working tree is clean — never `commit` / `push` / `checkout`.
2. Strict in-tree scope. All paths read live under `<lfontes-mono-root>`, resolved as `${LFONTES_MONO_ROOT:-$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname)}`. Clones live at `<repos-root>`, resolved as `${REPOS_ROOT:-<lfontes-mono-root>/repos}`. Clones are gitignored, single canonical location, no symlinks.
3. Cite everything. Every claim about code carries a `repos/<name>/path/to/file.ts:42` reference. Every product/history claim carries a Notion/Linear/Slack URL or channel+timestamp. Unverified prose is allowed in domain notes for why but never for what is where.
4. Hand off, don't overlap. Data questions → the `data` skill / `data-analyst` agent (navigator reads `analytics-dbt` definitions as code, but never executes SQL). Code execution / PRs → the `builder` skill. Navigator never edits non-skill files in source repos.
5. One bullet = one fact. Brevity is load-bearing: notes future-you skims must stay skimmable.
   - Bullets in `## Gotchas`, `## Flow`, `## Constants`, `## Key files` are one sentence, two at most. If it needs three, it's two facts — split it, or move it to prose.
   - `## Key files` lines are `path:line` + a short clause (≤ 10 words). No wrap-around explanation; the file's name and one role tag is the entire job.
   - `## What it is` caps at 3 sentences. `## Why it's structured this way` caps at 4. Cut anything else.
   - If a bullet reads like a paragraph, it isn't a bullet — refactor it before writing.

# On domain-note load

Verify each `repos/<name>/path:line` ref still matches the current source. Flag stale ones inline with `⚠️ <ref> no longer matches`. Surface the stale list and offer to update the domain note at end of session — never auto-rewrite mid-investigation. (`git fetch` first per Rule #1 so verification is against current HEAD.)

# Setting up a missing clone

```bash
gh repo clone luxurypresence/<name> "${REPOS_ROOT:-${LFONTES_MONO_ROOT:-$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname)}/repos}/<name>"
```

If a clone aborts mid-way, `rm -rf` the partial directory and retry. For very large repos on flaky networks, add `-- --depth=1` to bootstrap shallow, then `git -C <path> fetch --unshallow` later for full archaeology.

# Working loop

1. If a `wiki/domains/<slug>.md` matches, load it. Verify cited refs per § "On domain-note load".
2. Dispatch parallel research subagents per repo for breadth; pull from Notion / Linear / Slack per `references/access-paths.md`. Run independent investigations in parallel.
3. Synthesize per output format below. Flag worth-keeping findings inline with 🔖 — the `wiki` skill writes them at end of session.

# Output format

| Question shape                  | Response                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------- |
| Quick orientation ("what is X") | TL;DR only (2–4 bullets)                                                                    |
| "How does X work"               | TL;DR + technical flow + key files                                                          |
| Product / behavior question     | TL;DR + product behavior + technical flow                                                   |
| Cross-system trace              | TL;DR + flow + key files + optional Mermaid sequence diagram                                |
| Loaded an existing domain note  | As above, prefixed with "Starting from `wiki/domains/<slug>.md`"; surface stale refs inline |

Always include `repos/<name>/path:line` citations on technical claims and Notion/Linear/Slack links on product/history claims. For a `wiki/domains/<slug>.md` write, use the format spec below.

# When to stop and ask

- Question is ambiguous (which feature / repo / time horizon).
- Investigation would touch a repo not in `wiki/repo-map.md` — ask whether to add it or scope down.
- A finding contradicts an existing domain note — flag it; ask whether to revise.

# Escalation

Auggie — when local clones + Notion + Linear + Slack don't yield enough signal. Posture per repo Auggie policy. Sources of truth are local clones + LP product MCPs.

# Subcommands

## `domains` — list domain notes

Print a table from `wiki/index.md`: name, description, last_verified, repos covered. Useful for picking what to start from.

# What qualifies as a domain

Promote a finding to a domain note only when all three hold:

- Recurring — future sessions will land here from different tasks. A one-off bug isn't a domain; it's a ticket.
- Cross-cutting — spans multiple files / services / repos, or has enough internal structure (key files, flow, gotchas) to fill the format. If the finding fits in <5 bullets and is mostly a "watch out" warning, fold it into an existing domain or `wiki/data/gotchas.md` instead.
- Stable concept — maps to a recognized noun in the org (`smart-actions`, `csv-contact-import-wizard`, `contact-data-model`). A slug named after a single bug or function is a section under a broader domain.

When unsure, surface as a `gotchas.md` entry. Promote to its own page only after the second time you'd want it.

# Domain note format

```markdown
---
name: <slug-case>
description: <one-line — what this domain covers>
domain: <broader-area, e.g. smart-actions, contacts, csv-import>
last_verified: YYYY-MM-DD
repos: [luxp, crm-monorepo] # repos this note touches
---

# <Title>

## What it is

<1–3 sentences in plain language.>

## Key files

- `repos/<name>/path/to/file.ts:42` — <one-line role>
- `repos/<name>/path/to/other.ts` — <one-line role>

## Flow

<2–6 bullets walking the request through the system. Imperative voice.>

## Why it's structured this way

<Optional. Keep tight — 2–4 sentences max.>

## Gotchas

- <One bullet = one fact, one sentence (two at most). Neutral statement of fact, no recommendations or value judgments — see `skills/wiki/SKILL.md` § Conventions.>

## Related

- Notion: <URL>
- Linear: <project / epic ID>
- Slack: <#channel>
- Adjacent domain: `wiki/domains/<slug>.md`
```

Every `repos/<name>/path:line` ref is grep-verified at write time and on every load.

# Related

- `navigator` agent (Claude Code wrapper at `.claude/agents/navigator.md`) — operational front door in CC; delegates into this skill.
- `data` skill / `data-analyst` agent — handoff target for data questions.
- `builder` skill / agent — handoff target for execution.
- `auggie` skill — fallback per repo Auggie policy; its `anatomy` subcommand mirrors the same refresh idiom for the `luxp` repo.
