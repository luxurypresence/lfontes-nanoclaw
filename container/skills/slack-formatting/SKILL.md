---
name: slack-formatting
description: Format messages for Slack. Load before drafting any message that will be delivered to a Slack destination — covers what survives the Chat SDK markdown→Slack conversion, what to use (tables, lists, mentions), and what to avoid (headings, horizontal rules).
---

# Slack Message Formatting

## How it works

Write **standard markdown.** The Slack Chat SDK adapter parses what you write and converts it to whatever Slack actually expects — so:

- Inline styles (bold, italic, strike, inline code, code blocks, blockquotes, links) are translated automatically.
- The **first** markdown table in a message becomes a native Slack table block. Any additional tables in the same message fall back to ASCII inside a code block.
- Bare `@username` mentions are resolved against the workspace and rewritten to user IDs.

Don't try to write Slack-native syntax by hand (`*single asterisks*`, `<url|label>` links, etc.). The adapter expects markdown going in — some Slack-native forms get mangled by its preprocessing.

## What to write

| Feature | Write this |
|---|---|
| Bold | `**bold**` |
| Italic | `_italic_` |
| Strikethrough | `~~strike~~` |
| Inline code | `` `code` `` |
| Code block | ` ```lang\n...\n``` ` |
| Link (named) | `[text](https://...)` |
| Link (bare) | `https://example.com` |
| Blockquote | `> quoted line` |
| Bulleted list | `- item` |
| Numbered list | `1. step` |
| Table (one per message) | `\| col \| col \|`<br>`\|---\|---\|`<br>`\| a \| b \|` |
| User mention | `@luisfontes` (resolved) or `<@U0AELNA1HUZ>` (raw) |
| Channel mention | `<#C12345\|name>` |
| Notify here / channel | `<!here>` / `<!channel>` |
| Emoji | `:tada:` |

### Tables — use them for numbers

Prefer a small markdown table over a flat bullet list whenever you're showing numbers, counts, dates, or anything two-dimensional. The first table per message becomes a real Slack table — sortable columns, aligned cells. Right-align numeric columns with `---:` in the header separator.

Keep tables small. If it doesn't fit on one screen, it belongs in a Notion doc, not a Slack message — and only **one** table per message renders natively, so don't pile them on.

## What does NOT work

- **Headings** (`#`, `##`): rendered as literal `#` text. Use a `**Bold label**` line instead.
- **Horizontal rules** (`---`): rendered as literal `---`. Just use a blank line.
- **Nested lists past ~2 levels**: visually noisy in Slack. Flatten or split.

## Quick rules

1. Write standard markdown — the adapter converts.
2. Use a table for numbers/comparisons; one table per message renders natively.
3. `[text](url)` for named links (not `<url|text>` — that gets stripped on the way in).
4. `@username` for mentions; the adapter resolves it.
5. No headings, no horizontal rules — use bold labels and blank lines.

## Example

````
**PR queue** — *as of 14:02*

| Repo     | PRs open | Mine |
|----------|---------:|-----:|
| crm-web  |       12 |    3 |
| contacts |        8 |    2 |

Top of the queue: [crm-web#4421](https://github.com/lp/crm-web/pull/4421) — waiting on review from @arianna since Friday.

> Reminder: I won't ping the channel about this again unless asked.
````
