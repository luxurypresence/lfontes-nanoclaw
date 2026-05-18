# Investigation: skill-needs-tool declaration

## Question

How does a skill declare the tools (and broader capabilities) it requires
to run, so the router can decide whether to surface that skill inside a
given trust-zone container — without the skill itself carrying any
permission-bearing code, and without forking the skill text per zone?

A `clone-repo` skill that wraps `gh` should run unmodified in `dm-trust`
(rw PAT) and `public-trust` (ro PAT). But a `deploy-prod` skill that
genuinely needs write access shouldn't be offered to a sender resolved to
`public-trust` — the router should refuse it, or warn the operator, or
both.

## Constraints (recap, brief)

- Skills = pure markdown + optional helper scripts. No credentials, no
  capability code, no per-zone forks of the text.
- Container is the trust zone; the container holds the credentials and
  binaries. Inside the container the agent has whatever the container has.
- Router is the **only** policy layer. No per-call capability check.
- Same skill text must work across zones when the **intent** is supported
  by the zone's tool surface.
- One human-author (me). Skills are not adversarial. The declaration is for
  *coordination*, not *defense*.

## Options

### 1. YAML frontmatter at the top of `SKILL.md`

A `requires:` block in the skill's own file, e.g.
`requires: { tools: [gh], fs: rw, network: true }`. Pros: one file per
skill, the requirement lives next to the prose that describes the intent,
existing skill conventions already use frontmatter for `name` and
`description`, trivial to grep and audit, the operator sees needs and
description in one place. Cons: pulls structured data into a markdown
file; a typo in the frontmatter is silently ignored until something breaks
at prompt-assembly; YAML's whitespace rules surprise occasionally;
inline-with-text means non-skill consumers (e.g., docs renderers) have to
know about the frontmatter convention.

### 2. Separate `manifest.json` per skill directory

Each skill is a folder; `manifest.json` (or `.toml`) sits alongside
`SKILL.md`. Pros: schema validation is straightforward (`ajv` against a
JSON Schema), tooling-friendly, no markdown parser surprises, the manifest
is a clean machine surface and the markdown is a clean human surface,
easy to extend with helper-script entry points, version pins, etc. Cons:
two files to keep in sync — drift is the standard failure mode; an
operator adding a new skill has to remember the manifest exists; doubles
the surface for what is essentially metadata about prose; encourages
overgrown manifests ("declare every property!") when the actual need is
small.

### 3. Convention/inference from skill text

