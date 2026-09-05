<!-- doc-tier: human | canonical-for: cloud-ui-blueprint | budget: 8000tok -->

# Barkpark Cloud — UI Blueprint

The ratifiable plan for making the Cloud dashboard **one designed product**. Written
for a human to read and sign off before the wave-B rebuild. Charter decisions D56–D66
are law; AMENDMENTS 2+3 (coherence over capability; the novice is the persona; ease of
mind first) are the north star. Two items below are marked **RATIFY:** — they need a
human yes before the CSS/copy slices execute.

The verdict this plan answers: the capability spine works, but the product feels like
things were *added randomly*. Every defect below is a wrong route or a stray affordance
between pieces that already exist and are good. The fix is **fewer things, better
placed, quieter** — deletion and consolidation are first-class moves.

---

## 1. Screen inventory

Derived from the real router (`app.js:1073` `VIEWS`, `SETTINGS_VIEWS`, `DETAIL_VIEWS`;
`legacyRoute` at `app.js:1098`; sections in `index.html`). One line = what the screen is
**for**. If a screen has no single purpose, it is a merge/kill candidate (§2). All
file:line anchors in this doc are pinned to the tree at `dba334c2`; re-find by symbol
(`grep`), not line math, once later waves move app.js.

| Screen | Route | Purpose (one line) |
|---|---|---|
| Auth / login | pre-shell | The quality bar. Focused, restrained sign-in. Nothing else on the page. |
| Overview (home) | `#overview` | The operator's answer to "what needs me now?" — and, when empty, the **welcome runway** (§3). |
| Fleet | `#fleet`, `#fleet/<bucket>` | The list of Barkpark instances, attention-ranked; drill into one. |
| Sites | `#sites` | Connected front-ends (Vercel etc.) and their revalidation wiring. |
| Activity | `#activity` | The team's append-only audit log — "what happened, in order." |
| Launch | `#launch` | **KILL** (§2). A one-field form ranked equal to Fleet; becomes an *action*, not a place. |
| Settings · Billing | `#settings/billing` | Current plan + invoices. Read surface; purchase moves to the launch moment (§2). |
| Settings · Providers | `#settings/providers` | Bring-your-own-cloud credentials (advanced). |
| Settings · Notifications | `#settings/notifications` | Where alerts go. |
| Settings · Tokens | `#settings/tokens` | API tokens for `bp` / scripts. |
| Instance workspace | `#instance/<id>/<tab>` | One Barkpark's home. Sub-tabbed (D49): **Overview** (status, timeline, actions) + **Webhooks**. |
| Site detail | `#site/<id>` | One connected site: its instance link, revalidation status, redeploy. |

**Note on parity with the aspirational IA.** The arc's target IA also names Team and
Account in the settings cluster; today the cluster is Billing/Providers/Notifications/Tokens,
and Webhooks lives as an instance-workspace tab — exactly the two tabs D49's
registration rule admits (`INSTANCE_TABS`, `app.js:1085`). Team and Account are **not
built** — their future homes are in the parity ledger (§7), not invented here.

---

## 2. Kill / merge / move register

Each move carries its evidence and its executing wave. Nothing here is a new feature;
every line makes the whole quieter.

| # | Move | Evidence | Wave |
|---|---|---|---|
| K1 | **DELETE** `#view-launch` section | `index.html:219` — a one-field form ranked as a *place*. `legacyRoute`'s MAP (`app.js:1101`) today remaps only the four settings pages; A4 adds `launch` to it so the old bookmark lands on the flow, not a 404 | A4 |
| K2 | **DELETE** `onboardingCard()` (the Get-started card) + `startStep` | `app.js:1418–1427` (+ helper `app.js:2929`) — "Choose a plan" as step 1 **contradicts** the server's dwb-13 auto-trial (`go_live` starts the free trial). The first screen asks for money the server doesn't require | A4 |
| K3 | **DELETE** the decorative ⌘K search | `index.html:151–156` — `aria-hidden`, "coming soon". A dead affordance is a pixel of "added randomly." Restored for real by roadmap item 14's palette | A4 |
| K4 | **DELETE** duplicate red-italic "— provisioning failed" fleet-url lines | `app.js:1330` **and** `app.js:1660` — the pill is the single status voice; a second red line is a third idiom for one fact | B1 |
| M1 | **DEMOTE** SSE-interruption toasts → topbar presence dot | `app.js:3492` `toast({title:"Live updates interrupted"})` — a transient reconnect is not an event worth a modal; a quiet `aria-live` dot carries it | B1 |
| M2 | **REMOVE** Refresh buttons from SSE-live views | `index.html:212/299/312` (fleet, sites, activity) — an SSE-live surface that also offers Refresh admits it might be stale — it isn't | B1 |
| H1 | **HIDE** "No sites yet" (`app.js:1881`) + "Health Unknown / Agent Offline" rail rows (`app.js:1708–1731`) during provisioning | A box that isn't born yet must not raise alarms about itself; placeholders read "—" | A4 |
| V1 | **MOVE** plan purchase → the launch moment; **demote** Billing to a settings surface | Purchase belongs at intent, not as a nav peer (D66). Billing keeps plan-state + invoices | C |
| V2 | **MOVE** GitHub out of cloud Providers → Connections | GitHub is a connected account, not a compute provider; it sits in the wrong cluster (D66) | C |

