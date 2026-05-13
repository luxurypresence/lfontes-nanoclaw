# Test checklist

Five phases per QA run. Each phase ends with a GIF or screenshot capture and a console read. Stop conditions are listed inline.

## Phase 1 — Happy path

Walk the feature end-to-end exactly as the acceptance criteria describe. One pass, no edges.

- Navigate to the feature entry point.
- Take a baseline GIF starting before the first interaction.
- For each acceptance criterion, perform the action and observe the result.
- Record per-criterion outcome: pass / fail / partial.

Stop and ask if: the entry point isn't reachable, the feature isn't enabled for the test company, or required seed data is missing.

## Phase 2 — Edges

Stress the inputs and controls. Stay black-box.

- Empty / null: submit with required fields blank.
- Bounds: numeric fields with 0, negatives, max-int, decimals where integers are expected.
- Long input: paste 1,000 chars into text fields; 10,000 into long-form fields.
- Special chars: emoji, quotes, `<script>`, RTL, leading/trailing whitespace.
- Rapid clicks: double-submit a primary CTA; spam a toggle.
- Back/forward: browser back mid-flow; reload mid-flow.
- Concurrent: open the feature in a second tab; mutate in one, check the other.

Skip edges that don't apply (e.g. no inputs ⇒ skip empty/null). Record each surprising behavior; don't pre-filter as bugs vs not — triage in step 4 of the working loop.

## Phase 3 — Mobile viewport

Resize to 375×667 (iPhone 6/7/8 baseline) via `mcp__claude-in-chrome__resize_window`.

- Replay the happy path at narrow width.
- Check: anything overflowing, anything clipped, anything unreachable (hidden behind a fixed header, off-screen modals, untappable touch targets < 32px).
- Capture a mobile GIF of the happy path.
- Resize back to desktop before continuing.

`resize_window` may reject with "Bounds must be at least 50% within visible screen space" on high-DPI displays or constrained window managers. If that happens, record the limitation in the report's Mobile section and mark Phase 3 deferred — don't fight it.

Skip if the feature is explicitly desktop-only and the caller said so.

## Phase 4 — Console sweep

`mcp__claude-in-chrome__read_console_messages` with a pattern filter for `error|warning|failed`.

- Re-run the happy path with the console open.
- Capture every error, unhandled rejection, and failed network request that fires during the feature flow.
- Distinguish: errors that fire on every page (pre-existing, log but down-rank to minor) vs errors that fire because of feature interaction (file as feature bugs).

If the page is producing errors before any interaction, note "baseline console noise" once at the top of the bugs list and don't repeat per phase.

## Phase 5 — Final capture

One clean GIF of the happy path, no edges, no console panel. This is the artifact the report links from the verdict block — it's what a reader watches to understand what the feature looks like working.

## Harness fallbacks

- `mcp__claude-in-chrome__computer` with `action: type` can fail with "Cannot access a chrome-extension:// URL of different extension" when a browser extension (1Password, autofill) intercepts focus on the target input. Fall back to a JS-driven value set that fires a React-compatible input event:

  ```js
  const i = document.querySelector('input[placeholder="…"]');
  i.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(i, 'value to type');
  i.dispatchEvent(new Event('input', { bubbles: true }));
  ```

  React's controlled inputs watch the native setter; calling it via the prototype descriptor is what tricks React into picking up the change. Plain `i.value = '…'` doesn't.

- `mcp__claude-in-chrome__resize_window` constraint is documented under Phase 3.

## Triage

After all five phases:

- Critical — acceptance criterion fails, page crashes, data appears corrupted, console error halts the flow, security-sensitive (auth bypass, PII leak in URL).
- Major — flow completes but a documented sub-behavior is wrong, recoverable error users would hit, accessibility break (keyboard trap, missing focus).
- Minor — visual nit, copy typo, edge that's unlikely in practice, mobile-only layout glitch on a desktop-first feature.

One bug = one entry. Don't bundle "and also" into a single bug.
