---
name: builder
description: Use when implementing a feature, fixing a bug, refactoring, writing a test, building a component, wiring something up, or developing a prototype in this monorepo or in LP repos via `repos/`. Stops at working-tree edits by default — commit, push, and PR only when the brief asks for them ("commit and push", "open a PR", "ship this change").
---

# Role

The coding skill. Auto-loads on any implementation task, in this monorepo or an LP repo via `repos/`. Loads in any harness that supports SKILL.md — paths and tools below are skill-relative; the harness binds them.

# Context

| File / source                                                     | When to read                                                                                                                                             |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The target repo's `CLAUDE.md` + `AGENTS.md` (always, first thing) | Repo conventions: branch names, dev commands, PR rules, changeset format, CI gates. Single source of truth per repo — don't duplicate that content here. |
| `references/react-development/index.md`                           | Working on React components in this monorepo: shadcn/ui, oklch tokens, Tailwind v4, lucide icons, `cn()` utility, TanStack Query patterns.               |
| `references/tanstack-start/index.md`                              | Working on TanStack Start routes / server functions / SSR / loaders / Cloudflare Workers in this monorepo.                                               |
| `references/graphql-schema/index.md`                              | Working with LP GraphQL queries / mutations / types — current or legacy API.                                                                             |
| `scripts/validate.sh`                                             | Pre-PR validation: lint, format, typecheck, test, build. Auto-detects pnpm/npm/yarn, monorepo, changesets.                                               |
| `last-check.json`                                                 | Tracks luxp SHA for `validate.sh` drift detection.                                                                                                       |

Pull only what the task needs. Read the target repo's CLAUDE.md first, before anything else.

# Rules

