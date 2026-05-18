# ideas-v2-flat/

The **current** design direction for the from-scratch rewrite. Supersedes
`../ideas/` (the container-per-zone model).

## What changed

The v1 design (`../ideas/`) put N agent containers on one VM, with the
host process orchestrating them via Unix-socket RPC and a single
SQLite + Honker queue. Trust boundaries were containers; capabilities
were ambient inside each container; the host owned visibility across
all of them.

v2-flat collapses the layer cake. **The VM itself is the trust zone.**
One trust profile, one VM. No Docker-as-trust-boundary inside the VM —
agents run as a subprocess of a thin Node host, isolated from
credentials by Unix user permissions, not by container walls. The
framework is small enough to hold in your head (~1000–1500 LOC) and
intentionally narrow: a channel adapter that runs your existing
Claude Code (or Codex, or OpenCode) setup as a bot, with observability.

The v1 corpus is preserved next door — not as a draft, as a *rejected
path*. The reasoning that led us to walk down the container model is
load-bearing; you can't tell what v2-flat is without seeing what it
rejected.

## Foundational docs (read in order)

1. [design-principles.md](design-principles.md) — the canonical "what
   I'm building" doc for v2-flat. Ten principles, accepted trade-offs,
   what's explicitly out of scope.
2. [comparison-landscape.md](comparison-landscape.md) — where this
   design sits relative to OpenClaw / NanoClaw / IronClaw / ZeroClaw
   and the lower-layer runtimes (Pi, Claude Code, etc.). Refreshed
   from v1's version to reflect the channel-adapter framing.
3. [deployment-shape.md](deployment-shape.md) — one VM per trust zone.
   exe.dev for v1. The deploy/ folder. Costs.
4. [monorepo-layout.md](monorepo-layout.md) — the `shared/ +
   agents/<name>/ + deploy/` repo structure that *is* the trust
   boundary structure.
5. [harness-mounting.md](harness-mounting.md) — how the user's
   `.claude/` (or `.codex/`, or `.opencode/`) is mounted into a VM
   via OverlayFS. Where session writes land.
6. [framework-versioning.md](framework-versioning.md) — the
   framework as a versioned Docker image. Per-agent independent
   versioning. Migration semantics.
7. [credentials.md](credentials.md) — subprocess env injection. Unix
   user split (host vs. agent). No vault.
8. [host-responsibilities.md](host-responsibilities.md) — what the
   Node host process actually does. ~1000–1500 LOC ceiling.
9. [observability.md](observability.md) — per-VM dashboard. Logging
   proxy. Audit log. Cross-VM aggregation deferred.

## Investigations

Open questions specific to the v2-flat model. Resolve before code.

- [investigations/01-honker-after-simplification.md](investigations/01-honker-after-simplification.md)
  — with one host + one subprocess per VM, do we even need Honker?
- [investigations/02-overlayfs-sessions.md](investigations/02-overlayfs-sessions.md)
  — writable upper-layer semantics across VM reboots, session
  persistence, what goes in the persistent disk.
- [investigations/03-webhook-fanout.md](investigations/03-webhook-fanout.md)
  — N VMs each wired to Slack: one app many webhooks, or N apps?
- [investigations/04-cross-vm-aggregation.md](investigations/04-cross-vm-aggregation.md)
  — the cross-agent visibility loss flagged in the design discussion.
  Options for ever rebuilding it.

## Conventions

Same as v1: append-only (rejected ideas keep their reasoning),
cross-reference rather than duplicate, concrete over abstract.
