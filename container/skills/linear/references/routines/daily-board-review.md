# Daily team-board review

Scheduled procedure. Surveys the user's team board and reports stale work. Read-only — no auto-close, comment, or reassign.

## Inputs

- Team key — `$LINEAR_REVIEW_TEAM` (e.g. `ENG`). Required.
- Stale threshold — `$LINEAR_STALE_DAYS`, defaults to 14.
- Output target — `$LINEAR_REVIEW_OUTPUT`. One of: `chat` (default; reply in the triggering thread), `clq-ticket` (open a routine-output ticket on `CLQ`).

## Steps

1. List open issues on `$LINEAR_REVIEW_TEAM` with no activity for > `$LINEAR_STALE_DAYS` days. Group by assignee.
2. For each, capture: ID, title, assignee, status, days idle, last comment author and date.
3. Render the markdown summary below.
4. Deliver per `$LINEAR_REVIEW_OUTPUT`.

## Output

```markdown
## Daily Board Review — <YYYY-MM-DD>

Team: `<team>` · Threshold: <N> days · Stale issues: <N>

### <Assignee>

| ID       | Title | Status      | Days idle | Last comment      |
| -------- | ----- | ----------- | --------- | ----------------- |
| ENG-1234 | …     | In Progress | 21        | luis (2026-04-16) |
```

If zero stale, output one line: `Board is healthy — no issues idle > <threshold> days.`

## Hand-offs

- Issue idle > 30 days — flag for user decision (close, reassign, or extend).
- Assignee has more than 5 stale issues — flag separately as a load signal.

## Scheduling

Drive via `/schedule`:

```
/schedule weekday 09:00 "follow $LFONTES_MONO_ROOT/skills/linear/references/routines/daily-board-review.md"
```

Set `$LINEAR_REVIEW_TEAM` (and optional overrides) in the agent group's environment before the first run.