---

## 3. The onboarding narrative

The centerpiece (AMENDMENT 2 rule 2, AMENDMENT 3 rule 3). A **numbered spec**, not a
form scattered across tabs. Every step reuses machinery that already exists and is good
(`provisionSteps` fold, `NEW_RETURN_KEY` re-entry, `newReadyHtml`); the work is *routing
them into one line*, per D56.

1. **Login → empty Overview = the welcome runway.** Full-width. One line of what a
   Barkpark *is* (novice copy, no jargon). **Exactly one** primary CTA. Runway copy is
   **conditional on `GET /v1/subscription`** (`loadSubscription`, `app.js:3339`) — never
   hardcoded "Choose a plan." Trial-aware (D57).
   > **RATIFY: trial CTA wording.** Proposed primary: **"Launch your first Barkpark"**;
   > sub-line when a trial is available: **"Your free trial is ready — no card needed."**
   > Free-tier framing is human-gated (D57).
2. **Launch flow (one flow, one launch component — D66).** Ask for a **name**. Render the
   plan step **inline only on a real `402`** from `POST /v1/launch` (the auto-trial means
   it usually won't). If checkout is needed, the round-trip returns **into the flow** via
   the `NEW_RETURN_KEY` pattern (`app.js:3710`) — never dumps the user on a fresh page.
3. **`201` routes to `#instance/<id>`.** The 201 body already carries `{barkpark:{id,…}}`
   (verified: `json(conn, 201, %{barkpark: barkpark_json(barkpark)})`, web/router.ex:4559),
   so no server change. This replaces the current `submitLaunch` behavior —
   `location.hash="#fleet"` + a toast (`app.js:3030–3035`) — which is the single worst
   re-orientation in the product.
4. **Provisioning watched live.** The already-Vercel-grade C3 timeline (`provisionSteps`,
   `app.js:3814`) ticks in place: step ladder, live elapsed clock, console fold.
5. **Verify-pass folds into a ready panel.** On the SSE ready event the timeline collapses
   into `newReadyHtml` (`app.js:4606`): "&lt;name&gt; is ready", **Open Studio** as the one
   primary button, **View instance** as a ghost.
6. **Open Studio.** The journey ends in content, not a dashboard.

**Measure (binding):** zero re-orientations from signup to Studio. No dead spinner, no
"Studio doesn't work after setup" (AMENDMENT 3 rule 4 — the verify gate proves ready
before declaring done).

---

## 4. Layout rules

| Rule | Value |
|---|---|
| Content column | max-width **~1140px**, centered; the runway (§3 step 1) is the one full-bleed exception |
| Spacing rhythm | **8px grid** — `--s1..--s8`; no raw px spacing literals (D64 ratchet) |
| Type scale | **5 steps**: 12 / 13 / 15 / 18 / 24 (`--fs-1..5`). **`tabular-nums`** on every duration, count, and elapsed clock so digits don't jitter |
| List densities | **exactly two.** Dense **log rows** (fleet, activity, deployments, timeline) and **feature cards** (onboarding, billing). No third density |
| Primary action | **one** black/primary button per screen. Everything else is ghost or link |

---

## 5. Color / status rules

| Rule | Detail |
|---|---|
| Semantic tokens | `--ok / --warn / --danger / --info` (`app.css:24–35`) carried by **the pill only** |
| One telling | status is told **once per row/header** — the pill. Detail is a quiet text line below it |
| Pill shape | role + a **≤3-word** label ("Provisioning", "Removal failed") |
| Raw provider strings | appear **only** in the timeline's fail/console fold — never in a pill, never on the home screen |
| Provider identity ≠ status | Provider colour (`--provider-hetzner` / `--provider-azure`, generated from `design/tokens.json` `color.provider`) is **identity only**. It may tint a **chip mark or a chip/row border** — **never a pill background**. The status roles above stay the sole state voice, so a Hetzner box and an Azure box that are both *live* read the SAME green pill and differ only by a provider chip. |
| Instance lifecycle | The seven instance states — `provisioning · live · degraded · stopped · archived · decommissioned · adopted` — each map to **one** status role (live→ok, degraded→warn, decommissioned→danger, provisioning/adopted→info, stopped/archived→neutral). The SPA tints its glyph through that role via the generated `.bp-inst--<state>` classes; the CLI/TUI paints the same seven from `GenInstanceLifecycle` (`internal/semrole/chrome_gen.go`) — one vocabulary, dual-emitted, so browser and terminal never diverge (`design/check.mjs` Part D gates it). |

> **RATIFY: accent (D59) — neutral primary in BOTH themes.** Light keeps the near-black
> primary (`--primary: hsl(240 5.9% 10%)`, `app.css:13`) — the login page is the ratified
> quality bar. Dark **adopts the mirror** (white-on-dark primary, Vercel-style), replacing
> today's `--primary: hsl(217.2 91.2% 59.8%)` (`app.css:72`) — which changes the product's
> most important color's *hue* at the theme toggle (shadcn residue, not a decision). The
> dark blue **demotes to `--info`/links** (it is already the `--info` hue, `app.css:27`).
> AA contrast-checked per consumer before B2 ships.

---

## 6. Copy voice

The novice persona (AMENDMENT 3 rule 1). **Jargon is a defect.**

| Rule | Do | Not |
|---|---|---|
| Case | sentence case, verbs first | Title Case Buttons |
| Failures | human sentences | raw codes |
| — example | "A capacity or quota limit was reached…" | `SERVER_LIMIT_EXCEEDED` |
| Time | relative ("2h ago"), absolute on hover | raw timestamps |
| Durations | "2h 1m" (`fmtDur` learns hours) | "121m 8s" (today's `fmtDur`, `app.js:3765`, caps at minutes) |
| Log vocabulary | "launched an instance" | `barkpark.launched` |

Human failure copy is threaded server-side through `FailureCopy` (exists) — provider-error
classes (quota/auth/dns/network) humanize at the JSON boundary (wave A5) so no surface ever
parses provider jargon.

---

## 7. Parity ledger

Honest Kinsta/Vercel gaps. **None built in this arc (D65).** Each names its future home in
the IA so a later panel can't rearrange today's coherence work.

| Gap (they have, we don't) | Future home in the IA | Status |
|---|---|---|
| Rollback / redeploy | Instance workspace → *Deployments* tab (D49) | parked (roadmap 11) |
| Custom domains UI | Instance workspace → *Domains* tab | parked (roadmap 12) |
| Env-vars UI | — | RULED OUT 2026-09-02 (cch-w53-bl) |
| Usage meters | Instance workspace → *Overview* tab (usage endpoint exists) | parked (roadmap 13) |
| Team members / roles | Settings → *Team* (cluster gains the entry) | parked (roadmap 13) |
| Account settings | Settings → *Account* (cluster gains the entry) | parked |
| Infrastructure (Hetzner) | Instance workspace → *Infrastructure* tab | parked (roadmap 8) |
| ⌘K palette + copy-as-CLI | Topbar (replaces the deleted K3 stub) | parked (roadmap 14) |

---

## Ratification checklist

- [ ] **RATIFY** §3 — trial CTA wording (free-tier framing, D57)
- [ ] **RATIFY** §5 — neutral accent in both themes (D59)
- [ ] Screen inventory (§1) and kill/merge/move register (§2) accepted

Once the two RATIFY items are signed, wave B's CSS (accent, type/spacing tokens) and the
copy sweep may execute. Until then, wave A ships the routing/consolidation (A4) and the
mechanical enforcement (A2 styleguide, A3 preview harness) that this plan governs.
