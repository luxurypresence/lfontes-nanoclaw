# Ticket templates

Three ticket-body skeletons for common Clanq-board work types. Use the heading set as-is; trim sections that don't apply.

## Project plan

For multi-session work with sub-tasks or cross-dependencies. The description is the plan; sub-tasks linked per backend (sub-issues in Linear); comments for progress.

```markdown
## Goal

<1–2 sentences — what done looks like.>

## Plan

1. <Step.>
2. <Step.>

## Sub-tasks

<Bulleted list of child tickets — one per sub-task with link. Empty until needed.>

## Open questions

<Bullets. Resolved questions move to Decisions.>

## Decisions

<Date-stamped log: "2026-05-07: chose X over Y because Z.">

## Links

- Thread: <chat URL or thread ID>
- Adjacent: <other Linear / Notion links>
```

## Investigation

For research that produced a finding worth keeping.

```markdown
## Question

<What we set out to find.>

## Finding

<2–4 sentences — the answer.>

## Evidence

- <`repos/<name>/path:line` or other citation>

## Follow-ups

- <Bullets if the investigation surfaced new tickets.>

## Links

- Thread: <chat URL or thread ID>
- Sources: <Notion / Slack / Linear cross-refs>
```

## Routine output

For scheduled routine runs. One ticket per run, closed at the end.

```markdown
## Routine

`<routine name>` — see `$LFONTES_MONO_ROOT/skills/linear/references/routines/<name>.md`.

## Date

<YYYY-MM-DD>

## Output

<Markdown summary the routine produced.>

## Actions taken

- <Bullets — what was done as a result, if anything.>
```
