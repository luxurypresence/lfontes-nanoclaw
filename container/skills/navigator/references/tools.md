# Tools — LP-specific routing

Generic tool choice (when to grep vs read vs spawn a research subagent vs run a command) is left to the harness. This file only documents the parts that are LP-specific: which source carries which kind of LP knowledge, and the posture rules around them.

## Sources and what each is for

| Source                                                                   | What lives there                                                                 | Cite as                |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------- | ---------------------- |
| Notion (via Notion MCP / API)                                            | PRDs, design docs, runbooks, ADRs, "[Domain] Engineering" pages, meeting notes   | Notion URL             |
| Linear (via Linear MCP / API)                                            | Ticket history, epic/project scope, "why was this built", status of related work | Issue ID + URL         |
| Slack (via Slack MCP / search)                                           | Past discussion of a feature, decisions, channel-specific context                | `#channel` + timestamp |
| External library docs (e.g. context7)                                    | Framework / SDK documentation                                                    | Library + section      |
| Auggie agent                                                             | LP tribal knowledge — sanity-check escape hatch only                             | Conversation ID        |
| `gh` CLI (`gh search code 'org:luxurypresence "<query>"'`, `gh pr view`) | Cross-repo searches, PR threads                                                  | PR URL                 |

## Auggie posture

Posture lives in repo CLAUDE.md § "Auggie usage policy". Auggie is a fallback for cross-repo questions that local search can't answer cleanly.

## What not to use for what

- Web fetch / web search — only for non-LP content (external docs, blog posts). Never for LP product knowledge.
- Hex — analytics queries. If it routes there, hand off to the `data` skill / `data-analyst` agent.
- Figma — design questions. Out of navigator's scope unless explicitly asked.
- Browser automation — live browser/QA work, not codebase research.

## Verification rule (capture-time)

Before any `repos/<name>/path:line` claim is written into a `domains/*.md`, grep-verify it against the current HEAD of the relevant repo. If grep returns 0 results, drop or fix the claim. The capture flow handles this automatically; if you write a domain note by hand, run the verification yourself.
