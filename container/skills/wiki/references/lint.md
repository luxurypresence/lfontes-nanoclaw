# Wiki lint workflow

Read-only checklist the `wiki` skill runs to surface drift between the wiki and reality. Reports findings; never edits. v1 covers five mechanical checks; conflict-detection across domains is deferred until the heuristic is worth more than its false-positive rate.

## Checks

Run each in order. Skip a check entirely (with a one-line note) if the underlying source is missing — e.g. `repos/` clones absent on this machine.

### 1. Broken cross-links

Find markdown links `[text](path)` in `wiki/**/*.md` whose target doesn't exist.

```bash
rg -n --no-heading -t md '\[[^]]+\]\(([^)]+)\)' wiki/ | \
  awk -F: '{print $1":"$2":"$0}'  # path:line:full-line
```

For each match, extract the link target (the `(...)` part). Resolve relative to the file's directory. If the path starts with `wiki/` or `skills/`, resolve from repo root. Skip URLs (`http://`, `https://`, `mailto:`).

Verify each target with `test -e`. Flag missing ones.

### 2. Stale path references

Scan `wiki/**/*.{md,sql}` for paths into the rest of the repo or local clones. Verify each file exists.

```bash
# repo / package / skill references
rg -n --no-heading -t md -t sql '(repos|packages|skills)/[a-zA-Z0-9._/-]+\.(md|ts|tsx|js|jsx|sql|json|yaml|yml|sh|graphql)' wiki/
```

For each hit, strip the optional `:LINE` suffix and `test -e` the path. Don't check the line number — files routinely shift, and false positives erode trust.

Filter out paths containing `...` — that's the wiki abbreviation convention for omitted middle segments (e.g. `repos/crm-monorepo/.../event-dedup.util.ts`); those aren't real paths.

Exception: paths under `repos/<name>/` are local clones. If `repos/<name>/` doesn't exist on this machine, skip every reference into that clone with one note: `⚠ skipped repos/<name>/ (clone not present)`. Re-running with the clone restored will pick them up.

### 3. Oversized files

Line count per `.md` under `wiki/`. Flag anything over 500 lines (matches the cap in `skills-manager/SKILL.md`).

```bash
fd -e md . wiki/ -x wc -l {} | awk '$1 > 500'
```

### 4. Log drift

Scan `wiki/log.md` for explicit wiki paths mentioned in capture summaries (`wrote N entries to wiki/...`, `✓ wrote ... wiki/...`, or any bare `wiki/<path>.md` / `.sql` reference). Verify each path still exists.

```bash
rg -n --no-heading 'wiki/[a-zA-Z0-9._/-]+\.(md|sql|json)' wiki/log.md
```

Flag log entries whose referenced files no longer exist — likely a stale log entry from a file later deleted or renamed without log cleanup.

### 5. Frontmatter

Every content file under `wiki/` (except `wiki/index.md` and `wiki/log.md`) carries the trio: `name`, `description`, `last_verified`. Verify each file has it and parses as valid YAML.

Also flag pages where `last_verified` is significantly older than the file's last git commit on the path — the content may have been edited without re-verification.

```bash
# files missing frontmatter or required keys
fd -e md . wiki/ --exclude index.md --exclude log.md
# (read each, check for ^---\n(name|description|last_verified): patterns)

# verification staleness
fd -e md . wiki/ --exclude index.md --exclude log.md -x sh -c '
  lv=$(rg -m1 "^last_verified:" "{}" | sed "s/.*: *//")
  gc=$(git log -1 --format=%cs -- "{}")
  [ -n "$lv" ] && [ "$gc" \> "$lv" ] && echo "{} — last_verified=$lv but last commit=$gc"
'
```

Flag missing-trio entries; flag verification staleness only when the gap is meaningful (e.g., > 30 days).

## Output format

Print an in-chat markdown report. One section per check; one bullet per finding; `None.` if a check passes.

```markdown
# /wiki lint report — YYYY-MM-DD

## Broken cross-links

- `wiki/<file>.md:<line>` → `<target>` (not found)

## Stale path references

- `wiki/<file>.md:<line>` → `<path>` (not found)

## Oversized files

- `wiki/<file>.md` — N lines (cap: 500)

## Log drift

- `wiki/log.md:<line>` → mentions `<path>` which no longer exists

## Frontmatter

- `wiki/<file>.md` — missing required keys: name, description
- `wiki/<file>.md` — last_verified=2026-03-01 but last git commit=2026-05-10 (verify and refresh)

## Summary

N findings total — A broken links, B stale paths, C oversized files, D log drift, E frontmatter. Skipped: <list any checks deferred>. Review and decide which to fix; lint never edits.
```

If a check produced zero findings, the section header still appears with `None.` so the user can see the check ran. If a check was skipped (e.g., repos clones absent), say so explicitly under that section.

## When to stop and ask

- A check needs a clarifying decision the protocol doesn't cover (e.g., a borderline 501-line file). Just flag it and move on — the user decides what to act on.
- Errors running `rg` / `fd` / `wc` — surface the error inline, don't suppress.
