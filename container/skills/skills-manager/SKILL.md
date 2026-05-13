---
name: skills-manager
description: Use whenever creating, editing, or planning a skill in `skills/<name>/`. Use even for tiny edits — a one-line tweak, a description change, a rename. Use also when proposing a new skill, picking a name, or planning structure before any files exist. Skip edits to `wiki/`, `plans/`, or anything outside `skills/`. For eval-driven workflows (running test prompts against a skill, packaging a `.skill`, optimizing a description with the eval loop), use `skill-creator` instead.
paths: skills/**/*.md
---

# Role

Custodian of `skills/<name>/`. Owns the repo's skill-authoring conventions; routes to Anthropic's official `skill-creator` for eval-driven workflows.

# Context

| File                          | When to read                                                                                                                                                                              |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `references/skill-creator.md` | Creating a skill from scratch with eval-driven iteration, optimizing a description for triggering accuracy, packaging a `.skill`, or benchmarking variants of a skill against each other. |

# Layout

```
skills/<name>/                 static skill logic
  SKILL.md
  references/<file>.md         static decision trees, recipes, tool routing
  scripts/*                    tooling
  last-check.json              source-refresh tracker (when applicable)

.claude/skills/<name>          relative symlink → ../../skills/<name>
```

SKILL.md loads when the skill triggers; everything under `references/` loads only when SKILL.md cites it. Keep SKILL.md focused on routing and the common case; move detail into `references/` and point at it explicitly from the Context table.

For structural questions (section order, frontmatter shape, Context table format), mirror `skills/data/SKILL.md` or `skills/navigator/SKILL.md`.

# Description (frontmatter)

The `description` field is the primary triggering mechanism — Claude reads it to decide whether to load the skill. Optimize for triggering, not for explaining internals.

- Lead with the key use case. Combined `description` + `when_to_use` is capped at 1,536 characters in the skill listing.
- Include the natural phrases a user would actually say, even when they don't name the skill or its outputs.
- Be a little pushy. "Use whenever the user does X" beats "consider using this for X" — Claude tends to under-trigger skills.
- Keep implementation details out (folder layout, template names, internal section labels). Those belong in the body, which loads on trigger.
- Cover the negative case briefly when it's easy to confuse — what does _not_ warrant the skill.

Spec: https://code.claude.com/docs/en/skills (frontmatter table), https://agentskills.io.

# Voice

- Imperative. "Use X for Y." Not "you should consider using X."
- Calm. No all-caps emphasis (MUST, ALWAYS, NEVER, CRITICAL, IMPORTANT). Imperative voice carries the load.
- Motivated. When a rule isn't self-evident, attach the reason in one short clause.

# Form

- Encode only what's non-obvious — domain knowledge, repo-specific quirks, tool locations, hand-off triggers, rules whose reason isn't self-evident. Skip anything a senior engineer would already know.
- Prefer terseness. SKILL.md body stays in conversation context across turns — every line is a recurring token cost. If removing a line wouldn't lose the rule, remove it.
- Cap files at 500 lines. Applies to `SKILL.md` and any reference file under `skills/` or `wiki/`.
- Use markdown only for structure (headings, lists, code blocks, inline code). No bold or italics — they add visual noise without changing model behavior.
- Say it once. No concept appears in two sections.
- No process scaffolding the model would do anyway. Procedural steps only where sequence is non-obvious or encodes a hand-off.
- Examples only when the example is the rule (a template the consumer copies) or teaches a shape no prose could specify shorter. No paired anti-pattern/correct-pattern blocks.
- Describe operations and capabilities ("run a code-review pass"), not harness primitives (tool names, plugin IDs, agent types). Use skill-relative paths and `wiki/...` paths so the skill reads identically on any AgentSkills-compatible harness.

# Self-audit

Run before surfacing a diff. Look for:

- Reasoning prologues — paragraphs of why before stating the rule. State the rule first; the reason follows.
- Overfitted lists — long do/don't enumerations that cover one specific use case. Trust the canonical rule.
- Hypothetical futures — sections that prepare for capabilities that don't exist yet. Write for today.
- Hedging — "consider", "might want to", "could be useful". State the instruction or remove it.
- Talking to yourself — thinking out loud on the page: rationale, asides, design notes. Cut to the instruction.

# Wiki

Dynamic, accumulating content (gotchas, schema docs, investigated topics) lives in `wiki/`, not in a skill's `references/`. References that auto-refresh from an external source, or graduate from `capture`, count as dynamic.

Skills don't write to `wiki/` directly. Flag findings inline with 🔖 + a one-line note during work; the `wiki` skill is the custodian — it sweeps flagged candidates, lints, and writes with per-item user approval. Exception: a skill whose native output _is_ a wiki document (e.g., `feature-qa` → `wiki/qa/`) writes directly, governed by `skills/wiki/SKILL.md`.
