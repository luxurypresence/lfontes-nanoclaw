# NanoClaw v2 Install Flow: Complete Trace

A step-by-step documentation of what happens when a user installs NanoClaw from `git clone` to a running service.

## 1. User-Facing Entry Points

Three ways users start the install:

### 1.1 Direct bash entry: `bash setup.sh` (legacy, still supported)
- **File:** `/home/exedev/nanoclaw/setup.sh` (lines 1-248)
- Runs only the bash-side bootstrap (Node + pnpm + native modules).
- Does NOT hand off to `setup:auto` — user must run `pnpm run setup:auto` separately.
- Used by: developers, direct-shell users, testing.

### 1.2 Full orchestrator: `bash nanoclaw.sh` (recommended)
- **File:** `/home/exedev/nanoclaw/nanoclaw.sh` (lines 1-374)
- **Entry point:** User types `bash nanoclaw.sh` from the repo root.
- Renders ASCII splash (under-the-sea lobster in truecolor braille + figlet wordmark).
- Runs pre-flight checks (RAM, GCP warning, root user warning, Homebrew on macOS).
- **Part 1 (bash):** Invokes `bash setup.sh`, captures output, renders spinner with elapsed time.
- **Part 2 (Node):** Sets `NANOCLAW_BOOTSTRAPPED=1`, calls `pnpm run setup:auto` (which exec's to avoid subshell).
- Defines three-level logging contract: user-facing (clack), progression (logs/setup.log), raw-per-step (logs/setup-steps/NN-name.log).

### 1.3 Claude Code skill: `/setup` (operational setup via chat)
- **Trigger:** User runs `/setup` or `/setup --step <name>` in Claude Code.
- Routes through `setup/index.ts::main()` (lines 29-66), which dispatches individual steps.
- Allows re-running single steps (e.g., `--step onecli`, `--step service`) without the full flow.
- Used for: debugging, re-config, post-install modifications.

### 1.4 Relationship between entry points
- `bash nanoclaw.sh` is the primary UX — combines bootstrap + auto in a continuous visual flow.
- `bash setup.sh` is the implementation (no clack, just bash spinners) — callable standalone or by `nanoclaw.sh`.
- `/setup` skill is an administrative tool — for re-running steps, debugging, adding channels post-install.
- All three converge on the same TS step handlers in `setup/*.ts`.

---

## 2. Phase 1: Environment Check (bootstrap)

**File:** `setup.sh` (lines 50-177) + `setup/environment.ts` (lines 81-142)

### 2.1 Bash-side detection (setup.sh)

1. **Platform detection** (lines 23-46):
   - Reads `uname -s` → maps to `darwin` (macOS) or `linux` (Linux).
   - Detects WSL via `/proc/version` grep.
   - Detects root user via `id -u`.
   - Logs all three to `$LOG_FILE` (default: `logs/bootstrap.log`).

2. **Node.js check** (lines 49-68):
   - `command -v node` → reads version.
   - Requires Node 20+.
   - If missing or too old, runs `bash setup/install-node.sh`.
   - On macOS Homebrew, installs via `brew install node@22`.
   - On Linux, installs from source or distro package manager.

3. **pnpm install** (lines 70-159):
   - Uses corepack (if available) to enable pnpm shim.
   - Fallback: `npm install -g pnpm@<pinned-version>` (from `package.json`'s `packageManager` field).
   - Discovers npm's global prefix and prepends `~/.npm-global/bin` if needed (custom `npm config set prefix`).
   - Runs `pnpm install --frozen-lockfile`.
   - Verifies `better-sqlite3` native module loads (indicates build tools work).

4. **Build tools check** (lines 161-177):
   - macOS: `xcode-select -p` (Command Line Tools installed?).
   - Linux: `gcc` + `make` present?
   - Logged but not blocking — just informational.

### 2.2 TS-side detection (setup/environment.ts)

Run as the first step in `setup:auto` (auto.ts line 125):

```bash
pnpm exec tsx setup/index.ts --step environment
```

Checks:

| Check | Method | Status Values |
|-------|--------|----------------|
| Platform | `os.platform()` → darwin/linux | PLATFORM: macos\|linux\|unknown |
| WSL | `/proc/version` grep | IS_WSL: true\|false |
| Headless | `$DISPLAY` and `$WAYLAND_DISPLAY` absent (Linux only) | IS_HEADLESS: true\|false |
| Docker | `docker info` | DOCKER: running\|installed_not_running\|not_found |
| .env exists | `path.join(cwd, '.env')` | HAS_ENV: true\|false |
| Auth dir | `store/auth/` with files | HAS_AUTH: true\|false |
| Registered groups | `data/registered_groups.json` or agent_groups count in DB | HAS_REGISTERED_GROUPS: true\|false |
| OpenClaw legacy | `~/.openclaw` or `~/.clawdbot` | OPENCLAW_PATH: path\|none |

Emits status block to `logs/setup-steps/02-environment.log` (per the three-level contract).

---

## 3. Phase 2: Dependencies + Build

### 3.1 pnpm install (already done in setup.sh)

```bash
cd /home/exedev/nanoclaw
pnpm install --frozen-lockfile
```

Installs:
- Host dependencies (TS, node_modules/).
- Better-sqlite3 native module (requires build tools).
- All transitive deps for `src/`, `setup/`, scripts.
- Does NOT build the dist yet (that's deferred to service step).

### 3.2 Container image build

**File:** `setup/container.ts` (lines 82-244)

Run as the second major step (auto.ts line 148):

```bash
pnpm exec tsx setup/index.ts --step container
```

Workflow:

1. **Docker availability check:**
   - `docker info` → running, installed-but-stopped, or not-found.
   - If not running, try `open -a Docker` (macOS) or `sudo systemctl start docker` (Linux).
   - On Linux, if socket permission denied (EACCES), re-exec under `sg docker` (auto.ts lines 135-152).

2. **Docker install fallback:**
   - If `docker` not found, run `setup/install-docker.sh`.
   - macOS: `brew install docker` (or Docker Desktop).
   - Linux: `sudo apt-get install docker.io` (or distro equivalent) + add user to docker group.

3. **Build the agent image:**
   ```bash
   cd container/
   docker build \
     --build-arg INSTALL_CJK_FONTS=<from .env if set> \
     -t nanoclaw-agent:latest \
     .
   ```
   - Reads `./container/Dockerfile`.
   - Pulls base image (debian:bookworm or alpine, typically).
   - Installs agent runtime dependencies: Python, git, curl, etc.
   - Builds agent-runner inside container (bun install in `container/agent-runner/`).
   - Caches Docker layers — subsequent builds re-use cached steps.
   - Takes 3–10 minutes on first run.

4. **Test the image:**
   ```bash
   echo '{}' | docker run -i --rm --entrypoint /bin/echo nanoclaw-agent:latest "Container OK"
   ```
   - Verifies the image boots and basic I/O works.

5. **Emit status:**
   - `BUILD_OK: true/false`, `TEST_OK: true/false`.
   - On failure, exit(1) and abort setup.

---

## 4. Phase 3: OneCLI Install + Init

**File:** `setup/onecli.ts` (lines 293-457)

Run after container (auto.ts line 178):

```bash
pnpm exec tsx setup/index.ts --step onecli [--reuse | --remote-url <url>]
```

Three modes:

### 4.1 Fresh install (default)

1. **Remove legacy v1 OneCLI containers:**
   - Query `docker ps -a` for compose project "onecli" with service != "onecli" or "postgres".
   - Remove old containers (fixes port conflicts).

2. **Install OneCLI gateway (docker-compose):**
   ```bash
   export ONECLI_VERSION=1.23.0
   curl -fsSL onecli.sh/install | sh
   ```
   - Downloads docker-compose config.
   - Brings up `onecli` (main gateway) and `postgres` services.
   - Listens on `http://127.0.0.1:10254` (default).

3. **Install OneCLI CLI:**
   ```bash
   curl -fsSL onecli.sh/cli/install | sh
   ```
   - Downloads pre-built binary to `~/.local/bin/onecli`.
   - Fallback if GitHub API rate-limit: direct download from releases.
   - Version pinned to `1.3.0` or resolved via HTTP redirect.

4. **Configure CLI:**
   ```bash
   onecli config set api-host http://127.0.0.1:10254
   ```

5. **Write .env:**
   ```bash
   ONECLI_URL=http://127.0.0.1:10254
   ```

6. **Health poll:**
   - `GET /api/health` up to 15 seconds.
   - Continues even if unhealthy (auth gateway may be gated).

### 4.2 Reuse mode (--reuse)

- User has another app already using OneCLI (e.g., another NanoClaw install).
- Detect via `onecli version` and `onecli config get api-host`.
- Skip installer, write ONECLI_URL to .env, poll health.

### 4.3 Remote mode (--remote-url <url>)

- Advanced setup: gateway runs on a different machine.
- Install CLI only, point at remote URL.
- Optional: `NANOCLAW_ONECLI_API_TOKEN=<key>` written to .env for API auth.

### 4.4 Update shell profile

Appends to `~/.bashrc` and `~/.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```
Ensures `onecli` is on PATH for subsequent steps (auth, service, etc.).

---

## 5. Phase 4: Database Init

**Implicit in:** `setup/service.ts::setupLinux/setupLaunchd` (lines 34-53)

Happens when the service first starts:

1. **Database creation:**
   - Path: `data/v2.db` (central SQLite, using better-sqlite3).
   - Migrations run on first boot via `src/db/migrations/` (numeric prefix order).
   - Create tables: `agent_groups`, `messaging_group_agents`, `users`, `channels`, `messages`, etc.

2. **Seed data (optional):**
   - If this is a fresh install and no groups exist, the service may create default entries.
   - CLI agent group wired up by `setup/cli-agent.ts` (phase 6).

3. **Persistence:**
   - Data survives restarts (SQLite file on disk).
   - Later channel installs (`/add-telegram`, etc.) insert rows into chat-sdk-bridge tables.

---

## 6. Phase 5: Service Install

**File:** `setup/service.ts` (lines 26-87 main, 122-217 macOS, 219-479 Linux)

Run after auth (auto.ts line 300):

```bash
pnpm exec tsx setup/index.ts --step service
```

Workflow:

1. **Build TypeScript:**
   ```bash
   pnpm run build
   ```
   - Compiles `src/**/*.ts` → `dist/`.
   - Includes server binary, SDK, db migrations, etc.

2. **Peer cleanup:**
   - Detect unhealthy peer NanoClaw installs (v1 or other checkouts).
   - Unload crash-looping services to prevent container orphaning.

3. **Platform-specific service setup:**

### 6.1 macOS: launchd

1. **Generate plist:**
   ```xml
   ~/Library/LaunchAgents/<label>.plist
   ```
   where `<label>` is from `src/install-slug.ts::getLaunchdLabel()` (hash-based, e.g., `nanoclaw-abc1def2`).

   Contents (from service.ts lines 138–167):
   ```xml
   <key>Label</key>
   <string>nanoclaw-abc1def2</string>
   <key>ProgramArguments</key>
   <array>
     <string>/opt/homebrew/bin/node</string>
     <string>/Users/me/nanoclaw/dist/index.js</string>
   </array>
   <key>WorkingDirectory</key>
   <string>/Users/me/nanoclaw</string>
   <key>RunAtLoad</key> <true/>
   <key>KeepAlive</key> <true/>
   <key>StandardOutPath</key>
   <string>/Users/me/nanoclaw/logs/nanoclaw.log</string>
   <key>StandardErrorPath</key>
   <string>/Users/me/nanoclaw/logs/nanoclaw.error.log</string>
   ```

2. **Load with launchctl:**
   ```bash
   launchctl unload ~/Library/LaunchAgents/nanoclaw-abc1def2.plist 2>/dev/null || true
   launchctl load ~/Library/LaunchAgents/nanoclaw-abc1def2.plist
   ```
   Unload first (clears cached plist in launchd) so edits take effect immediately.

3. **Verify:**
   ```bash
   launchctl list | grep nanoclaw-abc1def2
   ```

### 6.2 Linux: systemd (preferred) or nohup fallback

**If systemd available:**

1. **User-level unit (non-root):**
   ```
   ~/.config/systemd/user/nanoclaw-abc1def2.service
   ```
   Contents:
   ```ini
   [Unit]
   Description=NanoClaw Personal Assistant
   After=network.target

   [Service]
   Type=simple
   ExecStart=/usr/bin/node /home/user/nanoclaw/dist/index.js
   WorkingDirectory=/home/user/nanoclaw
   Restart=always
   RestartSec=5
   StandardOutput=append:/home/user/nanoclaw/logs/nanoclaw.log
   StandardError=append:/home/user/nanoclaw/logs/nanoclaw.error.log

   [Install]
   WantedBy=default.target
   ```

2. **System-level unit (root):**
   - Same unit, but at `/etc/systemd/system/nanoclaw-abc1def2.service`.
   - `WantedBy=multi-user.target` instead of `default.target`.

3. **Enable and start:**
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable nanoclaw-abc1def2
   systemctl --user restart nanoclaw-abc1def2
   ```

4. **Docker group stale check (Linux non-root):**
   - If user was added to `docker` group mid-session, user systemd session doesn't see it yet.
   - Apply temporary ACL: `sudo setfacl -m u:$USER:rw /var/run/docker.sock`.
   - Or ask user to re-log in.

5. **Enable linger (Linux non-root):**
   ```bash
   loginctl enable-linger
   ```
   So the service survives SSH logout.

**If systemd unavailable (WSL without systemd, old Linux):**

Generate bash wrapper (`start-nanoclaw.sh`):
```bash
nohup /usr/bin/node /home/user/nanoclaw/dist/index.js \
  >> /home/user/nanoclaw/logs/nanoclaw.log \
  2>> /home/user/nanoclaw/logs/nanoclaw.error.log &
echo $! > /home/user/nanoclaw/nanoclaw.pid
```

User must manually `bash start-nanoclaw.sh` to start (or add to `.bashrc`).

4. **Install ncl symlink:**
   ```bash
   ln -s /home/user/nanoclaw/bin/ncl ~/.local/bin/ncl
   ```
   Makes `ncl` CLI available from anywhere.

---

## 7. Phase 6: First Agent + Channel Wiring

### 7.1 CLI agent creation

**File:** `setup/cli-agent.ts` (lines 59-88)

Run after service (auto.ts line 334):

```bash
pnpm exec tsx setup/index.ts --step cli-agent \
  --display-name "Alice" \
  --agent-name "Terminal Agent" \
  --folder _ping-test
```

Wraps `scripts/init-cli-agent.ts`:

1. Creates a messaging group in the database.
2. Inserts a user row with `id: 'cli:local'` and `display_name: 'Alice'`.
3. Creates a local Unix socket at `data/cli.sock` (readable by this user).
4. CLI input piped through socket → routed to the agent container → response streamed back.

### 7.2 First-chat test (optional)

**File:** auto.ts lines 358-431

1. **Ping the CLI socket:**
   ```bash
   echo "ping" | nc -U data/cli.sock
   ```
   (via the helper `pingCliAgent()` in auto.ts).

2. **Wait for pong (cold start takes 30–60s):**
   - Container boots, authenticates with OneCLI, initializes SDK.
   - Elapsed timer shown to user ("Waking your assistant…").

3. **On success:**
   - Offer user to chat interactively via `pnpm run chat hi` (sends message, waits for reply).
   - Or continue setup (skip to next phase).

4. **On failure:**
   - Suggest `tail -f logs/nanoclaw.log` to debug.
   - Offer Claude Code fallback to diagnose.

### 7.3 Channel installation (optional, selected by user)

**Auto.ts lines 441-483** prompts:
> "Want to chat with your assistant from your phone?"

Options: Telegram, Discord, WhatsApp, Signal, Teams, Slack, iMessage, Other, Skip.

Each channel flow (e.g., `runTelegramChannel()` in `setup/channels/telegram.ts`):

1. **OAuth/API token collection** (clack prompts, channel-specific).
2. **OneCLI secret creation:**
   ```bash
   onecli secrets create --name "<channel>" --type "<type>" --value "<token>"
   ```
3. **Chat SDK bridge table insertion** (SQLite):
   - Row in `messaging_group_agents` linking agent group → channel credential.
4. **Spawn container with channel env vars** (service config will read these at restart).

Example (Telegram):
- User provides Telegram bot token.
- Stored in OneCLI as `Telegram:bot_token`.
- Service reads at startup: `TELEGRAM_TOKEN=<placeholder>` (OneCLI injects real token on outbound requests).
- Bot webhook registered (if enabled).

---

## 8. Phase 7: Verification

**File:** `setup/verify.ts` (lines 26-150+)

Run before the final outro (auto.ts line 487):

```bash
pnpm exec tsx setup/index.ts --step verify
```

Checks:

| Item | Method | Status |
|------|--------|--------|
| Service running | `launchctl list` (macOS) or `systemctl is-active` (Linux) | running\|stopped\|not_found |
| Service checkout | Resolve binary `/proc/<pid>/exe` → project path | running\|running_other_checkout |
| Claude credentials | `onecli secrets list` → find type="anthropic" | configured\|not_configured |
| Configured channels | Count `messaging_group_agents` rows | count |
| Database writable | Open `data/v2.db` and test write | ok\|failed |
| Socket reachable | Attempt ping on `data/cli.sock` | ok\|failed |

**Soft failure mode:** If some checks fail, emit a "What's left" note listing unresolved issues, but don't abort. The user can still use the CLI or retry channels.

---

## 9. Migration Path: v1 → v2

**File:** `migrate-v2.sh` (lines 1-150+)

User runs from v2 checkout:
```bash
bash migrate-v2.sh
```

High-level steps:

1. **Find v1 install:**
   - Check sibling directory, or env `NANOCLAW_V1_PATH`.
   - Verify it's actually v1 (check `data/` structure, version field, etc.).

2. **Bootstrap v2:**
   - Run `bash setup.sh` to ensure Node, pnpm, deps.

3. **Migrate data:**
   - Read v1's SQLite database (`data/v1.db` or `.db`).
   - Extract users, groups, credentials, channel config.
   - Insert into v2's `data/v2.db` (with schema translation).

4. **Migrate OneCLI secrets:**
   - Query v1's OneCLI vault.
   - Replica to v2 OneCLI (or reuse same OneCLI instance).

5. **Switch service:**
   - Unload v1 service (launchctl unload / systemctl disable).
   - Load v2 service.
   - Verify v2 boots with migrated data.

6. **Report:**
   - Write `logs/migrate-v2.log` and step logs.
   - Emit JSON handoff summarizing what succeeded/failed.

---

## 10. Step-by-Step Happy Path (Fresh Install)

User runs:
```bash
bash nanoclaw.sh
```

### Steps executed in order:

1. **Pre-flight checks** (nanoclaw.sh lines 125-248)
   - RAM >= 3.7 GB.
   - Not on Google Cloud (known issue).
   - Not running as root (on Linux; warn).
   - Homebrew present (on macOS; offer install).

2. **Bootstrap** (~1–3 minutes, setup.sh)
   - Detect platform, Node, pnpm, build tools.
   - Install Node if needed (source or Homebrew).
   - Run `pnpm install --frozen-lockfile`.
   - Verify better-sqlite3 builds.

3. **Wordmark splash** (nanoclaw.sh line 138)
   - ASCII lobster + figlet "NanoClaw".

4. **Hand off to setup:auto** (nanoclaw.sh line 373)
   - Sets `NANOCLAW_BOOTSTRAPPED=1`.
   - Exec `pnpm run setup:auto`.

5. **Setup start** (auto.ts lines 91-93)
   - Emit `auto_started` event.
   - Initialize progression log (`logs/setup.log`).

6. **Welcome menu** (auto.ts lines 100–115)
   - "Standard setup" (default) vs. "Advanced" (override defaults).
   - User selects Standard.

7. **Environment check** (~2 seconds, auto.ts lines 125–135)
   - Detect Docker, platform, existing config.
   - Emit `02-environment.log`.

8. **Container build** (~3–10 minutes, auto.ts lines 138–176)
   - Ensure Docker running/installed.
   - Re-exec under `sg docker` if needed (Linux group perms).
   - Build image, test it.
   - Spinner shows elapsed time.

9. **OneCLI install** (~1 minute, auto.ts lines 178–278)
   - Check if OneCLI already running (offer reuse).
   - Install gateway + CLI.
   - Poll health endpoint.
   - Write `ONECLI_URL` to `.env`.

10. **Auth step** (~1–2 minutes interactive, auto.ts lines 280–803)
    - Display auth method menu:
      - Sign in with subscription (browser OAuth).
      - Paste OAuth token.
      - Paste API key.
      - Skip.
    - User chooses "subscription".
    - Run `bash setup/register-claude-token.sh`.
    - Script invokes `claude setup-token` (opens browser → user signs in → token extracted → `onecli secrets create`).

11. **Mounts** (~1 second, auto.ts lines 284–297)
    - Write mount allowlist to `.env` or config file.
    - Container's allowed directories initialized.

12. **Service install** (~1 minute, auto.ts lines 299–315)
    - Run `pnpm run build`.
    - Generate launchd plist (macOS) or systemd unit (Linux).
    - Load service with system manager.
    - Spinner shows "Starting NanoClaw in the background".

13. **CLI agent creation** (~2 seconds, auto.ts lines 334–341)
    - Prompt for display name ("What should your assistant call you?").
    - Default: `$USER`.
    - User enters "Alice".
    - Create cli:local user, Unix socket, wiring table.

14. **First-chat test** (~30–60 seconds, auto.ts lines 349–358)
    - Prompt for display name (cached from step 13).
    - "Waking your assistant…" spinner.
    - Ping socket until pong (or 30-second timeout).
    - Container boots, SDK initializes, OneCLI proxies auth.

15. **First-chat interactive loop** (optional, auto.ts lines 661–689)
    - "Try a quick hello — or press Enter to continue setup".
    - User types "hi there".
    - Spawns `pnpm run chat hi there`.
    - Agent responds, loops for more messages or Enter to skip.

16. **Timezone** (~3 seconds if auto-detected, auto.ts lines 434–1076)
    - Auto-detect from system (`timedatectl` on Linux, `systemsetup` on macOS).
    - If UTC (likely VPS), confirm with user ("Is that right?").
    - User selects "I'm somewhere else" → text prompt → "Los Angeles" → resolves to `America/Los_Angeles`.
    - Run `setup/timezone.ts --tz America/Los_Angeles`.

17. **Channel selection** (optional, auto.ts lines 441–483)
    - "Want to chat from your phone?"
    - Options: Telegram, Discord, WhatsApp, Signal, Teams, Slack, iMessage, Other, Skip.
    - User selects "Telegram".
    - Runs `runTelegramChannel(displayName)` → prompts for bot token → stores in OneCLI → updates chat-sdk-bridge tables.

18. **Verification** (~5–10 seconds, auto.ts lines 486–539)
    - Check service running (`launchctl list` / `systemctl is-active`).
    - Check credentials present (`onecli secrets list`).
    - Check database OK (`open v2.db, SELECT 1`).
    - If all pass, print "Everything's connected".
    - If partial, print "What's left" note (e.g., "Want to chat from your phone? Add a messaging app with `/add-slack`, etc.").

19. **Outro** (auto.ts lines 542–574)
    - Print "Try these" suggestions:
      - `pnpm run chat hi` (terminal chat).
      - `tail -f logs/nanoclaw.log` (watch logs).
      - `claude` (open Claude Code).
    - Print "Heads up" note (NanoClaw runs on this machine, only reachable while on).
    - Print "Go say hi" banner with Telegram DM directive.
    - Emit `setup_completed` event.
    - `pnpm run setup:auto` exits with code 0.

20. **Post-setup** (implicit)
    - User is back at shell prompt.
    - launchd/systemd service running in background.
    - Can now:
      - Chat via `pnpm run chat hi`.
      - Add channels via `/add-<channel>` in Claude Code.
      - Check logs via `tail -f logs/nanoclaw.log`.

---

## Environment Variables & Configuration Files

### .env (auto-generated)

```bash
ONECLI_URL=http://127.0.0.1:10254
NANOCLAW_DISPLAY_NAME=Alice
NANOCLAW_AGENT_NAME=Terminal Agent
# Custom endpoint (if user set it):
ANTHROPIC_BASE_URL=https://custom.api.example.com/v1
```

### Shell profiles (.bashrc, .zshrc — appended)

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### launchd plist (macOS)

```
~/Library/LaunchAgents/nanoclaw-<hash>.plist
```

Template substitution in `service.ts::setupLaunchd()` (lines 138–167):
- `${label}` → hash-based unique label.
- `${nodePath}` → `/opt/homebrew/bin/node` or equivalent.
- `${projectRoot}` → `/Users/user/nanoclaw`.
- `${homeDir}` → `/Users/user`.

### systemd unit (Linux)

```
~/.config/systemd/user/nanoclaw-<hash>.service (non-root)
/etc/systemd/system/nanoclaw-<hash>.service (root)
```

---

## Key Files & Directories Post-Install

```
nanoclaw/
├── dist/                          # Compiled JavaScript (built by pnpm run build)
│   └── index.js                   # Service entry point
├── data/
│   ├── v2.db                      # Central SQLite database
│   ├── cli.sock                   # Unix socket for CLI input/output
│   └── registered_groups.json     # Persisted messaging group IDs (optional)
├── logs/
│   ├── nanoclaw.log               # Service stdout (appended)
│   ├── nanoclaw.error.log         # Service stderr (appended)
│   ├── setup.log                  # Setup progression log (per-run)
│   └── setup-steps/
│       ├── 01-bootstrap.log       # Raw bootstrap output
│       ├── 02-environment.log     # Raw environment check
│       ├── 03-container.log       # Raw docker build
│       └── ...
├── .env                           # Configuration (ONECLI_URL, custom endpoint, etc.)
├── store/
│   └── auth/                      # Channel credentials (plain files, or empty placeholder)
└── start-nanoclaw.sh              # (Linux without systemd) Wrapper script to start service
```

---

## Error Modes & Recovery

| Error | Phase | Recovery |
|-------|-------|----------|
| Node missing | bootstrap | Install via setup/install-node.sh; retry. |
| pnpm install fails | bootstrap | Run `pnpm install --frozen-lockfile` manually; check disk space. |
| Docker not found | container | Run setup/install-docker.sh or `brew install docker` (macOS). |
| Container build fails | container | `docker builder prune -f`; retry. |
| OneCLI install fails | onecli | Check curl installed; verify ~/.local/bin writable. |
| Auth token rejected | auth | Re-paste; check Claude subscription active or API key valid. |
| Service fails to load | service | Check `logs/nanoclaw.log`; verify dist/ built successfully. |
| Socket unreachable | first-chat | Service may be crashing; check logs; `pnpm run chat` shows error. |
| Docker group stale | service (Linux) | Re-log in or `sudo setfacl -m u:$USER:rw /var/run/docker.sock`. |

---

## /setup Skill Entry Point

The `/setup` skill in Claude Code invokes NanoClaw setup steps via SSH-like syntax:

```typescript
// setup/index.ts lines 29–66
const STEPS: Record<string, () => Promise<{ run: (args: string[]) => Promise<void> }>> = {
  timezone, 'set-env', environment, container, register, 'pair-telegram', groups,
  'whatsapp-auth', 'signal-auth', mounts, service, verify, onecli, auth, 'cli-agent',
};

// Dispatches: pnpm exec tsx setup/index.ts --step <step> [args...]
```

Allows re-running individual steps after install, e.g.:
- `pnpm exec tsx setup/index.ts --step service` (re-generate & reload launchd/systemd).
- `pnpm exec tsx setup/index.ts --step timezone -- --tz America/New_York` (change timezone).
- `pnpm exec tsx setup/index.ts --step onecli --reuse` (reconnect to existing OneCLI).

---

## Summary

NanoClaw v2 install is a two-phase process:

1. **Bash bootstrap** (setup.sh): Node/pnpm/native modules, spinners with elapsed time.
2. **TS orchestrator** (setup:auto): 11 major steps (environment → container → onecli → auth → mounts → service → cli-agent → timezone → channel → verify), clack spinners, interactive prompts.

The service is installed as a **launchd agent** (macOS) or **systemd user/system unit** (Linux), with **per-checkout unique labels** so multiple installs can coexist. Database initialization is **implicit on first service boot** (migrations run automatically). All three output levels (user-facing, progression, raw logs) are implemented per the `docs/setup-flow.md` contract, ensuring debuggability and auditability.

**Entry points:** `bash nanoclaw.sh` (recommended UX), `bash setup.sh` (bootstrap-only), `/setup` skill (post-install admin).
