# Dashboard access

Local URLs, login, test company, preflight chain. Read at start of every run.

## URLs

| Surface     | URL                                         |
| ----------- | ------------------------------------------- |
| Frontend    | https://local.luxurycoders.com:8000         |
| Federation  | https://local.luxurycoders.com:4000/graphql |
| api-gateway | https://localhost:8001                      |
| cms-service | http://local.luxurycoders.com:8002          |

Frontend is the only surface feature-qa drives. Use the others for triage only — e.g. when a console error references a backend.

## Test company

Default: lfontes staging account (`479e9969-66be-4d58-a6e8-ad9280348390`).

Active-company verification is TODO. The dashboard URL exposes the contact UUID but not the company; the company name doesn't appear in obvious page chrome yet. Until this is mapped, do a best-effort visual check from the open sidebar / header and surface a stop-and-ask if the active company is ambiguous.

## Preflight chain

Run before any browser action. Order matters — earlier steps unblock later ones. feature-qa always operates at the web-platform level; never run `pnpm start` at the monorepo root (turbo's whole-monorepo start hits a cms-jobs-worker race and crashes the chain).

1. Probe HTTPS on port 8000:

   ```bash
   curl -ksf https://local.luxurycoders.com:8000 -m 3 >/dev/null && echo UP
   ```

   If UP, skip to step 6.

2. Check `repos/dashboard/node_modules`. If missing, install:

   ```bash
   cd repos/dashboard && pnpm install
   ```

   If install errors with `ERR_PNPM_FETCH_404 ... @luxury-presence/*`, the npm token is expired. Surface "Run `npm login` then say continue" and stop — this is the one preflight step the caller has to do (interactive auth flow).

3. Check mkcert certs in `repos/dashboard/packages/web-platform/`:

   ```bash
   ls repos/dashboard/packages/web-platform/local.luxurycoders.com*.pem 2>/dev/null
   ```

   If missing, generate:

   ```bash
   cd repos/dashboard/packages/web-platform && mkcert local.luxurycoders.com
   ```

   mkcert is non-interactive once `mkcert -install` has populated CAROOT (which it has on this machine).

4. Detect HTTP-only vite. Vite falls back to HTTP when certs are absent. Auth0 SDK refuses to bootstrap without HTTPS — the page renders an error boundary instead of the app. If port 8000 is bound but HTTPS probe fails while HTTP probe succeeds, kill the stale vite via its PID before starting fresh.

5. Start the web-platform dev server (backgrounded):

   ```bash
   cd repos/dashboard && pnpm -F web-platform start
   ```

6. Poll HTTPS until it responds. Cold compile: ~30s. Warm: <10s. Then navigate Chrome.

## Login

Auth0 session, persisted in the Chrome profile Claude-in-Chrome runs against. If the session is gone, the page redirects to Auth0 — surface a stop-and-ask: "Auth0 session expired. Log in manually in the open Chrome tab, then say 'continue'."

## Other accounts

To be added. Capture into this file when the caller names a new reference account: id, role (SUPER_USER / agent / admin / standard), and what kind of data it has (listings, contacts, integrations).
