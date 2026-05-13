# Access paths

Routing logic: where each kind of question gets answered. Pick the cheapest path that yields evidence.

## Decision tree

```
Question type                    → Path
─────────────────────────────────  ──────────────────────────────────────────────
"Where does <code logic> live?"   → local clones (rg/fd/Read) · research subagent
"How does <feature> work?"        → local clones + product docs (Notion)
"Why was <X> built?"              → Linear ticket history + git log/blame
"What did people decide about Y?" → Slack search + Notion design docs
"How many / which records?"       → STOP. Hand off to `data` / `data-analyst`.
"What does external lib X do?"    → external library docs source (preferred) or web fetch
"Where is this discussed today?"  → Slack search
"Is this still relevant?"         → git log <main>..HEAD on the file + Linear status
```

## Source-of-truth ladder

When evidence conflicts, prefer higher-numbered tiers.

1. Live code in `repos/<name>` (after `git fetch`). Highest authority for "what is".
2. Tests in the same repo — confirm behavior, not just structure.
3. Notion design docs / PRDs — capture intent at a point in time. May be stale.
4. Linear tickets — describe what was supposed to happen and when.
5. Slack discussion — captures decision-making and tribal context. Often disagrees with code; trust code first.
6. Auggie — escape hatch only. Use when 1–5 don't cleanly answer.

## Tool routing per source

### Local clones (`repos/<name>`)

| Tool                                 | Use for                                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| Research subagent (parallel breadth) | Parallel breadth across many files in one repo. "Where is X used?" "Map all callers of Y." |
| `rg` / `fd` (shell)                  | Targeted searches when you know the pattern. Faster than a subagent for narrow lookups.    |
| Read                                 | Pulling specific files/lines once located.                                                 |
| `git log --oneline --stat <path>`    | History of a file or directory.                                                            |
| `git log --all -S "<string>"`        | Find commits that introduced or removed a string.                                          |
| `git blame -L <start>,<end> <file>`  | Who/when added a specific block — feeds Linear lookup.                                     |
| `gh pr list --search "<query>"`      | Find related PRs by title/description.                                                     |
| `gh pr view <num>`                   | Pull PR description, comments, reviewers.                                                  |

### Notion

- Search for: PRDs, design docs, runbooks, ADRs, "[Domain] Engineering" pages.
- Useful when: a feature has product context not encoded in code (intent, scope, sequencing).
- Cite Notion findings by URL.

### Linear

- Search by team prefix or by free-text. CRM Group prefixes: ACTS, GCRM, MAPS, etc.
- Useful when: tracing why a feature was built, scope of an epic, status of related work.
- Cite by issue ID + URL.

### Slack

- Search by channel: `#crm-group`, `#smart-actions`, `#contacts`, `#maps`, `#engineering`, etc.
- Useful when: looking for the decision behind a piece of code that lacks docs.
- Cite by channel + timestamp.

### External library docs

- For non-LP dependencies (frameworks, SDKs).
- Use this source before generic web search for dependency questions.

### `data` skill / `data-analyst` agent (handoff)

- The moment a question becomes "how many", "which rows", "what's the count" — stop, surface the question, and recommend the `data` skill or hand off to the `data-analyst` agent.
- Navigator can read SQL files in `repos/analytics-dbt/models/**` to understand metric definitions, but never executes SQL.

### Auggie — fallback only

Posture (when to use, when not, confirm-first, cite-format) lives in repo CLAUDE.md § "Auggie usage policy". Navigator-specific fit: cross-repo question that would take many `gh search` calls to answer, or a tribal-knowledge sanity check.

## Auto-refresh expectations

Before answering, the agent fetches the repos that the topic touches (debounced 10 min via `last-check.json`). When loading a `domains/<slug>.md`, the same refresh runs against the repos in the note's frontmatter. See `SKILL.md` § "Auto-refresh on domain load".

## Scope guard

Never read or write outside `<lfontes-mono-root>` (the directory whose `.git/` is your `git rev-parse --git-common-dir`'s parent). If a path-resolution feels like it's pointing outside that tree, stop and surface it.
