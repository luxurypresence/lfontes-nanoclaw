# LP Data Access Paths

Four ways to query LP production data, ranked by preference. Start at the top; drop down only if the upper path is unavailable for the question.

## Path 1 — `lp-psql` against the production read replica (primary)

Direct `psql` into LP's production read replica. This is the default path — use it for almost everything.

Script: `scripts/lp-psql`.

```bash
scripts/lp-psql -c "SELECT 1;"
```

Wraps `psql` with the right host/user/db, pulls the full connection (host, port, database, username, password) on demand from a 1Password item via the `op` CLI. Default vault `LP op-cli`, default item `LP Production`. Sign in with `op signin` (or set `OP_SERVICE_ACCOUNT_TOKEN`) before first use. Same pattern as the Snowflake CLI setup.

### Switching databases

Each 1P item carries a complete connection profile; the script reads `host` / `port` / `database` / `username` / `password` from the item. Per-field env overrides (`LP_PSQL_HOST`, `LP_PSQL_PORT`, `LP_PSQL_USER`, `LP_PSQL_DB`) win over the item's values when set. Override the item lookup via `LP_PSQL_OP_VAULT`, `LP_PSQL_OP_ITEM`, `LP_PSQL_OP_FIELD`.

### Known 1P items (vault `LP op-cli`)

| Item name                   | DB                                                | When to use                                                                                                                                                                                                                                                                         |
| --------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LP Production` (default)   | `lp_core_production` on main-cluster-2 RO replica | Everything in `core` / `identity` / `buyerseller` / `website` / `property` / `ops` / `ai_augmentation`. The default — no override needed.                                                                                                                                           |
| `LP Event Store Production` | `event_store`                                     | Querying CloudEvents-style event store events. The federated GraphQL `eventStoreEvents` query reads from this DB. Use when looking up events by `subject` (typically a contact / membership / canonical UUID). Invoke as `LP_PSQL_OP_ITEM="LP Event Store Production" lp-psql ...`. |

### Common invocations

```bash
# One-shot SQL, pipe-friendly TSV output
scripts/lp-psql -A -F $'\t' -c "SELECT COUNT(*) FROM core.task WHERE type = 'AI_SUGGESTED';"

# Run a SQL file
scripts/lp-psql -f /tmp/query.sql

# Bind a psql variable (quote yourself when substituting strings)
scripts/lp-psql -v company_uuid="'9553e0a1-...'" -f query.sql

# Silent + unaligned + no row count (great for scripting)
scripts/lp-psql -qAtc "SELECT id, type FROM core.task LIMIT 5;"

# EXPLAIN to sanity-check a heavy query before running it
scripts/lp-psql -c "EXPLAIN (VERBOSE, ANALYZE FALSE) SELECT ..."

# CSV export (streams to stdout; gitignored ./exports/)
scripts/lp-psql -c "COPY (<SQL>) TO STDOUT WITH (FORMAT CSV, HEADER)" \
  > exports/<slug>-$(date +%F).csv
