# ideas-v3-hybrid/

The **current** design direction. Supersedes `../ideas/` (the
container-orchestrator model that ended up over-engineered) and
`../ideas-v2-flat/` (the VM-per-agent model that ended up
over-fragmented at N≥2).

v3-hybrid keeps the insights that survived both rounds and lands
in the middle: **one VM, one host process, N agent containers,
one dashboard.** The framework distributes as a single npm package
plus a small set of pre-built base images. The user's existing
Claude Code config (skills, MCP servers, CLAUDE.md, etc.) mounts
into the containers verbatim — no translation, no framework
intrusion into `~/.claude/`.

## What changed (the short version)

| | v1 (rejected) | v2-flat (rejected) | **v3-hybrid (this folder)** |
|--|---------------|---------------------|------------------------------|
| Topology | 1 VM, N containers, baroque IPC | N VMs, no containers, no host | **1 VM, N containers, simple host** |
| Trust unit | Container | VM | **Container** |
| State storage | Two SQLite DBs per session, OneCLI vault, Honker pub/sub | One SQLite per VM | **One SQLite per VM (in user monorepo)** |
| Host ↔ container IPC | Long-poll RPC, dual-DB seq parity | n/a — no host | **stdin/stdout NDJSON via `docker exec`** |
| Dashboard | One central | N per-VM | **One central** |
| Framework distribution | (undecided) | Docker image per VM | **npm package + base images** |
| Mount strategy | Per-session DB bind mounts | OverlayFS three-layer | **Deploy-time merge + two bind mounts** |
| Operator-facing scope | Heavy | Heavy at N≥2 | Light at any N |

v1's container-as-trust-boundary insight survives. v2-flat's
monorepo + mount-don't-translate + framework-not-in-user-repo
insights survive. v1's IPC baroqueness and v2-flat's per-VM
fragmentation are both rejected.

## Foundational docs (read in order)

1. [design-principles.md](design-principles.md) — the canonical
   "what I'm building" doc for v3-hybrid. Ten principles, accepted
   trade-offs, what's explicitly out of scope.
2. [comparison-landscape.md](comparison-landscape.md) — where this
   design sits relative to OpenClaw / NanoClaw / IronClaw / ZeroClaw
   and the lower-layer runtimes (Pi, Claude Code, …). Refreshed for
   the channel-adapter framing.
3. [deployment-shape.md](deployment-shape.md) — one VM, exe.dev for
   v1, bootstrap installs Node + pnpm + Docker.
4. [monorepo-layout.md](monorepo-layout.md) — the `shared/ +
   agents/<name>/ + deploy/ + data/` repo structure.
5. [distribution.md](distribution.md) — framework as an npm package
   `@yourname/agent-host`, plus pre-built base images per harness.
   How updates flow.
6. [harness-mounting.md](harness-mounting.md) — how the user's
   `.claude/` is brought into each container via deploy-time merge
   and two bind mounts. No OverlayFS.
7. [container-shim.md](container-shim.md) — the ~150 LOC framework-
   owned shim that runs as the container's entrypoint, manages the
   harness subprocess, and proxies I/O to the host.
8. [framework-versioning.md](framework-versioning.md) — one version
   number, three artifacts. Migration model.
9. [credentials.md](credentials.md) — `/etc/agent/env` on the host;
   host injects per-container subsets at spawn time. No vault.
10. [host-responsibilities.md](host-responsibilities.md) — what the
    Node host process actually does. ~1500 LOC ceiling.
11. [observability.md](observability.md) — single dashboard,
    cross-agent views free. Logging proxy.

## Investigations

- [investigations/01-honker-after-simplification.md](investigations/01-honker-after-simplification.md)
  — carried over from v2-flat. Recommendation unchanged: drop Honker,
  go SQLite-only. The simplification of "host on VM, not in container"
  reinforces it.
- [investigations/02-container-shim-protocol.md](investigations/02-container-shim-protocol.md)
  — the NDJSON protocol between host and container shim. Heartbeat,
  cycle, crash recovery.

## Conventions

Same as the previous two folders. Append-only (rejected directions
keep their reasoning), cross-reference rather than duplicate,
concrete over abstract. v1 and v2-flat folders are part of the
reasoning trail — they're not stale, they're the rejected paths
that justify the current shape.
