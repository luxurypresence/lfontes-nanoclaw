# internals/

A personal scratchpad for understanding how NanoClaw works and planning a
from-scratch rewrite of my own, for kicks and learning.

Two kinds of content live here:

- **Numbered study docs** (`01-` through `05-`) — snapshots of how the *current*
  NanoClaw codebase works. Written as a tour to make future-me productive
  fast: "where does X happen, why is it like that, what would break if I
  changed it." Heavy on `file_path:line_number` citations.
- **`ideas/`** — forward-looking design notes for the rewrite. Each file
  captures one direction I'm considering, with enough context that I (or
  Claude) can pick it up cold later and either build it or argue against it.

This is not documentation for the project; it's a thinking notebook. Nothing
here is on the runtime path. The directory could be deleted and NanoClaw
would still work.

## Index

| # | File | What's in it |
|---|------|--------------|
| 01 | [01-architecture-from-docs.md](01-architecture-from-docs.md) | Synthesized from `docs/*.md` + README. Entity model, three-DB design, host/container split, channels-as-skills, OneCLI, isolation model, 10 invariants. |
| 02 | [02-host-code.md](02-host-code.md) | `src/` deep-dive: boot sequence, inbound/outbound paths, container lifecycle, sweep, session resolution, routing/triggers, permissions, approvals, `ncl` CLI, footguns. |
| 03 | [03-agent-runner.md](03-agent-runner.md) | `container/agent-runner/src/` deep-dive: poll loop, `on_wake`, formatter, providers, MCP tools, scheduling, destinations, DB pragmas, Bun gotchas. |
| 04 | [04-install-flow.md](04-install-flow.md) | Install trace: `bash nanoclaw.sh` → environment check → pnpm install → container build → OneCLI → DB migrations → launchd/systemd service → first-agent wiring. |
| 05 | [05-slack-flow.md](05-slack-flow.md) | End-to-end Slack message trace: webhook POST → Chat SDK bridge → router → session DB → container wake → poll loop → provider → outbound DB → delivery → Slack web API. |
| 06 | [06-sender-routing.md](06-sender-routing.md) | Study of the `/add-sender-routing` local-fork patch — the closest existing mechanism to the trust-zone model in `ideas/`. |
| — | [ideas/](ideas/) | Forward-looking design notes for the rewrite (foundational principles + investigations). |

## How to read these

If you want the mental model fast:
- Start with **01** (entities, DBs, single-writer rule).
- Then **02** (host wiring), then **03** (container side).
- **04** and **05** are concrete walkthroughs you can use to anchor what 01-03
  describe in the abstract.

If you're stripping NanoClaw down rather than rewriting:
- The "Key invariants" section of **01** is the contract you cannot break.
- "Footguns" at the end of **02** and "Bun-specific gotchas" in **03** are the
  bear traps.

If you're building from scratch:
- Read all five for the lay of the land, then read `ideas/` for what we'd
  actually do differently.

## When to update

- **Study docs (01-05):** re-run when upstream changes substantially. The
  file:line refs rot. They were accurate at the date stamped at the top of
  each file.
- **Ideas:** append-only thinking. If a direction gets rejected, leave the
  note with a "rejected because…" footer rather than deleting it — the
  reasoning is the value.
