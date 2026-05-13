---
name: gh-cli
description: Use the `gh` CLI and `git` to interact with GitHub — list/view PRs and issues, read repo files, clone, push, comment. Use whenever the user asks about a GitHub repo, PR, or issue, or asks you to commit/push/open something on GitHub.
---

# GitHub CLI

You have `gh` and `git` available. Auth is injected by OneCLI at the HTTPS proxy layer — there's no token stored on disk in this container.

## Auth pattern

`gh` refuses to run without *some* token in its environment, so a placeholder is set in the container env (`GH_TOKEN=placeholder`). OneCLI's HTTPS proxy intercepts requests to `api.github.com` and `github.com` and replaces the `Authorization` header with the real PAT. You don't need to do anything — just use `gh` and `git` normally.

**Never** run `gh auth login` or write a token to a file. The placeholder pattern is intentional; logging in would shadow it and break things on the next session.

Sanity check before doing real work:

```bash
gh api user --jq .login   # prints the GitHub username the agent is authenticated as
```

If that returns 401/403, the OneCLI agent in this group is missing the GitHub secret — tell the user to assign the right `gh-clanq-*` secret in OneCLI and stop.

## Scope depends on which group you're in

Each NanoClaw group is wired to a different PAT:

- **clanq-dm** — read/write. You can `gh pr create`, `gh issue comment`, `git push`, etc.
- **clanq-channels** — read-only. You can `gh pr view`, `gh repo view`, `git clone`, `git fetch`, but `git push` and any mutating `gh` call will fail with 403.

If you don't know which group you're in, run `gh api user --jq .login` and check the result against what the user expects. If a write fails with 403 in clanq-channels, that's the design — say so and ask the user to do it themselves or move the request to DM.

## Common reads

```bash
gh repo view OWNER/REPO --json name,description,defaultBranchRef
gh pr list --repo OWNER/REPO --state open
gh pr view 123 --repo OWNER/REPO --comments
gh issue list --repo OWNER/REPO --label bug --state open
gh api repos/OWNER/REPO/contents/path/to/file.ts --jq .content | base64 -d
gh search prs --owner OWNER "is:open review:none"
```

## Common writes (clanq-dm only)

```bash
gh pr create --title "..." --body "..." --base main --head feature-branch
gh pr comment 123 --body "..."
gh pr merge 123 --squash --delete-branch
gh issue create --title "..." --body "..." --label triage
gh issue comment 456 --body "..."
```

## Git over HTTPS

Cloning, fetching, pushing all work through the same OneCLI proxy. Use HTTPS URLs (`https://github.com/owner/repo.git`), not SSH — there's no SSH key in the container.

```bash
git clone https://github.com/OWNER/REPO.git
cd REPO
git checkout -b feature-branch
# ... edits ...
git add -A && git commit -m "..."
git push -u origin feature-branch
```

If `git push` hangs or asks for credentials, the github.com secret is missing. Don't try to type credentials — abort and report.

## Don't

- Don't `gh auth login` or `git config credential.helper` — the proxy handles it.
- Don't echo `GH_TOKEN` or pipe it anywhere — it's a placeholder, not a secret, but printing it is still noise.
- Don't write tokens to `.env`, `.netrc`, or any config file. There are no real tokens to write.
- Don't suggest the user paste a PAT into a chat message. If a credential is missing, the fix is on the host (OneCLI), not in the conversation.
