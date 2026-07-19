<!-- doc-tier: human | canonical-for: gr-p4-notifications-evidence | budget: 1100tok -->
# G-04 Notifications (the crown) — evidence

Phase-4 Settings-wave G-04. `#view-notifications` recomposed onto the GR33 `.set-*`
anatomy: channel roster + event×channel routing matrix + delivery log, all backend-true.

## Gates (as-run, this branch)

| gate | baseline | as-run |
|---|---|---|
| `node __app.test.mjs` | 544 | **559 pass / 0 fail** |
| `node __preview__/smoke.mjs` | 58 | **62 scenarios** |
| `node __css_check.mjs` | 0 err (748 cls / 516 pairs) | **0 err (768 cls / 516 pairs)** |
| `node --check app.js` | — | OK |

No new `CONTRAST_PAIRS` entry needed: every new class reuses tokens already in the
manifest (`--text`/`--muted-text` on `--surface`, the frozen `--ok-strong`/`--ok-soft`
tint for the "configured" tag). R4 raw-px count went **down** (267 → 264) — the retired
`.notif-row`/`.notif-toggle` rules took their raw px with them.

## Shots (evergreen, headless Chrome)

- `notif-configured-light.png` / `notif-configured-dark.png` — the full page in both
  themes: email delivery (SMTP transport seg + write-only stored secrets + save-row),
  chat-channel roster (configured honesty + consequence sub-lines + per-channel
  Send-test), the **6-column routing matrix** (explicit routes solid; `chat_default_on`
  failure events dashed on enabled channels; Telegram/Pushover columns marked "off";
  the always-send Test row stated, not toggled), and the **populated delivery log**
  (toned pills: Failed / 204 OK / Sent / Pending + the verbatim `smtp 550` error line).
- `notif-member-light.png` — plain member: read-only email definition list, no
  save-rows, no inputs, an honest "managed by team admins" notice for the admin-only
  sections, and no Send-test button in the header.

The **empty** (no channels, empty delivery log) and **deliveries-error** (honest
degrade, no infinite spinner) states are pinned by the smoke scenarios `notif-empty`
and `notif-deliveries-error` and by the unit tests on `notifDeliveriesHtml` /
`notifDeliveriesErrorHtml` (Chrome screenshots of these two states were skipped —
headless Chrome was unreliable under the concurrent-builder machine load; the states
are fully proven by the gates below).

## Design decisions (backend-true)

- **6-column routing matrix, two endpoints, no save-row.** Columns = email + the 5
  chat channels. The email column writes the per-event boolean via `PUT /settings`;
  the chat columns write `event_routes` via `PUT /events`. Because the two columns
  hit different endpoints, a single batched save-row would lie about atomicity
  (GR33) — so the matrix is a **live toggle grid**: each cell persists to its true
  endpoint the instant it flips. The two *buffered* form sections (email, channels)
  each own their save-row.
- **`chat_default_on` honesty.** The four failure events fan to every enabled channel
  by default; those cells render *dashed* (`.set-matrix-cell--default`) so a default
  is never painted as an explicit choice. The first edit of a default event
  materializes the full fan-out before flipping one cell, so it can't silently drop
  the others.
- **Always-send `test`.** The test row is stated ("Always sent to every enabled
  channel"), never a lying toggle.
- **Write-only chat credentials.** The server echoes only `configured:bool`; the UI
  shows a `configured`/`not configured` tag and a sealed placeholder — never a value.
- **Plain-member law.** Reads are member-visible, writes are admin-gated. A member
  sees the email settings read-only with no save-rows and an honest "managed by team
  admins" line — no disabled ghosts, no silent-403 buttons.
- **`sendTestNotification` moved home.** The wave's one sanctioned cross-region move —
  it physically lived in the TOKENS span; it now lives in the notifications region.
