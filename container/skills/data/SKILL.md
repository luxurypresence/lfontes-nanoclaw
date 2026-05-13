---
name: data
description: Use this skill PROACTIVELY for any data question against LP production — SQL queries against `lp_core_production`, table/column lookups for LP's `core` / `identity` / `buyerseller` / `ops` / `website` / `property` schemas, or DBT mart knowledge from the `analytics-dbt` repo. Even if the user just says "check the database" or "look that up", use this skill. Trigger phrases: "how many contacts/tasks/companies", "find affected rows", "query LP", "production DB", "smart actions SQL", "DBT mart", "analytics-dbt", "Snowflake LAKE_LUXURY".
---

# Role

Read-only data agent for LP production. Routes a question to the fastest backend, runs the query, reports back.

# Context

| File                             | When to read                                                                                                                                                                                                            |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `references/access-paths.md`     | Picking a backend (lp-psql / Snowflake / Hex / Auggie). Has `lp-psql` flags and env overrides.                                                                                                                          |
| `wiki/data/core-schemas.md`      | Tables, columns, JSONB shapes, enum quirks, join rules per schema.                                                                                                                                                      |
| `wiki/data/queries/`             | Canonical, runnable `.sql` files for recurring operational lookups (smart actions count, entitlements, websites by status, etc.). Bind via `lp-psql -v name=value -f`. See `wiki/data/queries/README.md` for the index. |
| `wiki/data/query-patterns.md`    | SQL **shapes** that need adapting per use — affected-rows, JSONB discovery, latest-row, event-store two-step, cross-table matrix.                                                                                       |
| `wiki/data/gotchas.md`           | Deprecated tables, broken columns, enum casts. Skim once per session.                                                                                                                                                   |
| `wiki/data/analytics-anatomy.md` | `analytics-dbt` repo map — marts, macros, sources, `.claude` assets.                                                                                                                                                    |
| `wiki/last-check.json`           | Source-repo state for derived wiki artifacts. Read `repos.analytics-dbt` for the SHA `wiki/data/analytics-anatomy.md` reflects.                                                                                         |

Pull only what the current question needs.

# Rules

1. Read only. No DDL/DML.
2. `lp-psql` runs against `lp_core_production` (Metabase DB 4).
3. Cap exploratory queries with `LIMIT`. `EXPLAIN (VERBOSE, ANALYZE FALSE)` first for anything likely to scan > 10M rows.
4. Show filters alongside every result; flag what's not filtered (soft deletes, demo accounts, expired entitlements) when the omission could change the number materially. One-line "Filters: …" footer, not a SQL dump.
5. Flag worth-keeping findings inline with 🔖 — the `wiki` skill sweeps and writes at end of session.

Schema-level rules (joins, soft deletes, JSONB avoidance, deprecated tables) live in `wiki/data/core-schemas.md` and `wiki/data/gotchas.md` — read those when touching specific tables.

# Script — `lp-psql`

`scripts/lp-psql` — thin `psql` wrapper against the production read replica, keychain-cached. Examples:

```bash
# inline query
scripts/lp-psql -A -F $'\t' -c "SELECT COUNT(*) FROM core.task WHERE type='AI_SUGGESTED';"

# query from a file
scripts/lp-psql -f /tmp/query.sql
```

Variable injection (`-v key="'value'"`) and CSV export (`COPY … TO STDOUT WITH (FORMAT CSV, HEADER)`) work as in plain `psql`. Flag cheatsheet and first-run bootstrap: `references/access-paths.md`. If `lp-psql` is down or the question needs a different backend, consult `access-paths.md`.

# Auto-refresh on access

External sources go stale; refresh fires automatically when the skill is loaded for real work and `wiki/last-check.json` shows the source as out of date. Each step is independent — run only the ones whose timestamp is older than the threshold.

| Source                                                   | Threshold | Action                                                                                                                                                                                                                                                                                        |
| -------------------------------------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `analytics-dbt` SHA → `wiki/data/analytics-anatomy.md`   | 14 days   | `cd repos/analytics-dbt && git fetch --quiet && git log -1 --format=%H origin/main`. If SHA differs from `wiki/last-check.json § repos.analytics-dbt.last_sha`, diff `models/`, `macros/`, `.claude/`, top-level docs; update `wiki/data/analytics-anatomy.md` and the SHA.                   |
| Postgres schema spot-check → `wiki/data/core-schemas.md` | 14 days   | Diff covered schemas (`core`, `identity`, `buyerseller`, `website`, `property`, `ops`) against `repos/analytics-dbt/.claude/postgres-exploration/POSTGRES_RDS_*.md`. Add tables that matter; flag deprecations. Leave column detail as a pointer.                                             |
| Auggie gotcha probe → `wiki/data/gotchas.md`             | 30 days   | Per repo Auggie policy, ask: _"What new or updated data gotchas should I know when querying `lp_core_production` for CRM / smart-actions / saved-search / contact-import work? I have an existing list; flag only NEW ones, with source citations."_ Append new items with date and convo ID. |

Surface the diff and ask before overwriting reference content. Update `wiki/last-check.json § repos.analytics-dbt` after each run.

# Working loop

1. Pick a backend per `references/access-paths.md`. If a canonical query in `wiki/data/queries/` answers the question as-is, run it via `lp-psql -f`. Otherwise adapt a shape from `wiki/data/query-patterns.md`.
2. Run it (default backend per `# Script` above). `EXPLAIN` first if selectivity is unclear.
3. Sanity-check surprising results against a different predicate before reporting.
4. Report per the output format below.

# Output format

| Question shape                              | Format                                          |
| ------------------------------------------- | ----------------------------------------------- |
| Single number / small aggregate (≤ 3 cells) | Inline text                                     |
| Small set (≤ 20 rows)                       | Markdown table                                  |
| Medium set (21–500 rows)                    | Markdown table (first 20) + footnote; offer CSV |
| Large set (> 500 rows)                      | CSV in `./exports/<slug>-<date>.csv`            |
| Reusable / shareable                        | Hex project (via the `hex` skill)               |
| Anything the user will share                | SQL + result                                    |

Always include the SQL, backend used, database + schema (`lp_core_production` / DB 4 when applicable), and total row count alongside the result.

# When to stop and ask

- Any dimension of the question is genuinely ambiguous → ask.
- Natural query would scan > 10M rows → show the plan, ask before executing.
- Result is surprising (0 rows when expecting thousands, or 10× what you expected) → sanity-check against a different predicate before reporting.

# Escalation

Auggie — when Postgres alone can't answer (LP domain knowledge, cross-service state, session/active-user counts via Datadog RUM). Posture per repo Auggie policy.

# Related

- `data-analyst` agent (Claude Code wrapper at `.claude/agents/data-analyst.md`) — operational front door in CC; delegates into this skill.
- `auggie` skill — fallback per repo Auggie policy; sibling using the same refresh idiom for the `luxp` repo (its `anatomy` subcommand).
