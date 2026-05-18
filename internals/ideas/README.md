# ideas/

Forward-looking design notes for the from-scratch rewrite of NanoClaw.

## Foundational docs (read in order)

1. [design-principles.md](design-principles.md) — the canonical "what I'm
   building" doc. 10 principles + the "not doing" list + accepted trade-offs.
   Everything else refers back to this.
2. [comparison-landscape.md](comparison-landscape.md) — where this design
   sits relative to OpenClaw / NanoClaw / IronClaw / ZeroClaw plus the
   lower-layer runtimes (Pi, Agent SDK, Claude Code, …). What's taken from
   each, what's rejected, when to revisit.
3. [trust-zones.md](trust-zones.md) — the container model in detail. Data
   model, routing resolution, identity collapse, what's in a zone.
4. [queue-based-rewrite.md](queue-based-rewrite.md) — storage and RPC
   architecture. Single SQLite + Honker, intent-shaped RPC verbs, two
   long-lived containers.
5. [harness-selection.md](harness-selection.md) — Pi at v1 as the lower-
   layer runtime. The provider abstraction lifted from NanoClaw. Why
   Claude Code headless is the planned second harness, not the Agent SDK.
   May 2026 billing reality.
6. [migration-from-claude-code.md](migration-from-claude-code.md) — the
   selling-point doc. What ports from `~/.claude/` verbatim, what gets
   translated, what drops. The `import-claude-code` CLI spec.
7. [host-surface.md](host-surface.md) — what the host owns beyond
   durability. Single TOML config, read-only dashboard, observability
   primitives. The discipline rules that hold the line against config hell.

## Investigations

Specific open questions with a question / constraints / options /
recommendation / sub-questions structure. Resolve these before writing
code:

- [investigations/01-honker-reality.md](investigations/01-honker-reality.md) — Honker API surface + feature parity with pg-boss + alpha stability
- [investigations/02-skill-tool-declaration.md](investigations/02-skill-tool-declaration.md) — how skills declare needed tools and zones
- [investigations/03-identity-collapse.md](investigations/03-identity-collapse.md) — multi-platform identity → canonical user
- [investigations/04-idle-wake.md](investigations/04-idle-wake.md) — host signals long-lived containers
- [investigations/05-process-cycle.md](investigations/05-process-cycle.md) — fresh context = process restart inside container
- [investigations/06-audit-events.md](investigations/06-audit-events.md) — event schema, retention, queries
- [investigations/07-rpc-catalog.md](investigations/07-rpc-catalog.md) — full intent-shaped RPC API
- [investigations/08-trust-zone-provisioning.md](investigations/08-trust-zone-provisioning.md) — per-zone Dockerfile/credentials/mounts

## Conventions

- **Append-only.** If a direction gets rejected, leave the note with a
  "rejected because…" footer. The reasoning is the value, not the
  conclusion.
- **Cross-reference, don't duplicate.** If two docs need the same idea,
  one owns it and the others link. Drift between copies is the biggest
  failure mode of design docs.
- **Concrete over abstract.** Names, table schemas, endpoint signatures.
  If a doc can't get specific, it's not finished.
