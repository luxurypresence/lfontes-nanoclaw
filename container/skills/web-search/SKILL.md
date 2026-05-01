---
name: web-search
description: Search the web and fetch known URLs using Anthropic's hosted WebSearch and WebFetch tools — fast, cheap, no browser required. Prefer this over agent-browser for any task that's just "find me X" or "read this page", and fall back to agent-browser only when you need to interact, log in, click, or render JS-heavy content.
allowed-tools: WebSearch, WebFetch
---

# Web search and lightweight fetch

Two server-side tools, both allowlisted, no permission prompt:

- **`WebSearch(query)`** — Anthropic-hosted search. Returns ranked results (title, URL, snippet). One round trip, no Chromium, billed in API spend.
- **`WebFetch(url, prompt)`** — fetches a known URL and answers a question against its content. Faster than `agent-browser open` + scrape for static pages.

## When to use which

| Task                                                  | Tool                                       |
|-------------------------------------------------------|--------------------------------------------|
| "What's the latest on X?" / "Find docs for Y"         | `WebSearch`                                |
| "Read this article and summarize" (URL in hand)       | `WebFetch`                                 |
| "Compare these N pages" (URLs in hand)                | `WebFetch` per page                        |
| "Log into <app> and do Z" / fill a form / click       | `agent-browser` (see its skill)            |
| JS-heavy SPA where `WebFetch` returns nothing useful  | `agent-browser`                            |
| Screenshots, PDFs, downloads                          | `agent-browser`                            |
| Anything behind auth                                  | `agent-browser` with saved state           |

Default: try `WebSearch` / `WebFetch` first. They're an order of magnitude cheaper in tokens and latency than spinning up Chromium. Escalate to `agent-browser` only when you actually need a browser.

## WebSearch

```
WebSearch(query="luxury presence jobs platform engineer")
```

Optional filters (use sparingly, they narrow results hard):

- `allowed_domains=["docs.example.com"]` — restrict to specific domains
- `blocked_domains=["pinterest.com"]` — exclude noisy domains

Returns a ranked list. Read the snippets to decide which result to fetch in full.

## WebFetch

```
WebFetch(url="https://example.com/article", prompt="What does this say about pricing?")
```

The `prompt` is an instruction to a small model that summarizes the page for you — be specific, since the raw HTML never reaches the main context. If you need the full text, ask explicitly: `prompt="Return the full article text verbatim, no summary."`

`WebFetch` follows redirects and handles most static HTML / Markdown / RSS / JSON. It does not execute JavaScript — for anything client-rendered, switch to `agent-browser`.

## Citing results

When grounding an answer in something you found, include the source URL inline. In Slack groups, use `<url|label>` syntax (the host CLAUDE.md covers Slack mrkdwn rules).