The system scans `SKILL.md` for known tool names (`gh`, `vercel`,
`claude-code`, `agent-browser`, etc.) and infers requirements from a fixed
allowlist. Pros: zero declaration burden, skill author writes prose
naturally. Cons: brittle — a skill that mentions `gh` in passing
("similar to how `gh` works") would be flagged as requiring it; the
inference rule itself becomes a hidden policy layer (violates principle
3); negation is impossible ("this skill is *about* `gh` but doesn't
actually use it"); changes to the keyword list silently re-classify
skills; this is the kind of cleverness that looks great in a demo and
rots in six months.

### 4. Per-zone explicit skill allowlist (no skill-side declaration)

Each `trust_zone` row carries `available_skills: [...]`; the skill itself
declares nothing. Pros: maximally explicit, no ambiguity about what's
surfaced where, the policy decision lives in one place (the zone
definition) which is where the rest of the policy lives, easy to audit
"what can `public-trust` do?" — read one row. Cons: every new skill
requires touching every zone's allowlist; in practice that means
forgetting and only discovering the omission when a skill mysteriously
isn't offered in a zone; couples skill authoring to zone configuration,
which makes contributed/shared skills painful; doesn't capture *why* a
skill is excluded (was it deliberate, or did someone just forget?).

### 5. Hybrid: zones declare what they offer, skills declare what they need

Trust zones expose a **capability surface** (`tools: [gh, vercel]`,
`fs: rw`, `network: true`, `credentials: [github-rw, vercel-prod]`).
Skills declare their requirement set in frontmatter. At prompt-assembly
time the router computes `skill.requires ⊆ zone.provides` per skill, and
includes only skills whose requirements are satisfied. Pros: the matching
rule is one line of code and the policy decision still lives in the
router (principle 3 intact); the zone definition is the source of truth
for "what's available"; the skill is the source of truth for "what's
needed"; adding a skill is a one-file change; adding a zone is a one-row
change; mismatches are inspectable (`why isn't /deploy available here?` →
`requires fs:rw, zone offers fs:ro`); aligns with how container images
already work (Dockerfile declares what's installed, this just makes it
visible to the router). Cons: two surfaces to keep aligned (zone provides
vs skill requires); the capability vocabulary itself needs to be
maintained and disciplined, otherwise it sprawls into per-tool minutiae.

## Recommendation

**Option 5, with the skill-side declaration implemented as YAML
frontmatter (option 1's mechanism).** The hybrid model captures the
asymmetry of the design: zones own capability bundles, skills express
intent. The router computes the intersection. Frontmatter (not a separate
manifest) because the declaration is small, the failure mode of drift
between two files is real, and the requirement set is genuinely a
property of the skill — keep it next to the prose.

Reject inference (3) outright. Reject pure zone allowlist (4) because it
makes skill authoring an inter-file change. Reject pure-frontmatter
without zone declaration because then the router has to hard-code which
zones provide what, which is exactly the kind of policy sprawl principle
3 forbids.

The capability vocabulary should start **deliberately small** — `tools`,
`fs` (`ro`|`rw`|`none`), `network` (`true`|`false`), `credentials`
(by named credential id). If it grows, it grows by adding a deliberate
new dimension, not by adding a new value to an existing axis without
thought.

## Implementation sketch

### Skill file format

```markdown
---
name: clone-repo
description: Clone a GitHub repo locally using gh CLI.
requires:
  tools: [gh]
  fs: rw
  network: true
  credentials: [github]   # any github credential, not a specific one
---

# clone-repo

Use `gh repo clone <owner>/<repo>` to clone a repo into /workspace.
...
```

A `deploy-prod` skill instead declares:

```yaml
requires:
  tools: [vercel]
  fs: rw
  network: true
  credentials: [vercel-prod]   # specific credential id
```

Note the credential discipline: `github` is a class; `vercel-prod` is a
specific named credential. The zone declares which specific credentials
it carries; the skill declares whether it needs a class or a specific
one. `public-trust` carries `github` (the read-only PAT) → `clone-repo`
matches. It does **not** carry `vercel-prod` → `deploy-prod` is filtered
out.

### Zone declaration

In the central SQLite, alongside the `trust_zones` table from
`trust-zones.md`:

```sql
CREATE TABLE trust_zone_capabilities (
  zone_id      TEXT NOT NULL REFERENCES trust_zones(id),
  kind         TEXT NOT NULL,   -- 'tool' | 'fs' | 'network' | 'credential'
  value        TEXT NOT NULL,   -- 'gh' | 'rw' | 'true' | 'github' | 'vercel-prod'
  PRIMARY KEY (zone_id, kind, value)
);
```

Seeded at zone provisioning time. The Dockerfile and this table are kept
in sync by convention; a `scripts/verify-zone.ts` can diff "what the
Dockerfile says is installed" against "what the table claims" and shout
if they disagree.

### Router resolution

When the router resolves a message to zone Z and is about to assemble the
prompt, it loads all skills, parses frontmatter, and filters:

```ts
function skillsForZone(zone: ZoneCaps, all: Skill[]): Skill[] {
  return all.filter(skill => requirementsMet(skill.requires, zone));
}

function requirementsMet(req: Requires, zone: ZoneCaps): boolean {
  for (const t of req.tools ?? []) if (!zone.tools.has(t)) return false;
  if (req.fs === 'rw' && zone.fs !== 'rw') return false;
  if (req.fs === 'ro' && zone.fs === 'none') return false;
  if (req.network && !zone.network) return false;
  for (const c of req.credentials ?? []) if (!zone.credentials.has(c)) return false;
  return true;
}
```

The filtered set goes into the system prompt's skill index.

### Operator UX

Adding a skill:
1. Drop `skills/<name>/SKILL.md` with frontmatter.
2. Run `ncl skills list --zone dm-trust` and `ncl skills list --zone public-trust`
   to confirm it shows up where intended. If it doesn't, the CLI prints
   the *missing capability* (`needs tool 'gh', zone doesn't provide`).
3. To add the missing capability, either add the tool to that zone's
   Dockerfile + capability table, or accept the skill is intentionally
   gated.

Adding a zone:
1. Insert into `trust_zones` and `trust_zone_capabilities`.
2. Build the zone's container.
3. Skill availability falls out automatically.

### What happens if a user invokes a missing skill

The skill index in the prompt only contains satisfied skills, so the
agent generally won't know to invoke missing ones. If a user types
`/deploy-prod` in a `public-trust` resolved session, the agent should
respond: "That skill isn't available in this trust zone. Reason: needs
`vercel-prod` credential. If you want it here, ask the operator." The
"reason" string is produced by the same `requirementsMet` check, run in
explain mode, so the failure message is mechanically generated from the
real check (no drift between the two).

Silent refusal is wrong — it makes the system feel broken. A helpful
diagnostic is cheap and matches principle 3's audit-friendliness.

### Implementation code paths

- `src/skills/loader.ts` — read skills dir, parse frontmatter (e.g.
  `gray-matter`), validate against schema, cache.
- `src/skills/match.ts` — `requirementsMet` and `explainMismatch`.
- `src/router.ts` — after resolving zone, calls `skillsForZone` and
  passes the filtered list to prompt assembly.
- `ncl skills list [--zone Z]` — CLI surface for operator inspection.
- `scripts/verify-zone.ts` — sanity-check Dockerfile vs DB capability
  table.

## Open sub-questions

- **Granularity of `fs`.** Is `ro` / `rw` / `none` enough, or do we need
  path-scoped declarations (`fs: { /workspace: rw, /etc: ro }`)? Lean
  toward starting simple; revisit if a real skill needs the granularity.
- **Credential classes vs IDs.** Where does the class-to-id mapping live?
  Probably in the zone's capability rows (a zone with `vercel-prod`
  *also* implicitly satisfies `vercel` the class). Needs a small
  convention; don't overbuild.
- **Tool versioning.** A skill that needs `gh >= 2.40` is real eventually.
  Out of scope for v1; add a `version` field to the requires block later.
- **Skills with optional features.** A skill that *can* use `gh` but
  degrades gracefully without it. Punt: just write two skills, or branch
  inside the prose ("if `gh` is available…"). Keep the requires block a
  hard set.
- **Multi-skill conflicts.** Two satisfied skills could in principle ask
  the agent to do contradictory things. That's a prompt-quality problem,
  not a router problem. The router's job ends at "skill is allowed
  here."
- **Discovery for operators.** Should `ncl zones show --id dm-trust` list
  the provided capabilities alongside the assignments? Probably yes,
  cheap to add.
