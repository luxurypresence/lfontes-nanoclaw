---
name: notion
description: Read, search, and create Notion pages — LP's docs surface.
---

# Notion at LP

Notion is LP's docs / wiki / planning surface. The MCP server exposes the standard Notion tools (search pages/databases, query, create-page, update-page, append-block, etc.).

## Auth

Routed through MintMCP — auth + page-permission scope is configured server-side at the MintMCP gateway, not on the client. If a call fails with a permission error, the scope of the configured token is the cause; surface the failure, don't retry.

## Citation

When citing Notion content, prefer the page title plus a permalink so the reader can verify. Bare titles are ambiguous.
