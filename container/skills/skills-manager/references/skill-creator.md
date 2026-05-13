# Anthropic `skill-creator`

Anthropic's official skill for creating and iterating on skills, distributed with Claude Code. Hand off via the harness; don't duplicate its workflows here.

## Source

- Upstream: https://github.com/anthropics/skills/tree/main/skills/skill-creator
- Local mirror: `.claude/skills/skill-creator/`

## When to reach for it

- Creating a skill from scratch with eval-driven iteration — write skill → run test prompts → grade outputs → improve.
- Optimizing a `description` for triggering accuracy via the eval-driven optimization loop.
- Packaging a skill into a `.skill` bundle.
- Blind A/B comparison between two versions of a skill.

## When not to reach for it

- Routine edits to an existing skill — apply the conventions in the parent `SKILL.md` and ship.
- Adding a reference file or example to an existing skill.
- Renaming, restructuring, or splitting a skill where the workflow shape is unchanged.
- Tweaking a description by hand based on a single observation — reach for the optimization loop only when description quality is a measurable problem.