1. Repo CLAUDE.md is canonical. Branch names, commit conventions, PR template, changeset format, CI gates, repo-specific format specs — all live in the target repo's `CLAUDE.md` / `AGENTS.md` (or per-package CLAUDE.md). Read them first; defer to them on conflict.
2. Validate before opening a PR. `scripts/validate.sh` (or the repo's native equivalent — e.g. `pnpm test && pnpm lint && pnpm typecheck`). Don't open PRs with red gates.
3. Code review gate before opening the PR. One TypeScript code-review pass (we're a TS/Node/React shop). Add a security audit pass when the change touches auth / data / external IO. In Claude Code, the harness binds these to `kieran-typescript-reviewer` and `security-sentinel` from the Compound Engineering plugin. No fan-out, no severity scoring — fix what's blocking; defer the rest with notes in the PR description's `## Deferred`.
4. Browser visual pass for frontend. Any change touching `**/*.tsx`, `**/*.vue`, or known frontend dirs gets a browser-automation walkthrough with before/after screenshots and console-error capture. Skip for backend-only or test-only changes.
5. Strict in-tree scope; no destructive git. Read/write paths under `<lfontes-mono-root>` (computed via `git rev-parse --git-common-dir | xargs dirname`); LP repos at `<root>/repos/<name>/`. Never `reset --hard` / `push --force` / `branch -D` / `clean -fd` / `--no-verify` / `--no-gpg-sign` without explicit user confirmation.
6. Co-author trailer on every commit:
   ```
   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
   ```
7. Stop at edits by default. Ending state is working-tree edits + summary + validation result, ready for the user to review locally. Each shared-state action is its own per-step gate: the brief must explicitly include `commit`, `push`, or `open PR` for those steps to fire — `commit` does not imply `push`, `push` does not imply `open PR`. A general "let's go" / "do it" / "implement this" authorizes the implementation loop and stops there.
8. Flag worth-keeping findings inline with 🔖 — the `wiki` skill sweeps and writes at end of session. Use for recurring patterns or repo-specific gotchas surfaced during a build, not for code that just landed in the PR.

# Auto-refresh — `validate.sh` drift check

Once per session, if `last-check.json § validate_sh.checked_at` is > 7 days ago, `git -C repos/luxp log -1 --format=%H -- apps/a2a-runner/.claude/skills/validating-changes/scripts/`. If the SHA differs from `validate_sh.sha`, surface notable diffs and ask before re-copying. Update `validate_sh.sha` + `validate_sh.checked_at` when re-copy succeeds.

Don't auto-pull silently. The user should know when local validation logic changes.

# Setup

## Repo clones

LP repos at `<lfontes-mono-root>/repos/<name>/` — gitignored, single canonical location, shared across worktrees:

```bash
gh repo clone luxurypresence/<name> "$(git rev-parse --git-common-dir | xargs dirname)/repos/<name>"
```

Required for builder: `luxp`, `crm-monorepo`, `dashboard`. Pull the rest only when needed.

## Validation

Validation runs from the target repo, which means the skill's `scripts/validate.sh` needs an absolute path. Resolve once at session start and reuse:

```bash
# Absolute path to the skill's validate.sh — resolve once, reuse
VALIDATE="<absolute path to this skill>/scripts/validate.sh"

cd <target-repo>
"$VALIDATE"          # full validation
"$VALIDATE" --fix    # auto-fix lint
```

The harness exposes the skill mount path under whatever variable / convention it uses (in Claude Code that's `<lfontes-mono-root>/.claude/skills/builder/`).

For a `packages/<name>` prototype in this monorepo, run from the monorepo root — the script's smart-package detection picks up only the changed package.

## Sub-skill upstream sync

`pnpm exec tsx scripts/update.ts --check` (run from the skill directory) to see what's behind; `--update` to pull latest and save new SHA pins in `upstream.json`. Tracks `skill-creator`, `evals-skills`, and the framework reference docs.

# Working loop

1. Frame — restate the task; identify the target repo (`repos/<name>/` for LP, `packages/<name>/` for prototypes, or this monorepo root). Sanity-check it's in scope.
2. Pre-flight — `cd` to target; `git status` (abort if uncommitted state is unfamiliar — ask); `git fetch && git checkout <main-branch>` per the repo's CLAUDE.md (`master` for luxp, `main` elsewhere typically); read repo `CLAUDE.md` + `AGENTS.md`; for frontend, read the relevant `references/<name>/index.md`.
3. (Conditional) hand off — `navigator` for unfamiliar code; `data-analyst` for data evidence. Resume here with the result, ready to cite in the PR.
4. Branch + implement — `<prefix>-<slug>` off main (Linear ticket prefix when given). Small reversible edits; reuse existing patterns. Edits stay in the working tree; don't commit unless the brief authorizes it.
5. Validate → browser pass → review gate — run validation; do the browser walk-through for frontend changes (before/after screenshots, console errors); run the code-review gate per Rule 3. Fix what's blocking; defer the rest with notes.
6. Surface for review — print: branch (if created), files touched, validation outcomes, code-review gate summary. Stop here per Rule 7; the user reviews the diff locally and gives the next instruction.
7. (Conditional) Commit — only if the brief says "commit": stage the relevant files, write the commit per `# Format spec § Commit message shape`, include the co-author trailer (Rule 6). Don't push or open a PR as part of this step.
8. (Conditional) Push — only if the brief says "push" (and the work is committed). Push the branch to origin. Don't open a PR as part of this step.
9. (Conditional) Open PR — only if the brief says "open a PR" / "ship this change". Requires committed + pushed state. `gh pr create` per `# Format spec § PR description shape` (HEREDOC body); cite navigator/data context inline; report the URL.

# Output format

Default ending state per Rule 7 — no commit, push, or PR unless the brief authorizes it.

| Question shape              | Response                                                                                                         |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| "Implement X" / "Fix bug Y" | Branch (if created) + working-tree diff summary (files touched, key changes) + validation + code-review summary. |
| "Refactor Z"                | Same shape; emphasize "no behavior change" + tests in the summary.                                               |
| "Set up a new prototype"    | New `packages/<name>/` directory with scaffolding; report layout + dev command.                                  |
| "Just run validation"       | Validation output + green/red verdict.                                                                           |

When the brief explicitly authorizes additional steps, append:

| Escalation phrase in brief       | Additional response content                                                             |
| -------------------------------- | --------------------------------------------------------------------------------------- |
| "commit"                         | Commit SHA + commit-message confirmation + co-author-trailer confirmation. Stops there. |
| "push"                           | Push result + remote branch URL. Stops there.                                           |
| "open a PR" / "ship this change" | Implies commit + push if not yet done. PR URL.                                          |

Always include branch + base, validation outcomes, code-review gate summary (reviewer used + blocking-vs-deferred), and links to navigator/data context if cited. Commit / push / PR fields are conditional on explicit authorization (Rule 7).

# When to stop and ask

- Task spans multiple repos at once → ask which order or whether to split.
- Repo has uncommitted changes on the current branch → stop, show `git status`, ask.
- A dependency is being downgraded, removed, or its license changed → stop, confirm.
- Acceptance criteria are ambiguous → ask one focused question, then proceed.
- Brief authorizes "open a PR" but doing so would fail CODEOWNERS or queue rules in an obvious way → stop, explain, ask.
- PR review comments need a response → stop and ask. Responding to PR comments isn't wired into this skill.

# Escalation

- `navigator` skill — unfamiliar code; resume with the domain note.
- `data` skill — data question surfaces (counts, affected rows, validate the bug); resume with the result.
- Code-review pass — pre-PR review gate (TypeScript + optional security audit; see Rule 3).
- `auggie` skill — last-resort escape hatch for LP tribal knowledge not findable in repo + Notion + Linear + Slack. Posture per repo Auggie policy.

# Format spec

## PR description shape

```markdown
## Summary

<1–3 bullets: what changed and why>

## Test plan

- [ ] <bulleted markdown checklist of testing steps>

<!-- if relevant -->

## Domain context

- <link to navigator domains/<slug>.md if cited>

## Data evidence

- <data-analyst query + result if relevant>

## Deferred

- <reviewer-flagged minor items not addressed in this PR>
```

Use a HEREDOC when calling `gh pr create --body`. The harness may append its own attribution trailer (e.g. "Generated with Claude Code"); leave that to the harness.

## Commit message shape

```
<type>(<scope>): <imperative summary, ≤72 chars>

<optional body — what + why, not how>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

`<type>` follows the target repo's convention (most LP repos use `feat`/`fix`/`refactor`/`chore`/`docs`).

Repo-specific format specs (changeset YAML, branch-prefix convention, PR template variants) live in the target repo's CLAUDE.md, not here. If `pnpm changeset` is interactive and blocks the agent, follow the repo's documented non-interactive convention.

# Related

- `builder` agent (Claude Code wrapper at `.claude/agents/builder.md`) — operational front door in CC; delegates into this skill.
- `data` skill / `data-analyst` agent — handoff target for data questions surfaced during a build.
- `navigator` skill / `navigator` agent — handoff target when the task lands in unfamiliar code.
- `ship` skill — sibling for shipping local changes in lfontes-mono (squash-merge or PR open). Builder can hand off to `ship` for the merge step in this repo.
- `auggie` skill — last-resort escape hatch (per repo Auggie policy). Read-only on `auggie-platform` internals; don't edit it from here.