```

### Useful psql flags

- `-A` — unaligned output (pipe-friendly)
- `-t` — tuples only (no headers/footer)
- `-q` — quiet (suppress banner)
- `-F $'\t'` — TSV field separator
- `-c "SQL"` — single command, exit after
- `-f path.sql` — run from file
- `-v var=value` — bind variable (`:'var'` for quoted substitution)
- `-o path.out` — write results to file

Read-only role — writes raise a permissions error.

## Path 2 — Snowflake via `snow` CLI (analytics / long-horizon queries)

Snowflake CLI (`snow`), connection name `lp`, config at `~/.config/snowflake/config.toml`. Set as default — no `-c` flag needed.

Auth uses `username_password_mfa` + 1Password TOTP. The password is in `$SNOWFLAKE_PASSWORD` (set in `~/.config/zsh/secrets.zsh`). TOTP is pulled on demand from 1Password via a service account scoped to the `LP op-cli` vault — `$OP_SERVICE_ACCOUNT_TOKEN` lives in the same secrets file.

Use the `snowq` shell function (defined in `~/projects/dotfiles/zsh/.zshrc`):

```bash
snowq -q "SELECT COUNT(*) FROM LAKE_LUXURY.POSTGRES_RDS_CORE.TASK;"
snowq -f /tmp/query.sql
snowq --format=json -q "SELECT ..."
```

`snowq` expands to `snow sql --mfa-passcode "$(op item get 'Snowflake' --vault 'LP op-cli' --otp)" "$@"`. No passcode typing, no browser, no user interaction needed.

Longer-term: get LP Snowflake admin to attach a network policy to the `LFONTES` user so PAT auth works (then swap config to `password = <PAT>`, drop the `authenticator` line, no more passcodes). Other auth modes are dead: `externalbrowser` opens Google SSO that isn't linked to this user; password-only via driver is blocked by Snowflake's 2025 MFA policy.

### When to use

- Long-horizon history (Snowflake keeps more than prod does)
- Heavy analytical joins across services
- DBT-transformed marts (see `analytics-anatomy.md`)
- Cross-service cohort / retention analysis

### Namespace

- `LAKE_LUXURY.POSTGRES_RDS_*` — raw mirrors of production Postgres via Fivetran
- `ANALYTICS.MART_*` — DBT-transformed marts (sales, finance, client marketing, product, metrics, …)
- `ANALYTICS.DW.*` — dimensional warehouse (e.g. `DW_PLATFORM_COMPANIES` bridges `LP_COMPANY_ID` ↔ `SF_ACCOUNT_ID`; `DW_CUSTOMERS` has `TIER_PLAN`)

### Freshness

Fivetran lag is typically 1–6 hours. DBT marts depend on the dbt Cloud schedule (typically daily). Do not use for sub-minute-fresh data.

### Cost discipline

Browser-dance per query makes `snow` expensive in interaction time. Batch — put multi-step analysis into a `.sql` file and run with `-f` rather than firing a stream of `-q` calls.

### Footguns

- Don't run `snowq` calls in parallel. Both pull the same TOTP from 1Password within the same window; the second login fails as "TOTP Invalid", and a few of these in a row trips Snowflake's "Too many failed MFA login attempts" cooldown (~10+ min). Run sequentially, or batch into a single `.sql` file via `snowq -f`.
- Snowflake SQL ≠ Postgres for some idioms — common surprises when porting from `lp-psql`:
  - `COUNT(*) FILTER (WHERE …)` is unsupported. Use `SUM(CASE WHEN … THEN 1 ELSE 0 END)`.
  - `DATE_TRUNC('day', ts)::date` fails (`::date` cast). Drop the cast — `DATE_TRUNC` already returns a date for date-grain truncation.
  - Identifier quoting is case-sensitive when double-quoted; prefer unquoted UPPER for table/column refs.

## Path 3 — Hex (complex / shareable / multi-step analysis)

Interactive notebooks — SQL + Python + charts in one thread. Good when the answer needs iteration or someone else will look at the result.

Access via the `/hex` skill, which drives the `hex` CLI (project create, run, cell append, connection query, dashboard build). Auth: `hex auth login`.

### When to use

- Multi-step analysis that benefits from intermediate cells (explore → filter → pivot → visualize)
- Needs to be shareable with a stakeholder — URL embeds live
- Data-source is Snowflake and you want a chart alongside the SQL
- The question is "build me a mini-dashboard for X"

### When not to use

- One-off count — that's lp-psql
- Large unstructured dump — that's a CSV from lp-psql

Tool surface inside the skill: `hex` CLI commands for `projects`, `cells`, `connections`, `dashboards`. See the skill itself for the command cheatsheet.

## Path 4 — Auggie agent fallback

Delegate to the Auggie agent (LP's AI engineering assistant). Posture (when to use, confirm-first, cite-format) lives in repo CLAUDE.md § "Auggie usage policy".

### Capability fit for data work

- `lp-psql` unavailable (op CLI not signed in, VPN down) and the question can't wait.
- Question requires LP domain knowledge beyond SQL ("which team owns this table?", session/active-user counts via Datadog RUM).

### Prompt shape (SQL via Auggie)

```
Run this SQL against lp_core_production (db_id=4) and return results as a table:

<SQL>
```

### Bindings and caveats

- Always pass `db_id=4` — Auggie defaults to staging (DB 3) silently otherwise.
- Auggie can also reach Hex and Datadog RUM — delegating lets it pick the right tool for session-oriented or notebook-style questions.

## Path selection heuristics

| Question                                                     | Path                                                      |
| ------------------------------------------------------------ | --------------------------------------------------------- |
| "How many rows match X in the last N days?"                  | 1 (lp-psql)                                               |
| "Find the affected rows for this bug"                        | 1 (lp-psql)                                               |
| "Compute a cohort retention curve over 12 months"            | 2 (Snowflake) if available, else 1 with care              |
| "Build a shareable analysis with charts"                     | 3 (Hex)                                                   |
| "What does the existing mart `fct_smart_actions` look like?" | Read `analytics-anatomy.md`, then 2 (Snowflake) if needed |
| Session / active-user counts                                 | 4 (Auggie) — it can reach Datadog RUM                     |
| Anything else, and Path 1 is up                              | 1                                                         |
| Path 1 is down and the user needs an answer now              | 4 (Auggie)                                                |

## Metabase — not a path, a destination

Metabase is the LP-wide BI tool (`metabase.luxurycoders.com`). It points at the same DB (`db_id=4` = `lp_core_production`, `db_id=3` = staging). We don't route queries through its API — `lp-psql` is faster and we don't need the row cap (Metabase `execute_query` caps at 2000 rows; `export_dataset` bypasses). Use Metabase when the user explicitly wants a Metabase link for someone else to open.

## State snapshot (2026-04-23)

| Path                   | Ready? | Notes                                                                                                                                                                                                                   |
| ---------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 — lp-psql            | ✅     | Full connection profile pulled on demand from 1Password (`LP op-cli` vault); default item `LP Production`, switchable via `LP_PSQL_OP_ITEM` (e.g., `LP Event Store Production` for the event-store DB). Read-only role. |
| 2 — Snowflake (`snow`) | ✅     | CLI + `snowq` shell wrapper live. Auth = `username_password_mfa` with TOTP auto-pulled from 1Password (service account, vault `LP op-cli`). Zero user interaction per query. PAT admin ask still pending for cleanup.   |
| 3 — Hex                | ⚠️     | Skill installed; run `hex auth login` if CLI prompts.                                                                                                                                                                   |
| 4 — Auggie             | ✅     | Posture per repo Auggie policy.                                                                                                                                                                                         |

Keep this snapshot current — it's the single place agents check to know which paths are live.
