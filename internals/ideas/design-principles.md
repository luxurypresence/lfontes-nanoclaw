# Design principles

The canonical "what I'm building" doc. Everything else under `ideas/` refers
back to these. If a later note contradicts a principle here, either this doc
gets updated or the note gets rejected.

## What I'm building

A personal NanoClaw-inspired agent framework. Single VM (exe.dev, Cloud
Hypervisor, ~2 vCPU / 8 GB / 25 GB). Single tenant (me). Docker available.
Everything self-contained on one host. No external databases, no remote
services beyond the LLM API and channel webhooks.

Two interaction modes that drive the architecture:

- **DM channel** — full powers, read/write, broad toolset.
- **Public channel** — restricted, mostly read-only, smaller toolset.

The real trust boundary is **sender identity**, not channel surface. When I
type in a public channel, I want my own user recognized and granted
DM-level capabilities — not constrained because of the surface. This is the
single most important shift away from NanoClaw, which splits on agent-group
(and thereby usually on channel).

## Principles

### 1. Container = identity = trust zone

One container per trust zone, not per session, not per message, not per
agent group. For me, that's probably ~2 containers: **DM-trust** and
**public-trust**. Containers are long-lived; the host wakes idle ones
rather than cold-spawning per turn.

The router maps `(sender_id, channel) → trust_zone → container`. The
container *is* the trust zone — what powers exist inside it are what that
zone permits. There is no second layer of capability checks once you're
inside.

### 2. Capabilities are ambient inside the container

Credentials, tool binaries, mounts are fixed at **container provisioning
time**, not per-call, not per-skill. A `clone-repo` skill uses `gh` CLI;
the DM container ships a read/write PAT; the public container ships a
read-only PAT; the skill text is **identical** in both. The container
determines the powers; the skill describes the intent.

This is structurally simpler than IronClaw's per-skill WASM capability
model, and the simplicity is the point.

### 3. Router is the policy layer

One small, readable place where "who can do what" is decided. The router
maps inbound messages to trust zones, and that's the only access-control
decision. No per-tool authorization. No per-skill capability negotiation.
If you're in the container, you have what the container has.

Audit-friendly by design — every router decision is a single function
trace that can be logged and replayed.

### 4. RPC exposes intents, not queries

The host RPC API exposes verbs:
`record_message`, `claim_task`, `request_credential`, `emit_audit`,
`schedule_message`. Never `select_from_messages`, never
`update_session_state(sql=…)`. Policy lives in endpoint definitions, not
in per-call SQL filters.

This prevents the RPC layer from drifting into SQL-over-HTTP — which is
what most "let containers talk to the DB" designs end up as eventually.

### 5. Host owns durability; containers own ephemera

- **Host:** identity, permissions, channel↔container wiring, scheduled
  tasks, audit log, queue. Single SQLite file with Honker on top.
- **Container:** session/working state in its own local SQLite. Conversation
  history, scratch memory, in-flight tool state. If a container is torn
  down, none of this is user-meaningful loss.

Audit events bubble up from container to host via RPC at significant
moments. Bytes stay local; meaning is central.

### 6. Skills are instructions, not capability-bearing code

A skill is markdown plus optional helper scripts. It declares **intent**
("clone a repo using gh") and optionally **required tools** (`gh`). The
router uses the requirement list to refuse skills that can't run in the
resolved trust zone, but the skill itself carries no permission, no
secret, no code path that grants capability.

Same skill, two containers, different outcomes.

### 7. Minimal moving parts

One Node host. One SQLite file with Honker. A handful of Docker containers
on a host-only bridge. Unix-socket RPC. That's it. Nothing else gets
introduced unless it earns its place against this baseline.

### 8. Host owns visibility, not just durability

Refinement of principle 5. Containers run code; the host *shows* the
operator what the code did. Configuration lives in one declarative TOML
file on the host. A read-only dashboard surfaces zone status, recent
activity, audit log, queue state. The CLI mutates; the dashboard reads.

This is a small but deliberate step away from NanoClaw's
no-config-no-dashboard religion, which crosses into operator-hostile. The
ceiling is OpenClaw-style config-hell, which fails in the other direction.
See `host-surface.md` for the discipline rules that hold the line.

### 9. Bring your existing tooling

A user with an existing Claude Code workflow — skills, subagents, MCP
servers, CLAUDE.md memory — should be able to lift that configuration into
the VM in one command. The format proximity between Claude Code and Pi
(the v1 harness — see `harness-selection.md`) makes the importer a
translation pass, not a rewrite.

This is the load-bearing selling point. A blank-slate framework loses to
"keep using what you already configured, just in a VM." See
`migration-from-claude-code.md`.

### 10. Harness integration is always subprocess CLI

Every agent runtime (Pi, `claude -p`, future additions) is wrapped as a
subprocess. No in-process libraries, no SDK paths. One integration
pattern.

Wins: operational uniformity across harnesses, language independence
(Rust/Go/Python harnesses work), crash isolation (a bad harness doesn't
take down the runtime), eat-your-own-dogfood (same binary local and
remote), trivial harness-swap experiments. Cost: NDJSON parser per
harness, weaker debug surface than typed in-process events. Both are
bearable.

Mid-response push becomes a per-harness capability flag
(`supportsMidResponsePush`) rather than a guaranteed primitive — harnesses
that support stream-stdin get it, others get queueing semantics. See
`harness-selection.md`.

## What I'm explicitly not doing

| Rejected | Why |
|----------|-----|
| WASM-per-skill (IronClaw) | I write/audit all my own skills. Per-call human-in-the-loop on dangerous actions can be done with tool wrappers, not capability infrastructure. The per-skill WASM model is defense against malicious skill authors — not my threat model. |
| TEE | Overkill for personal use. Locks me into specific hardware/clouds. The VM already provides kernel-level isolation. |
| Postgres centrally | Single writer, single host. Multi-tenant/multi-writer features wasted. Reconsider only if I want Honcho (pgvector-backed continual memory). |
| Per-session containers | Wasteful. Doesn't buy anything the per-zone model doesn't already give me. Latency tax on every fresh conversation. |
| Centralized session data | Latency tax on every turn, larger privacy blast radius, weaker isolation, schema coupling. Local-to-container session DB is the right call. |
| Multi-tenant on one host | If I ever host this for someone else, spin a separate VM. The whole design assumes a single human's intent. |

## Accepted trade-offs

- **"Me on public → full powers" is a slight security downgrade** if my
  Slack account is compromised. Accepted: once any inbound channel is
  trusted, that threat exists everywhere. It's a precondition of having
  agents at all, not a feature of this design.
- **Honker is alpha (0.2.x).** Pin versions. Read the source. If it breaks
  badly enough to be a blocker, the migration path is back to pg-boss on
  Postgres — same mental model, more ops.
- **No deep transcript inspection from the host without effort.** Container
  session bytes stay local. If I ever need to inspect, I'll mount a
  container's SQLite read-only at inspect time or add a gated RPC endpoint
  for it. Won't build that until I need it.

## Where to find what

- **Where these principles came from:** the design-context paste in the
  parent chat (May 17 2026). See `comparison-landscape.md` for the prior-art
  this builds on top of.
- **Container model deep-dive:** `trust-zones.md`.
- **Storage and RPC architecture:** `queue-based-rewrite.md`.
- **Open questions for each principle:** `investigations/`.
