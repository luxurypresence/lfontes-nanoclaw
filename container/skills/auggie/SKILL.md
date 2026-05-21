---
name: auggie
description: Delegate codebase, data, and product questions to Auggie, LP's AI engineering assistant. Use as an escape hatch when local sources don't answer.
argument-hint: '[anatomy | anatomy refresh]'
---

# Role

Delegate research, data lookups, and codebase investigation to Auggie — LP's AI engineering assistant — via MCP. Submit task → poll → report.

# Context

| File                     | When to read                                                                                                                                                                                       |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wiki/auggie-anatomy.md` | What Auggie is and what it can do — connected MCP servers, agent personas, commands, skills, system prompt, design patterns. Skim for capability lookup; read in full for architectural questions. |
| `wiki/last-check.json`   | Source-repo state for derived wiki artifacts. Read `repos.luxp` for the SHA `wiki/auggie-anatomy.md` reflects.                                                                                     |

Pull only what the current task needs.

# Rules

1. Async only — every interaction is `ask_auggie` then poll `get_task_status` until `completed`.
2. Read-only against LP databases (Auggie's Metabase access is read-only).
3. One focused task per `ask_auggie` call. Split unrelated questions into separate calls.
4. Pass `conversationId` to preserve context for follow-ups; otherwise each task starts fresh.
5. No deployments, no destructive DB writes — Auggie won't ship code or trigger CI/CD.
6. Flag worth-keeping findings inline with 🔖 — the `wiki` skill sweeps and writes at end of session.

# MCP tools

Auggie is exposed via the `Auggie` MCP server.

- `ask_auggie(prompt, conversationId?)` → `{ taskId, conversationId, status }`. Save both IDs.
- `get_task_status(taskId)` → `{ status, result }`. Status is `pending`, `running`, or `completed`. Read `result` when `completed`.

# Working loop

1. Submit: `ask_auggie(prompt)`. Save `taskId` + `conversationId`.
2. Poll: wait 15-30s, call `get_task_status(taskId)`. Repeat until `completed`. Most tasks finish in 1-3 minutes; complex research can take longer.
3. Follow up (optional): `ask_auggie(prompt, conversationId)` to keep context.

# Prompt crafting

Use specific identifiers (repo names like `luxurypresence/platform-api`, table names like `core.contact`, flag keys, ticket IDs). Specify the format ("markdown table", "top 5", "2-3 sentences"). Reference systems explicitly ("Query Metabase for…", "Search Slack for…", "Check LaunchDarkly for…"). One task per call.

Vague prompts ("tell me about the platform") produce shallow answers. Combined unrelated tasks reduce focus — split them.

# Auto-refresh on access

External sources go stale; refresh fires automatically when the skill is loaded for real work and `wiki/last-check.json § repos.luxp` shows the source as out of date.

| Source                                | Threshold | Action                                                                                                                                                                                      |
| ------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `luxp` SHA → `wiki/auggie-anatomy.md` | 14 days   | `cd repos/luxp && git fetch --quiet && git log -1 --format=%H origin/master`. If SHA differs from `wiki/last-check.json § repos.luxp.last_sha`, run the `anatomy refresh` subcommand below. |

Surface the diff and ask before overwriting reference content. Update `wiki/last-check.json § repos.luxp` after each run.

# Output format

Pass through Auggie's response with attribution:

```
> via Auggie (taskId: <id>, conversationId: <id>)

<Auggie's response>
```

If the response is a wall of text and the user asked a focused question, summarize the answer up top and link to the rest.

# When to stop and ask

- Prompt is ambiguous about which repo / system / time horizon → clarify before submitting.
- Auggie returns a surprising result that contradicts a known wiki fact → flag the conflict, don't blindly forward.
- A task has been polling > 5 minutes without completion → tell the user; ask whether to keep waiting.

# Subcommands

## `anatomy` — show the Auggie anatomy summary

Read `wiki/last-check.json § repos.luxp` and `wiki/auggie-anatomy.md`. Print a concise summary: section count, agent / command / MCP-server counts, last-check date, commit SHA. Offer to expand any specific section in detail.

## `anatomy refresh` — update `wiki/auggie-anatomy.md`

1. Read stored commit from `wiki/last-check.json § repos.luxp.last_sha`. Get current `repos/luxp` HEAD via `git rev-parse HEAD`. If equal, report "already up to date" and stop.
2. `git diff --name-only <old>..<new>` in `repos/luxp`. Filter to relevant paths:
   - `.claude/` — skills, rules, settings, plugins
   - `packages/luxp-auggie/src/assets/` — system prompt, agents, commands, governance docs
   - `apps/a2a-runner/.claude/` — runner-specific config
   - `apps/a2a-runner/src/modules/mcp/servers/` — custom MCP servers
   - `apps/a2a-runner/src/modules/claude-session/` — session / prompt management
   - `apps/a2a-runner/src/modules/claude-sdk/` — SDK integration
   - `.claude-plugin/marketplace.json` — plugin bundles
   - Root `CLAUDE.md`
3. If no relevant files changed, report and stop.
4. Run parallel research subagents on changed areas. Look for new / removed / modified agents, commands, skills, MCP servers; governance / system-prompt edits; new plugin bundles or rule files; structural changes.
5. Edit `wiki/auggie-anatomy.md` with findings — add new entries, drop deleted ones, update descriptions; keep section structure; refresh counts; update Metadata block at the bottom.
6. Write `wiki/last-check.json § repos.luxp` with `{ last_sha, last_check, summary }`.
7. Surface the diff for review before saving anything substantial.

# Related

- `data` skill — sibling using the same auto-refresh idiom; preferred for direct LP DB queries.
- `navigator` skill — preferred for LP code research with local clones; Auggie is the escalation when local sources don't yield enough signal.
- `builder` skill — preferred for code execution / PRs; Auggie is read-only on LP repos.
