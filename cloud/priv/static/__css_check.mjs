#!/usr/bin/env node
// __css_check.mjs — the SPA's design contract, machine-checked (epic charter
// decision 2: "A new __css_check.mjs validator (dead classes, undefined tokens)
// gates every SPA slice").
//
// ERRORS (exit 1):
//   E1  var(--x) consumed anywhere in app.css / app.js / index.html where --x
//       has no definition in app.css (a fallback does not excuse it — every
//       consumed token must be part of the contract).
//   E2  a class name emitted by index.html or an app.js template string /
//       classList call / className assignment that has no rule in app.css.
//       LITERAL CLASS TOKENS ONLY — attribute-driven state is out of scope by
//       technique; the boundary and its ruling are declared in full below.
//   E3  a dynamic class composition site in app.js (e.g. 'dot ' + kind) whose
//       static head is not explicitly allowlisted below — dynamic names cannot
//       be statically resolved, so every such site must be a conscious entry.
//       Static fragments in the dynamic TAIL (e.g. the " is-revoked" ternary
//       arm after the concat boundary) ARE extracted and E2-checked: inside
//       the attribute region, a double-quoted string starting with whitespace
//       is by construction a class fragment.
//   E4  a class token the checker cannot statically parse (e.g. a template
//       literal's ${...} inside class="..."). The extractor understands this
//       codebase's single-quoted concat style; anything else must fail loudly
//       here rather than ship unchecked — rewrite the site in concat style
//       (with an ALLOW_PREFIXES entry if dynamic).
//   E5  WCAG contrast (charter decision 28): every pair in CONTRAST_PAIRS —
//       a DECLARED manifest of the fg/bg token combinations the SPA actually
//       renders — is resolved for BOTH themes and must clear its threshold
//       (4.5:1 for text roles, 3:1 for non-text UI). Tune token values in the
//       app.css token blocks until green; never silence a pair.
//   E6  raw color literal in app.css outside the :root / [data-theme="dark"]
//       token blocks (was report R1; promoted to error per decision 28). The
//       conscious exceptions live in ALLOW_RAW_COLORS below — exact trimmed
//       lines, each with a reason; an edited line goes stale and fails until
//       re-ratified here.
//   E7  an external-host RESOURCE LOAD (link/script/img/@import/url(...)
//       pointing at http(s):// or //) in index.html, styleguide.html or
//       app.css — the console must render fully offline (decision 27).
//       Plain <a href> navigation links are deliberately allowed.
//   E8  scoped-theme alias leak: a token declared only in :root whose value
//       references a token the dark block re-themes. var() substitutes where
//       the property is DECLARED, so such an alias freezes the LIGHT value in
//       any subtree that scopes [data-theme="dark"] onto a non-root element
//       (the styleguide panes). Re-declare the alias in the dark block.
//   E9  swallowed declaration (parse-completeness, regression #4251): a `--x:`
//       the FLAT token scan trusts but the browser's `;`-delimited declaration
//       parse rejects inside a token block. A `*/` embedded in comment TEXT
//       (`… --ok*/ …`) ends the comment early, so the browser eats the garbage
//       that follows as one malformed declaration up to the next `;` — silently
//       dropping the real declaration that `;` belonged to (there,
//       `--btn-bg: var(--primary);`). The flat scan still "saw" `--btn-bg:`, so
//       the contract missed it. Fixture: __css_check.fixture.css; targeted run:
//       `node __css_check.mjs --swallow-check __css_check.fixture.css` (exit 1).
//   E10 orphan comment terminator (regression #4592/GR74): a `*/` reached while
//       NOT inside a comment. Its cause is always the same — a `/*` was lost, so
//       every line above the orphan is parsed as raw CSS, and CSS error recovery
//       discards tokens until the next `{…}` block, silently SWALLOWING the next
//       whole rule. Live case: app.css's GR63 modal comment lost the `/*` on its
//       REVIEW ADDENDUM paragraph, so `.modal-root { position: fixed; … }` never
//       reached the CSSOM and every modal in the console rendered in document
//       flow under a fixed backdrop. E9 could not see it (E9 is scoped to `--x:`
//       inside the three token blocks) and the app.test.mjs source-text
//       assertions could not either (they regex app.css as TEXT). The mirror
//       case — EOF reached while still inside a comment — is the same defect
//       from the other end and is reported too.
//       COVERAGE BOUNDARY (charter D40 — a check states what it does NOT own):
//       E10 owns the COMMENT-nesting class only. Unclosed `{` and stray `}` are
//       a DIFFERENT class and are NOT E10's: measured by mutation on app.css,
//       appending an unclosed `{` or a bare `}` leaves this whole file at exit
//       0 while the brace-depth walk in __app.test.mjs ("app.css is
//       BRACE-BALANCED") goes red; appending an orphan `*/` does the reverse.
//       The two instruments are therefore a DELIBERATE SPLIT, not a duplicate
//       — deleting either reopens a shipped defect class. Fixture:
//       __css_check.orphan.fixture.css; targeted run:
//       `node __css_check.mjs --orphan-check __css_check.orphan.fixture.css`
//       (exit 1). Both fixture proofs are executed by __app.test.mjs.
//   E11 banned source line-number citation (charter D41; bp-honest-gates D5):
//       any scanned SPA / preview-harness / STYLESHEET file (top-level
//       *.js|*.mjs|*.css + __preview__/*) citing `app.js:<line>` (also
//       `app.js ~<line>` or an `app.js:<a>-<b>` range). THE RULING is a BAN,
//       not a resolver: three separate blocks in one wave cited line numbers
//       that were wrong on arrival or wrong the moment a sibling slice shifted
//       the file +39 lines, so every live occurrence was ALREADY stale — there
//       is nothing correct for a line-resolving verifier to preserve, and that
//       verifier's own anchor heuristic would rot in turn (bp-honest-gates D5:
//       "ban the SHAPE, do not enumerate"). Re-anchor to the enclosing FUNCTION
//       name plus a grep. Cross-language `router.ex:<line>` cites are OUT — the
//       boundary is stated in full on bannedSourceCitationErrors below (filed
//       follow-up cch-bl-citation-drift-cross-language).
//   E12 translucent focus indicator (WCAG SC 1.4.11): a `:focus`/`:focus-visible`
//       rule whose SOLE indicator band — the outermost box-shadow layer, or the
//       painted `outline` — resolves to alpha < 1 in any theme state. E5 asserts
//       TOKEN pairs and cannot see which token a RULE consumes, so before this
//       check 19 focus rules painted a 1.19–1.52:1 band while E5 was green. A
//       rule carrying an opaque border-color is compliant (that border IS the
//       indicator); full predicate on focusIndicatorErrors below.
//   E13 an unpainted deployment status: a status in DEPLOY_STATUSES with no
//       `.dep-<status>` rule in app.css. The `dep-pill dep-` E3 allowlist waives
//       the whole dynamic head, so the emitted VALUE SPACE was unchecked and
//       `cancelled` shipped ruleless — falling through to the .dep-pill base,
//       which is byte-identical to .dep-queued, so an aborted deploy painted as
//       one still waiting. Full boundary on DEPLOY_STATUSES below.
//   E15 an unpainted DELIVERY TONE, and a stale consent for one. Same family as
//       E13 one surface over: `wh-del-status wh-del-status--` is an E3 allowlist
//       entry too, so the tone half was unmeasured. The value space is DERIVED
//       from `notifDeliveryTone()`'s returns in app.js and diffed against
//       WH_DEL_TONES, so a fifth tone reds here without anyone editing this file.
//       WH_DEL_BASE_TONES names the tones the neutral base pill really does paint
//       (`muted`, the withheld alert) — and a STALE entry there reds too, because
//       a consent that absolves nothing is the blind spot rebuilt inside the fix.
//   E16 an unpainted FRESHNESS DOT, and a deriver that went blind. Third in the
//       E13/E15 family: `fresh-badge fresh-badge--` is an E3 allowlist entry, so
//       the dot half was unmeasured and `.fresh-badge--unknown` — the dot the
//       `cancelled` arm and the unknown-status else arm both emit — shipped with
//       ZERO rules. It did not merely paint nothing: siteFreshnessSeg emits a
//       BARE `.fresh-badge` for "Not deployed to production", so a cancelled
//       deploy wore the never-deployed costume. The dot set is DERIVED from
//       freshnessModel's arms in app.js and diffed against FRESH_DOTS both ways.
//       DELIBERATELY NO CONSENT LIST, unlike E15's WH_DEL_BASE_TONES: the bare
//       base is a distinct SHIPPED state here, so "falls through to the base" is
//       never a treatment, it is an impersonation. Arm (d) pins that premise.
//   E17 a COLLAPSED citation scan set: citationScanFiles() returned nothing, or
//       lost a whole arm of its derivation (zero top-level members, zero
//       __preview__/ members, or this file missing from its own set). E11's
//       census is only as honest as the list it iterates, and an empty list
//       yields `0 error(s)` — a green from a scan that read NOTHING, byte-
//       identical to a green from a scan that read everything. The arms are
//       STRUCTURAL, never a pinned file list (D5: ban the shape, do not
//       enumerate). Print the derivation E17 guards with
//       `node __css_check.mjs --citation-inventory`, which also crosses the set
//       with the RULED alternation so the E11 widening's cost is a run, never a
//       quoted number.
//   E14 wrap-recipe DIVERGENCE (charter D220). THE INVARIANT, verbatim:
//
//         A rule whose selector is WRAPPER-SCOPED onto the pill
//         (`<wrapper> .status-pill` — one or more descendant/child steps then
//         `.status-pill`, and nothing after it) AND which declares AT LEAST ONE
//         of the five CORE properties must declare ALL FIVE, at the canonical
//         value: white-space: normal | height: auto | min-height: 24px |
//         padding-top: 2px | padding-bottom: 2px.
//
//       WHY AN INSTRUMENT AND NOT AN EXTRACTION. This epic hand-built the same
//       five-declaration wrap three times (`.detail-rail`, `.fleet-status`,
//       `.instance-card-head`). D210 ruled the third copy deliberate and made
//       THE FOURTH HOST the extraction trigger. Wave 19 reached the fourth host
//       and REFUSED the trigger, because driving it showed the axis was wrong:
//       the five-declaration recipe applied to `.op-gate` does NOT fix it (every
//       clipped cell stays clipped — it hides the symptom and leaves the label
//       unreadable), while ONE declaration, `.op-gate .status-pill { flex: 0 0
//       auto }`, is 64/64 at every width. Host COUNT is not the sin. DIVERGENCE
//       between the copies is, and nothing measured it. E14 measures it, so a
//       fourth copy that drifts from the shared core stops being possible.
//       THREE DESIGN CHOICES ARE LOAD-BEARING — each proven by a driven leg in
//       __app.test.mjs; do not "simplify" any of them:
//         1. TRIGGER ON DECLARATION, NOT ON SELECTOR. "every wrapper-scoped
//            `.status-pill` rule must carry the core" would false-red a future
//            `.foo .status-pill { margin-left: 4px }`. Triggering on
//            declares-any-core-property makes the rule SELF-SCOPING: start the
//            recipe and you must finish it; don't start it and E14 is silent.
//         2. DO NOT ASSERT THE JACKET. `align-items: flex-start` (2 of 3
//            copies), the `-dot`/`-detail`/`-label` sibling rules and the
//            wrapper's own `flex-wrap` are per-HOST. `.detail-rail` carries no
//            `align-items` and no `-dot`/`-detail` rules and must GREEN; a
//            jacketless synthetic fourth host must GREEN.
//         3. PIN THE CORE AS A LITERAL (WRAP_CORE below), never derive it as
//            the intersection of what the copies happen to declare — that is
//            self-fulfilling: a fourth copy dropping `min-height` would shrink
//            the intersection and pass.
//       THE BASE `.status-pill` IS EXCLUDED BY SELECTOR SHAPE, NOT BY AN
//       ALLOWLIST: it declares `height: 24px` and `white-space: nowrap` — core
//       PROPERTIES at non-core VALUES, by design. Requiring at least one
//       descendant/child combinator excludes it structurally, so the exclusion
//       cannot go stale when the base rule is renamed or moved.
//       TWO ANTI-VACUITY GUARDS, because a scan that stops seeing the copies
//       would otherwise report clean: zero wrapper-scoped copies is itself an
//       error, and the three known survivor selectors are PINNED as
//       required-present (same-file pins under pin-your-own/derive-foreign),
//       which closes the PARTIAL blindness the zero-guard misses.
//       COVERAGE BOUNDARY (charter D40 — a check states what it does NOT own):
//       E14 is STATIC and owns the DECLARATION-PARITY class ONLY.
//         • It cannot see whether a copy actually WRAPS when rendered. The host
//           needs `flex-wrap: wrap` on the WRAPPER; a copy with all five core
//           declarations inside a non-wrapping host is GREEN here and broken on
//           screen. The complement is overflow-guard.mjs's rendered legs — a
//           DELIBERATE SPLIT, not a duplicate.
//         • It cannot see a host that SHOULD have copied the recipe and did
//           not. Nothing static knows which wrappers hold a long-labelled pill.
//         • It asserts nothing about the base `.status-pill`, and nothing about
//           the jacket (see choice 2).
//         • It reads LONGHAND declarations only: a `padding: 2px 11px`
//           shorthand neither triggers E14 nor satisfies `padding-top`. The
//           three live copies are longhand and the canonical recipe is stated
//           in longhand; a shorthand copy is a shape this check does not see.
//       Fixture: __css_check.wrapparity.fixture.css; targeted run:
//       `node __css_check.mjs --wrap-parity-check
//       __css_check.wrapparity.fixture.css` (exit 1). Executed, both
//       directions, by __app.test.mjs.
//
// REPORTS (printed, never exit-affecting):
//   R2  tokens defined in app.css that nothing consumes yet.
//   R3  REPORT-ONLY: known violations whose fix would require editing app.js
//       (app.js is owned by another slice — leave, don't touch).
//   R4  raw px font-sizes in app.css rules outside the token blocks — the
//       type-scale migration backlog for the decision-24 sweep.
//
// ── E2 COVERAGE BOUNDARY (charter D40/D49) ──────────────────────────────────
// Declared because a gate that cannot see a whole class of defect must SAY so:
// an UNDECLARED boundary reads as coverage, and a reader who assumes "the class
// checker checks what the SPA puts on elements" is wrong in a way this file
// never told them.
//
//   WHAT E2 SEES. Exactly two extractors, both over double-quoted LITERALS:
//     /\.className\s*=\s*"([^"]*)"(\s*\+)?/g
//     /classList\.(?:add|remove|toggle)\(\s*"([^"]+)"/g
//   A class token has to be written out in the source to be checked at all.
//
//   WHAT E2 CANNOT SEE. `el.setAttribute("data-x", someVar)` — the attribute
//   NAME is a literal but the VALUE is a variable, and no regex over the call
//   site can enumerate what that variable holds. `el.dataset.x = v` is the same
//   defect in property form. So `[data-x="…"]` rules in app.css are, to E2,
//   neither emitted nor dead: they are invisible.
//
//   THE MEASURED POPULATION (five attribute-state writes, NOT the "three"
//   earlier recon claimed) — anchored to the enclosing FUNCTION, never a line
//   number (grep to re-derive: `grep -n 'setAttribute("data-' app.js`):
//     applyTheme()           documentElement.setAttribute("data-theme", t)
//     applyBpTheme()         documentElement.setAttribute("data-bp-theme", t)
//     coherenceStampTheme()  root.setAttribute("data-theme", theme)
//     coherenceStampTheme()  root.dataset.theme = theme   — same fn, DOM fallback
//     renderLivenessChip()   chip.setAttribute("data-state", state)
//   FOUR of the five are data-theme / data-bp-theme and are NOT an E2 gap —
//   E5 owns them. The contrast engine parses the `[data-theme="dark"]` and
//   `html[data-bp-theme="…"]` blocks straight out of app.css (parseTokenBlocks
//   and the identity-ramp scan below) and fans every theme x identity pair
//   through WCAG. Do not fold them into E2; that would double-own them.
//   ONE is genuinely E2-blind: `data-state` on the liveness chip, whose value
//   comes from liveDotState(). __preview__/cssom-parity.mjs does not cover it
//   either (`grep -c data-state __preview__/cssom-parity.mjs` → 0) and could
//   not in principle — it diffs authored CSS against the browser CSSOM and
//   never reads app.js.
//
//   THE RULING — E2 IS NOT EXTENDED TO ATTRIBUTE VALUES. Reaching a variable
//   attribute value is not a generalization of E2's technique: literal
//   extraction has no path there, so an attribute check added HERE would be a
//   parallel bolt-on with its own fragile function-body regex, carrying E2's
//   name without E2's method. The cheaper and stronger shape asserts over the
//   EMITTING FUNCTION instead, and it is already on main (#5377):
//     git show origin/main:cloud/priv/static/__app.test.mjs \
//       | grep -n 'carries a paint rule for EVERY chip state'
//     4713:test("liveness chip: app.css carries a paint rule for EVERY chip state", …
//   That test loops the REAL liveDotState return set against app.css, and its
//   sibling ("liveDotState: the return set is a CLOSED enum of exactly four
//   states") pins the set itself, so a fifth state cannot slip past unpainted.
//   Hence no check is added here and no second test is added there — that pair
//   would be duplicate coverage of the identical liveDotState/app.css seam.
//
//   KNOWN GRANULARITY LIMIT — CLOSED (D41/D66). The original HEAD fence proved
//   SELECTOR-PREFIX PRESENCE in app.css TEXT, not per-property survival: deleting
//   ONLY `.live-chip[data-state="stale"] .live-dot { background: … }` (app.css:3470)
//   while the same-prefix `.live-chip-label` rule on :3471 survived red NEITHER
//   check, so a state could lose its DOT colour — its one severity signal —
//   silently. That gap is now closed by a PER-DECLARATION probe in __app.test.mjs:
//   the test `every state's .live-dot rule DECLARES a background (per-declaration
//   fence)` loops hooks.liveDotStates, isolates each state's OWN `.live-dot {…}`
//   block (first-occurrence indexOf over the ` .live-dot {` marker, which skips the
//   `.live-dot.is-ping::after` decoy and the @media duplicate), and asserts a
//   `background:` declaration survives INSIDE it — so a background-ONLY deletion
//   reds as well as a whole-rule deletion. Mutation-proved: deleting app.css:3470
//   reds it with `no .live-dot paint rule for the "stale" state … falls back to
//   var(--dim)` while the prefix fence stayed green. __css_check itself is
//   UNCHANGED and still never reads data-state — that E2 boundary declared above
//   stands; the closure lives in the app.js/app.css-paired test, not here.
//
// Zero dependencies. Run: node __css_check.mjs

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));
// REFUSAL IS NOT A FINDING. Every sibling in this instrument family
// (__reason_arm_census, __me_envelope_census, __agent_event_vocabulary_census,
// __unknown_census, __binding_census) exits 2 when it cannot read its input,
// and the console-harness verdict wrapper maps 2→REFUSED / 1→MEASURED_DEFECT.
// This file's reads used to throw raw (uncaught ENOENT → exit 1), which
// reported "the tree has a measured defect" when the truth was "the instrument
// could not read its input". Exit 2 here, with the file named — a checker that
// cannot see its inputs must make NO claim about the tree, in either direction.
const readOrRefuse = (abs, label) => {
  try {
    return fs.readFileSync(abs, "utf8");
  } catch (e) {
    console.error(`FAIL(2): required input ${label} not readable at ${abs} — ${e.message}`);
    console.error("REFUSED (2): __css_check will not report a result it could not measure.");
    process.exit(2);
  }
};
const read = (f) => readOrRefuse(path.join(dir, f), f);

// ── Allowlists — every entry is printed on every run so the list stays honest ─

// Exact static head (the text before the first concat boundary) of each KNOWN
// dynamic class composition site in app.js. Seeded by inspecting the actual
// sites; a new dynamic site fails E3 until it is consciously added here.
const ALLOW_PREFIXES = [
  "toast toast-",      // showToast(): kind ∈ success | error | info
  "choice-ico ",       // provider picker tile: + p.cls (brand-hetzner | brand-do | brand-aws | brand-vultr)
  "choice-ico sm ",    // provider row mini-tile: + m.cls (same brand-* set)
  "token-row",         // token row (GR33 lean line item, no longer a .fleet-row): + (revoked ? " is-revoked" : "")
  "dot ",              // badge(): + esc(kind) (up | down | unknown | online | offline | warn)
  "dep-pill dep-",     // deployment status pill: + esc(st) — the value space is NOT this comment's; it is DEPLOY_STATUSES below, and E13 checks it
  "deploy-fail",       // deploy-fail row: + (failureTone === "blocked" ? " deploy-fail--blocked" : "")
  "deploy-console",    // + (open ? "" : " is-collapsed")
  "tier",              // + " tier-current" / " tier-free" conditionals
  "auth-tab",          // /new auth tabs: + (mode ? " is-active" : "")
  "new-console",       // + (collapsed ? " is-collapsed" : "")
  "new-step ",         // + cls (done | active | failed)
  "status-pill status-pill--", // statusPill(): + role (ok | info | warn | danger | neutral)
  "rollup-card rollup-card--",  // rollupCard(): + bucket (attention | inflight | healthy)
  "bp-tl-step bp-tl-step--",    // timelineHtml(): + role (ok | active | failed | pending)
  "bp-console",                 // timelineConsoleHtml(): + (collapsed ? " is-collapsed" : "")
  "inst-tab",                   // instanceTabStripHtml(): + (on ? " is-active" : "")
  "wh-del-status wh-del-status--", // delivery status pill: + tone — the value space is NOT this comment's; it is WH_DEL_TONES below, and E15 checks it
  "tlv-badge tlv-badge--",      // tlvRowHtml(): + variant (event | verify | verify-fail | audit)
  "vf-chip vf-chip--",          // verifyChipHtml(): + role (pass | fail | unknown)
  "usage-card usage-card--",    // usageMeterHtml(): + rowTone (warn | over)
  // gr-w1 (cloud GUI remake): dynamic sites whose composed classes all have
  // rules in app.css today — verified via `.<family>` grep before allowing.
  "inst-life-pill ",            // instanceLifecyclePill(): + model.pill.cls (.inst-life-pill rule)
  "inst-life-note",             // + (retry ? " inst-life-note--warn" : "") (.inst-life-note[--warn])
  "notice",                     // fleetRolloutBannerHtml(): + NOTICE_TONE_CLASS[tone] (.notice / .notice-ok|warn|error)
  "deploy-rail-status deploy-rail-status--", // + esc(st.tone) (.deploy-rail-status-- rules)
  "dep-current",                // + (rolledBack ? " dep-current--restored" : "") (.dep-current[--restored])
  "prov-overall",               // + state (.prov-overall rules)
  "usage-bar usage-bar--",      // + d.bar.tone (.usage-bar-- rules)
  "metric-card metric--",       // + esc(m.role) (.metric-card / .metric-- rules)
  "cmdk-row",                   // + (active ? " is-active" : "") (.cmdk-row / .is-active)
  // gr-w3 (v4 shell): the sidebar instance-morph section links (paintInstanceSections)
  "nav-link nav-sub",           // + (on ? " is-active" : "") (.sidebar .nav-link / .nav-sub / .is-active)
  // gr-p2 HOME TRIAGE (C-01/C-02): the v4 Overview's composed classes, each with
  // a rule in app.css (verified via `.<family>` grep).
  "instance-card instance-card--", // instanceCardHtml(): + statusOf role (.instance-card / .instance-card-- rules)
  "instance-card-spark spark--",   // + statusOf role (.instance-card-spark / .spark-- rules)
  "instance-card-stat-v",          // + (warn ? " is-warn" : "") (.instance-card-stat-v / .is-warn)
  "runway-step",                   // runwayCardHtml(): + (done ? " is-done" : "") (.runway-step / .is-done)
  // gr-p3 SITE DETAIL (E-02): the v4 domain-checklist rung pill.
  "dom-rung dom-rung--",           // domainRungChip(): + role (ok | failed | active | pending | proxied) (.dom-rung / .dom-rung-- rules)
  // gr-p5r5-css-families: the three var-then-concat sites rewritten to inline
  // concat, so the walker finally reads a literal head instead of "". These were
  // never missing CSS — every composed class below has had a rule all along; the
  // `var cls = …` form simply hid the site from the static walker.
  "set-matrix-cell",               // notifMatrixCellHtml(): + (isDefault ? " set-matrix-cell--default" : "")
  "fresh-badge fresh-badge--",     // freshnessBadge(): + m.dot — the value space is NOT this comment's; it is FRESH_DOTS below, and E16 checks it (+ optional " is-rebuilding")
  "usage-bar-quota",               // usageMeterHtml(): + (tone === "ok" ? " dim" : "") (.usage-bar-quota / .dim)
  // cch-w26-s5: promoted OUT of KNOWN_GAPS. The demotion's stated reason —
  // "the suffix set comes from fixture text" — is REFUTED by the emitter.
  // coherenceFixtureToHtml() (grep -n 'function coherenceFixtureToHtml' app.js)
  // replaces on `/\b(info|warn|ok|danger)\b/g`: a CLOSED four-way alternation
  // written in CODE. The fixture only chooses among the four the regex already
  // names; it cannot introduce a fifth. `bp-lc-hex` is a SEPARATE literal head
  // in the same function, not a capture. All five composable classes have rules
  // (grep -n 'bp-lc' app.css). So this head is MORE bounded than most entries
  // above, whose closed sets live only in a trailing comment. The closed-ness
  // itself is pinned by a leg that can lose in __app.test.mjs (role-adjacent
  // words outside the set emit no bp-lc- span) — widening the alternation reds
  // that test, which an allowlist entry alone could never do.
  "bp-lc-",                        // coherenceFixtureToHtml(): + captured role word (info | warn | ok | danger) — closed alternation in code
];

// ── E13: the .dep-* VALUE SPACE, derived instead of described ───────────────
// The `dep-pill dep-` entry above is an E3 allowlist: it waives the whole
// dynamic head, so before this list existed NOTHING checked which suffixes the
// head can actually take. The comment on that entry claimed five statuses and
// the server has six — `cancelled` shipped with no rule at all and fell through
// to the .dep-pill base, which is byte-identical to .dep-queued, so a terminal
// abort painted as "still waiting". A comment cannot fail; this list can.
//
// THE SOURCE OF TRUTH is Ecto: BarkparkCloud.Registry.Deployment's @statuses
// (grep: `grep -n '@statuses' cloud/lib/barkpark_cloud/registry/deployment.ex`
// — verified at review; the module and path both resolve, which is the point of
// citing them at all).
// It is COMMITTED here rather than parsed out of the .ex file on purpose — this
// checker is a zero-dependency static reader of three static assets and must not
// grow a cross-language parser (E11's cross-language boundary, same reasoning).
// The cost of the copy is that a SEVENTH server status lands here unnoticed; the
// mitigation is that adding a status to the Ecto enum without adding it here is
// the same review that must add the CSS rule anyway, and app.js emits
// `dep-` + esc(st) for whatever the server sends, so the omission is visible the
// first time that status renders.
//
// WHAT E13 OWNS: every status in this list has SOME rule in app.css whose
// selector names `.dep-<status>` (grouped selectors count — `.dep-building,
// .dep-pushing {…}` satisfies both). WHAT IT DOES NOT OWN: whether that rule
// says anything DISTINCT. A rule that only re-states the base would pass here;
// what stops that is CONTRAST_PAIRS plus the driven computed-style proof in the
// slice's evidence, not this check.
// cch-w64-s6: "deferred" added — the enum this list claims to mirror
// (registry/deployment.ex) carries SEVEN values, and the missing word is why the
// check called `.dep-deferred`'s total ABSENCE of a rule green while the raw
// status rode into the DOM. The word alone REDS origin/main (E13, naming
// `.dep-deferred`), so it co-merges with the rule in the same commit — a
// deliberate guard+fix co-merge, not a guard weakened to fit.
const DEPLOY_STATUSES = ["queued", "building", "pushing", "live", "failed", "cancelled", "deferred"];

// The `wh-del-status--` VALUE SPACE, mirroring DEPLOY_STATUSES above and checked
// by E15. `"wh-del-status wh-del-status--"` is an ALLOW_PREFIXES entry, which
// waives the whole dynamic head — so before E15 the tone half of that class was
// unmeasured, exactly the hole that let `.dep-cancelled` ship ruleless and paint
// a terminal abort as "still waiting". The delivery log repeats the shape: a
// WITHHELD alert that falls through to an unintended tone tells a team admin the
// opposite of what happened.
//
// This list is not hand-trusted: E15 also DERIVES the tones `notifDeliveryTone()`
// actually returns out of app.js and asserts the two sets are equal, so adding a
// fifth tone in app.js reds here even if the author never reads this file.
const WH_DEL_TONES = ["ok", "danger", "info", "muted"];

// The tones deliberately painted by the BASE `.wh-del-status` pill, with no rule
// of their own. `muted` is the shipped example: a withheld alert is neither in
// flight nor a transport failure, and the neutral base pill IS its treatment, so
// a `--muted` rule would only be a copy that can drift from the base.
//
// This is a CONSENT list and it is held to the consent doctrine: E15 reds on a
// STALE entry too — a tone named here that has grown a rule, or that
// `notifDeliveryTone()` no longer emits, is a consent absolving nothing, which is
// how a consent list quietly becomes the new blind spot.
const WH_DEL_BASE_TONES = ["muted"];

// The tones `notifDeliveryTone()` in app.js actually returns. Derived, never
// enumerated: an enumerated list is the tones somebody REMEMBERED.
function emittedDeliveryTones(js) {
  const start = js.indexOf("function notifDeliveryTone(");
  if (start === -1) return null;
  let depth = 0;
  let i = js.indexOf("{", start);
  if (i === -1) return null;
  const open = i;
  for (; i < js.length; i++) {
    if (js[i] === "{") depth++;
    else if (js[i] === "}" && --depth === 0) break;
  }
  if (depth !== 0) return null;
  const body = js.slice(open, i);
  const tones = new Set();
  for (const m of body.matchAll(/return\s+"([a-z][a-z0-9-]*)"/g)) tones.add(m[1]);
  return tones;
}

// ── E16: the .fresh-badge-- DOT SET, derived instead of described ───────────
// `"fresh-badge fresh-badge--"` in ALLOW_PREFIXES waives the dynamic head, and
// until now the only statement about what the head composes was that entry's own
// trailing comment — which named FOUR dots (up | down | deploy | rebuild) while
// freshnessModel has always had a fifth arm. `cancelled` emits dot "unknown", the
// generic else emits "unknown" for any status this client has not learned, and
// `.fresh-badge--unknown` had no rule at all. An instrument that reports green
// over its own subject is the shape this list exists to end, so the set below is
// only a DECLARATION: emittedFreshnessDots() reads the arms and E16 reds if the
// two disagree in EITHER direction.
//
// NO CONSENT LIST — and that is a decision, not an omission. E15's
// WH_DEL_BASE_TONES lets a tone name the neutral base pill as its real treatment.
// That option is unavailable here: siteFreshnessSeg (grep -n "function
// siteFreshnessSeg" app.js) deliberately emits a BARE `class="fresh-badge"` for a
// site that has NEVER deployed, so the base look is already spoken for. A dot
// that falls through to it does not read as neutral, it reads as "never deployed"
// — the same impersonation .dep-cancelled committed against .dep-queued, which is
// why E13 exists. E16 arm (d) asserts that premise still holds, so the day the
// bare-base badge is removed this reasoning is re-opened instead of rotting.
const FRESH_DOTS = ["up", "down", "deploy", "rebuild", "unknown"];

// The dots freshnessModel actually assigns. Derived, never enumerated. Returns
// null when the function cannot be located or brace-matched, and reports the
// assignment COUNT alongside the literals so a `dot = someVar` arm this reader
// cannot follow is a hard error rather than a silently shorter set — an empty
// scan is not a clean scan.
function emittedFreshnessDots(js) {
  const start = js.indexOf("function freshnessModel(");
  if (start === -1) return null;
  let i = js.indexOf("{", start);
  if (i === -1) return null;
  const open = i;
  let depth = 0;
  for (; i < js.length; i++) {
    if (js[i] === "{") depth++;
    else if (js[i] === "}" && --depth === 0) break;
  }
  if (depth !== 0) return null;
  const body = js.slice(open, i);
  const dots = new Set();
  let literal = 0;
  for (const m of body.matchAll(/\bdot\s*=\s*"([a-z][a-z0-9-]*)"/g)) {
    dots.add(m[1]);
    literal++;
  }
  const assigns = [...body.matchAll(/\bdot\s*=(?!=)/g)].length;
  return { dots, literal, assigns };
}

// Classes that intentionally have no style rule: they are JS/structural hooks
// (selector targets, event delegation markers), not visual classes. Each is
// printed on every run; removing the hook from the markup should remove the
// entry too.
const ALLOW_HOOK_CLASSES = [
  "view",              // section container app.js shows/hides per route ($$(".view"))
  "modal-body",        // openModal() innerHTML target (selected by #modal-body)
  "session-revoke",    // querySelectorAll(".session-revoke") — revoke button in the sessions panel
  "notif-smtp",        // querySelector(".notif-smtp") — SMTP fieldset container in notifications
  "token-revoke",      // querySelectorAll(".token-revoke[data-id]") — per-token revoke button
  "token-ab",          // querySelectorAll(".token-ab") — ability checkboxes in the new-token modal
  "fleet-open-studio", // querySelectorAll(".fleet-open-studio") — Open Studio button per fleet row
  "new-plan",          // querySelectorAll(".new-plan") — plan-choice buttons on the /new pricing step
  "wh-event-cb",       // querySelectorAll(".wh-event-cb") — event checkboxes in the create-webhook modal
  "launch-region",     // querySelector(".launch-region") — region <select>, styled by .form-input; S7 change hook
  "launch-connect-provider", // querySelector(".launch-connect-provider") — connect CTA, styled by .btn; S7 click hook
  "launch-catalog-retry",    // querySelector(".launch-catalog-retry") — retry button, styled by .btn; S7 click hook
];

// R3 / KNOWN_GAPS — genuine E2/E3 violations that live in app.js and index.html,
// NOT in this epic's owned files. This checker is CI-wired by gr-w1-styleguide-port
// (console-harness.yml) and MUST exit 0; app.js/index.html are owned by other
// slices ("leave, don't touch"), and their real fix — author the CSS or remove the
// emission — is tracked by task gr-backlog-css-check-missing-classes. Each entry
// DEMOTES its exact hard-fail to an R3 report line so the gate stays green while
// the gap stays visible on every run. Keyed by {file, cls} (E2) or {file, head}
// (E3) — line-INDEPENDENT so app.js churn never re-reds the gate; a genuinely NEW
// missing class (different name) or dynamic head still hard-fails. An entry that
// matches nothing prints `stale` (prune it — the owning slice fixed it). NOTHING
// in styleguide.html or the app.css token blocks may be listed here: this epic
// owns those, so their drift MUST hard-fail.
const KNOWN_GAPS = [
  // gr-p5r5-css-families retired EIGHT of the nine entries that stood here: the
  // six family E2s (all six now have authored rules in app.css), the phantom
  // "notice-" E2 (fleetRolloutBannerHtml now emits whole class names), and the
  // E3 head:"" entry (all THREE var-then-concat sites — notifMatrixCellHtml,
  // freshnessBadge and usageMeterHtml's quota trailer — are inline-concat now).
  // cch-w26-s5 retired the LAST entry — the E3 `bp-lc-` head. It was demoted on
  // the stated reason that "the composed suffix is a REGEX CAPTURE from an
  // arbitrary committed fixture file, so the closed role set is an assumption
  // about that file's contents rather than a property of this code." That reason
  // is false against the emitter: coherenceFixtureToHtml() in app.js replaces on
  // a CLOSED four-way alternation `/\b(info|warn|ok|danger)\b/g` written in code
  // (grep -n 'function coherenceFixtureToHtml' app.js), so the fixture selects
  // among four and cannot introduce a fifth. It is now an ALLOW_PREFIXES member,
  // with the closed-ness pinned by a test that reds if the alternation widens.
  //
  // THE LIST IS NOW EMPTY, AND THAT IS THE POINT: the checker no longer exits 0
  // by having been told to ignore a row it attributes to an open backlog task.
  // Whatever lands here next must carry an owner and a way out, not a waiver.
];

// E6 — the conscious raw-color exceptions (decision 28). EXACT trimmed line
// text as it appears in app.css (comments stripped); each entry carries its
// reason and is printed on every run. Editing the line invalidates the entry.
const ALLOW_RAW_COLORS = [
  { line: ".modal-backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.5); backdrop-filter: blur(2px); }", why: "scrim — theme-invariant by design (GR63: fixed, so it stays over the viewport while a tall modal scrolls)" },
  { line: "color: #fff; font-weight: 700; font-size: 13px;", why: "white initials on the fixed provider brand tiles" },
  // .brand-hetzner + .brand-azure now tint from --provider-* tokens (S7) — no raw literal to allow.
  { line: ".brand-do { background: #0080ff; }", why: "DigitalOcean brand colour" },
  { line: ".brand-aws { background: #232f3e; }", why: "AWS brand colour" },
  { line: ".brand-vultr { background: #007bfc; }", why: "Vultr brand colour" },
  { line: "background: rgba(127, 127, 127, 0.12);", why: "hue-neutral token-chip tint, works in both themes" },
  { line: ".btn-vercel { background: #000; color: #fff; border-color: #000; }", why: "Vercel brand button" },
  { line: ".btn-vercel:hover { background: #111; text-decoration: none; }", why: "Vercel brand button hover" },
  { line: '[data-theme="dark"] .btn-vercel { background: #fff; color: #000; border-color: #fff; }', why: "Vercel brand button (dark)" },
  { line: '[data-theme="dark"] .btn-vercel:hover { background: #eee; }', why: "Vercel brand button hover (dark)" },
  { line: "-webkit-mask: radial-gradient(farthest-side, transparent calc(100% - 3px), #000 calc(100% - 2.5px));", why: "mask ALPHA channel (opaque = keep), not a rendered colour — theme-invariant ring cutout" },
  { line: "mask: radial-gradient(farthest-side, transparent calc(100% - 3px), #000 calc(100% - 2.5px));", why: "mask ALPHA channel (opaque = keep), not a rendered colour — theme-invariant ring cutout" },
];

// E5 — THE contrast manifest (decision 28). Each entry is a fg/bg pairing the
// SPA really renders; `over` names the surface a translucent bg composites
// onto first. min 4.5 = text, min 3 = non-text UI (dots, borders, glyphs).
// Both themes are checked. Add a pair when a new component pairs tokens;
// removing one requires removing the component that renders it.
const CONTRAST_PAIRS = [
  { fg: "--text", bg: "--bg", min: 4.5, why: "body copy" },
  { fg: "--text", bg: "--surface", min: 4.5, why: "copy on cards" },
  { fg: "--text", bg: "--muted-surface", min: 4.5, why: "copy on muted/hover rows" },
  { fg: "--muted-text", bg: "--bg", min: 4.5, why: "secondary copy" },
  { fg: "--muted-text", bg: "--surface", min: 4.5, why: "secondary copy on cards" },
  { fg: "--dim", bg: "--bg", min: 4.5, why: "tertiary copy (.dim)" },
  { fg: "--dim", bg: "--muted-surface", min: 4.5, why: "tertiary copy on muted" },
  { fg: "--dim", bg: "--surface", min: 4.5, why: ".dep-cancelled pill text — the chip is hollow (background: transparent), so its label composites straight onto the .deploys card" },
  { fg: "--primary-fg", bg: "--primary", min: 4.5, why: "avatar label / step dots" },
  { fg: "--btn-fg", bg: "--btn-bg", min: 4.5, why: ".btn-primary label" },
  { fg: "--btn-danger-fg", bg: "--btn-danger-bg", min: 4.5, why: ".btn-danger label" },
  { fg: "--primary", bg: "--bg", min: 4.5, why: "links" },
  { fg: "--primary", bg: "--surface", min: 4.5, why: "links on cards" },
  { fg: "--ok", bg: "--surface", min: 4.5, why: "success text (.plan-rec, .new-eyebrow.ok)" },
  { fg: "--ok-strong", bg: "--ok-soft", over: "--surface", min: 4.5, why: ".runway-sub trial chip (green=accent: strong text voice on the soft tint, GR6)" },
  { fg: "--danger", bg: "--surface", min: 4.5, why: "error text (.deploy-fail, .wh-del-err)" },
  { fg: "--danger", bg: "--danger-soft", over: "--surface", min: 4.5, why: ".dep-failed pill text" },
  { fg: "--warn-strong", bg: "--warn-soft", over: "--surface", min: 4.5, why: ".dep-building pill text" },
  // cch-w64-s6: `.dep-deferred` keeps the warn hue but gives up the filled chip
  // (it no longer holds a build slot), so its ground is the CARD itself — the
  // one pair the tinted variant would not have owed.
  { fg: "--warn-strong", bg: "--surface", min: 4.5, why: ".dep-deferred pill text on an open chip" },
  { fg: "--text", bg: "--ok-soft", over: "--surface", min: 4.5, why: ".notice-ok copy" },
  { fg: "--text", bg: "--warn-soft", over: "--surface", min: 4.5, why: ".notice-warn copy" },
  { fg: "--text", bg: "--danger-soft", over: "--surface", min: 4.5, why: ".notice-error copy" },
  { fg: "--console-fg", bg: "--console-bg", min: 4.5, why: "console lines" },
  { fg: "--console-dim", bg: "--console-bg", min: 4.5, why: "console timestamps" },
  { fg: "--ok", bg: "--muted-surface", min: 3, why: "ok status dot on badge" },
  { fg: "--warn", bg: "--muted-surface", min: 3, why: "warn status dot on badge" },
  { fg: "--danger", bg: "--muted-surface", min: 3, why: "danger status dot" },
  { fg: "--info", bg: "--surface", min: 3, why: "active-step ring / probe dot" },
  { fg: "--cc-amber", bg: "--surface", min: 3, why: "branch-preview amber edge (--accent retired, reads --cc-amber directly)" },
  // The focus ring (SC 1.4.11, min 3:1) against EVERY backdrop a focusable
  // control actually sits on — --bg alone was the wrong backdrop for seven
  // consumers: the three sidebar controls (.ws-switch/.nav-find/.nav-account)
  // spacer against --cc-bg-side, and the card-embedded ones (.copy-btn,
  // .site-inst-link, .site-open, .actfilter-chip) paint straight onto the
  // card / hover-row / modal with no opaque spacer at all. These fan over all
  // theme states; E12 below is what ties them to the rules that consume them.
  { fg: "--ring", bg: "--bg", min: 3, why: "focus ring on the page backdrop (.btn, .scope-switch spacer)" },
  { fg: "--ring", bg: "--surface", min: 3, why: "focus ring on cards (.copy-btn, .site-inst-link, .site-open)" },
  { fg: "--ring", bg: "--muted-surface", min: 3, why: "focus ring on muted/hover rows (.actfilter-chip)" },
  { fg: "--ring", bg: "--cc-bg-side", min: 3, why: "focus ring in the sidebar (.ws-switch, .nav-find, .nav-account spacer)" },
  { fg: "--ring", bg: "--cc-modal", min: 3, why: "focus ring inside modals (.modal-x, .btn in modal footers)" },
  { fg: "--primary-fg", bg: "--ok", min: 4.5, why: ".badge-current text / toast-success glyph / done step-dot" },
  { fg: "--primary-fg", bg: "--danger", min: 4.5, why: "toast-error glyph / failed step-dot" },
  { fg: "--primary-fg", bg: "--muted-text", min: 3, why: "toast-info icon glyph" },
  // Cloud-console families (charter azure-hetzner S4). instanceLifecycle glyph
  // tones read THROUGH a status role; the only role not already paired on
  // --surface is --warn (degraded). Provider IDENTITY marks (--provider-*) are
  // non-text tints on a card surface (dot/border), so 3:1.
  { fg: "--warn", bg: "--surface", min: 3, why: ".bp-inst--degraded glyph tone" },
  { fg: "--provider-hetzner", bg: "--surface", min: 3, why: "Hetzner identity mark / chip border" },
  { fg: "--provider-azure", bg: "--surface", min: 3, why: "Azure identity mark / chip border" },
  // ── The living styleguide's cloudChrome text/UI pairs (gr-w1-styleguide-port).
  // These mirror the agency spec's own 17-row contrast table (section 03), now
  // machine-computed here instead of at render time. The cloudChrome family is
  // identity-INVARIANT (GR2), so these resolve identically across all theme
  // states, but they pin the raw designer hexes the swatch grid renders. fg4 is
  // the meta-only token duty-capped at 3:1 (GR6: --dim maps to fg3, never fg4 as
  // text). The accent pairs (--primary) fan per identity — the styleguide's
  // section 03 spells them out; the base link/label pairs above already gate them.
  { fg: "--cc-fg", bg: "--cc-bg", min: 4.5, why: "styleguide 03: primary text (fg on bg)" },
  { fg: "--cc-fg2", bg: "--cc-card", min: 4.5, why: "styleguide 03: row text on cards (fg2 on card)" },
  { fg: "--cc-fg3", bg: "--cc-bg", min: 4.5, why: "styleguide 03: secondary copy (fg3 on bg)" },
  { fg: "--cc-fg4", bg: "--cc-bg", min: 3, why: "styleguide 03: meta only — fg4 on bg, duty-capped ≥3:1 (GR6)" },
  { fg: "--cc-blue", bg: "--cc-bg", min: 4.5, why: "styleguide 03: links (blue on bg)" },
  { fg: "--cc-amber", bg: "--cc-bg", min: 4.5, why: "styleguide 03: warning text (amber on bg)" },
  { fg: "--cc-red", bg: "--cc-bg", min: 4.5, why: "styleguide 03: danger text (red on bg)" },
  { fg: "--primary", bg: "--cc-bg", min: 3, why: "styleguide 03: accent badge/UI (primary on bg) — fans per identity" },
  { fg: "--primary-fg", bg: "--primary", min: 4.5, why: "styleguide 03: button label on the accent (primary-fg on primary)" },
];

// ── Read the tree ────────────────────────────────────────────────────────────

const cssRaw = read("app.css");
const jsRaw = read("app.js");
const htmlRaw = read("index.html");
const styleguideRaw = read("styleguide.html"); // the living spec — required (decision 27)

const stripCssComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
const css = stripCssComments(cssRaw);

const lineOf = (src, index) => src.slice(0, index).split("\n").length;

// ── E9: parse-completeness guard (swallowed declarations, regression #4251) ──
// definedTokens (below) scans the comment-stripped text with a FLAT `--x:`
// regex, so a declaration the BROWSER dropped can still register as "defined".
// #4251: a `*/` inside comment TEXT (`… --ok*/ …`) ended the GR7 comment early;
// the parser then consumed garbage up to the next `;`, swallowing the real
// `--btn-bg: var(--primary);` — every light .btn-primary rendered invisible, yet
// the checker was green. This guard compares the FLAT view against a proper
// `;`-delimited declaration parse (what the browser actually keeps): a `--x:`
// the flat scan sees but the declaration parse rejects = swallowed = E9.
// stripCssComments blanks comments to SPACES (byte-preserving), so a legitimate
// `--x:` written inside a comment vanishes here and never false-fires.
// `label` names the file actually scanned. It defaults to "app.css" (the main
// run's only subject) but MUST be passed by --swallow-check: a diagnostic that
// cites a file it never read is the very thing this checker exists to catch.
export function swallowedTokenErrors(cssRawText, label = "app.css") {
  const stripped = stripCssComments(cssRawText);
  const lineAt = (i) => stripped.slice(0, i).split("\n").length;
  // Bare token blocks only — :root, [data-theme="dark"], and the identity ramps
  // html[data-bp-theme="X"](…[data-theme="dark"]) — carry `--x:` custom-property
  // declarations at column 0. Component rules deeper in the file set real CSS
  // properties, not the custom props this swallow analysis is about.
  const BLOCK_RES = [
    /^:root\s*\{([\s\S]*?)\}/gm,
    /^\[data-theme="dark"\]\s*\{([\s\S]*?)\}/gm,
    /^html\[data-bp-theme="[a-z0-9-]+"\](?:\[data-theme="dark"\])?\s*\{([\s\S]*?)\}/gm,
  ];
  const errs = [];
  const seen = new Set(); // one E9 per (token, line) across the three regexes
  for (const re of BLOCK_RES) {
    for (const m of stripped.matchAll(re)) {
      const body = m[1];
      const bodyStart = m.index + m[0].indexOf("{") + 1;
      // VALIDATED — the browser's view: a `;` segment is a real custom property
      // only when the text before its first `:` is exactly `--name`.
      const validated = new Set();
      for (const seg of body.split(";")) {
        const c = seg.indexOf(":");
        if (c === -1) continue;
        const lhs = seg.slice(0, c);
        if (/^\s*--[A-Za-z0-9_-]+\s*$/.test(lhs)) validated.add(lhs.trim());
      }
      // FLAT — definedTokens' view: every `--x:` the flat regex would trust.
      for (const d of body.matchAll(/(?:^|[{;\s])(--[A-Za-z0-9_-]+)\s*:/g)) {
        const tok = d[1];
        if (validated.has(tok)) continue;
        const ln = lineAt(bodyStart + d.index);
        const key = `${tok}@${ln}`;
        if (seen.has(key)) continue;
        seen.add(key);
        errs.push(
          `E9 ${label}:${ln}  ${tok}: reads as a declaration to the flat token scan but the ` +
            `browser's ;-delimited parse rejects it — an early-terminated comment ` +
            `(a '*/' inside comment text, e.g. '… --ok*/ …') likely swallowed it (#4251)`,
        );
      }
    }
  }
  return errs;
}

// ── E10: orphan comment terminator (rule-swallow guard, regression #4592) ────
// E9 answers "did a mis-closed comment eat a custom property inside a token
// block?". E10 answers the strictly larger question the browser actually asks
// first: "is this file's comment nesting even coherent?". A `*/` met outside a
// comment proves a `/*` went missing above it; the browser then parsed that
// prose as CSS and, per error recovery, threw tokens away until the next `{…}`
// — i.e. it ATE the following rule whole. That is invisible to every
// source-text check, because the bytes are all still there.
//
// Deliberately NOT a "does this prelude look like a selector?" heuristic: that
// was prototyped and measured 15 false positives on a clean app.css (descendant
// selectors ending in ` a`, keyframe `50%` stops). Comment-state is exact.
//
// The walk is a single state machine over {code, comment, string} because that
// is what a CSS tokenizer is: quotes are inert inside a comment (`browser's`
// must not open a string) and comment markers are inert inside a string
// (`content: "*/"` is text, not a terminator). A newline ends an unterminated
// string, matching the tokenizer's bad-string recovery.
export function orphanCommentErrors(cssRawText, file = "app.css") {
  const errs = [];
  let line = 1;
  let commentStart = 0; // line the open `/*` sits on, 0 when not in a comment
  let quote = ""; // "" outside a string, else the opening quote character
  for (let i = 0; i < cssRawText.length; i++) {
    const c = cssRawText[i];
    if (c === "\n") {
      line++;
      quote = ""; // CSS: a newline terminates a bad string
      continue;
    }
    if (quote) {
      // An escaped char is consumed whole. CSS permits a backslash-escaped
      // NEWLINE as a string continuation, so count it or every line number
      // below such a string drifts.
      if (c === "\\") {
        if (cssRawText[i + 1] === "\n") line++;
        i++;
      } else if (c === quote) quote = "";
      continue;
    }
    if (commentStart) {
      if (c === "*" && cssRawText[i + 1] === "/") {
        commentStart = 0;
        i++;
      }
      continue;
    }
    if (c === '"' || c === "'") quote = c;
    else if (c === "/" && cssRawText[i + 1] === "*") {
      commentStart = line;
      i++;
    } else if (c === "*" && cssRawText[i + 1] === "/") {
      errs.push(
        `E10 ${file}:${line}  orphan '*/' outside any comment — the matching '/*' is ` +
          `missing, so every line above this was parsed as raw CSS and error recovery ` +
          `discarded tokens up to the next '{…}', swallowing the rule that follows (#4592)`,
      );
      i++;
    }
  }
  if (commentStart) {
    errs.push(
      `E10 ${file}:${commentStart}  comment opened here is never closed — EOF reached ` +
        `inside it, so every rule below this line is invisible to the browser`,
    );
  }
  return errs;
}

// ── E14: wrap-recipe declaration parity (charter D220) ───────────────────────
// The full ruling, the three load-bearing design choices and the coverage
// boundary are stated in the E14 entry of this file's header. What follows is
// the executable form of that invariant — the durable artifact.
//
// THE CORE, PINNED AS A LITERAL (design choice 3). Deriving it from the copies
// would let a fourth copy dropping a property redefine the contract.
const WRAP_CORE = [
  ["white-space", "normal"],
  ["height", "auto"],
  ["min-height", "24px"],
  ["padding-top", "2px"],
  ["padding-bottom", "2px"],
];
// The three copies that survived wave 18, pinned as REQUIRED-PRESENT. A
// same-file pin is the correct form here (pin-your-own, derive-foreign): it
// closes the PARTIAL-blindness case the zero-copies guard cannot see — a scan
// that degrades to finding 1 of 3 still reports "clean" without this.
// W20-S6 added `.attention-row` as the FOURTH copy and it is pinned here in the
// same commit. Without this line the fourth copy was COUNTED but not
// REQUIRED — a scan degrading to 3-of-4 that lost exactly the attention
// queue's copy would still have reported clean, which is the partial
// blindness these pins exist to close.
const WRAP_REQUIRED_HOSTS = [".attention-row", ".detail-rail", ".fleet-status", ".instance-card-head"];
// WRAPPER-SCOPED: one or more descendant/child steps, then `.status-pill`, and
// NOTHING after it. The trailing anchor keeps `.detail-rail .status-pill-label`
// and `.status-pill--ok .status-pill-dot` out; requiring a leading step keeps
// the BASE `.status-pill` out structurally rather than by allowlist.
const WRAPPER_SCOPED_PILL = /^\s*(\S[^{}]*?)[\s>]+\.status-pill\s*$/;

export function wrapParityErrors(cssRawText, file = "app.css") {
  const stripped = stripCssComments(cssRawText);
  const errs = [];
  const copies = []; // { selector, host, line, declared: Map }
  // Innermost `{…}` blocks only: a prelude cannot contain a brace, so an
  // `@media` wrapper never matches as a selector and its inner rules do.
  for (const m of stripped.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const prelude = m[1];
    const body = m[2];
    const declared = new Map();
    for (const seg of body.split(";")) {
      const c = seg.indexOf(":");
      if (c === -1) continue;
      const prop = seg.slice(0, c).trim().toLowerCase();
      if (!/^[a-z-]+$/.test(prop)) continue;
      declared.set(prop, seg.slice(c + 1).trim().replace(/\s*!important$/, ""));
    }
    // DESIGN CHOICE 1 — the trigger is the DECLARATION, not the selector. A
    // wrapper-scoped rule that touches none of the five is not a wrap copy and
    // is not even counted.
    if (!WRAP_CORE.some(([p]) => declared.has(p))) continue;
    for (const part of prelude.split(",")) {
      const hit = part.match(WRAPPER_SCOPED_PILL);
      if (!hit) continue;
      const selector = part.trim().replace(/\s+/g, " ");
      const line = lineOf(stripped, m.index + prelude.indexOf(part.replace(/^\s+/, "")));
      copies.push({ selector, host: hit[1].trim().replace(/\s+/g, " "), line, declared });
      const missing = WRAP_CORE.filter(([p, v]) => declared.get(p) !== v).map(
        ([p, v]) => `${p}: ${v} (${declared.has(p) ? `declared "${declared.get(p)}"` : "not declared"})`,
      );
      if (missing.length) {
        errs.push(
          `E14 ${file}:${line}  ${selector} declares ${WRAP_CORE.filter(([p]) => declared.has(p))
            .map(([p]) => p)
            .join(", ")} — starting the wrap recipe — but DIVERGES from the shared core: ` +
            `${missing.join("; ")}. A wrapper-scoped .status-pill rule that declares ANY of the five ` +
            `must declare ALL five at the canonical value (white-space: normal; height: auto; ` +
            `min-height: 24px; padding-top: 2px; padding-bottom: 2px) — charter D220. The jacket ` +
            `(align-items, the -dot/-detail rules, the wrapper's flex-wrap) is per-host and is NOT asserted.`,
        );
      }
    }
  }
  // ANTI-VACUITY 1 — zero copies is a broken scan, not a clean stylesheet.
  if (!copies.length) {
    errs.push(
      `E14 ${file}  ZERO wrapper-scoped .status-pill wrap copies found — a vacuous green. ` +
        `This check exists because three such copies ship; seeing none means the scan stopped ` +
        `seeing them (a selector shape changed, a parse broke), not that they agree.`,
    );
  }
  // ANTI-VACUITY 2 — a scan degrading to 1-of-3 also reports clean without this.
  for (const host of WRAP_REQUIRED_HOSTS) {
    if (!copies.some((c) => c.host === host)) {
      errs.push(
        `E14 ${file}  the pinned wrap copy \`${host} .status-pill\` is MISSING — either the copy ` +
          `was deleted (a shipped wrap regression) or the scan can no longer see it (partial ` +
          `blindness). Re-derive by grep before editing this pin.`,
      );
    }
  }
  return { errors: errs, copies };
}

// ── E11: banned source line-number citation (charter D41; bp-honest-gates D5) ─
// THE RULING — a BAN, not a resolver. Argued from maintenance cost and from the
// three measured occurrences, not taste: (a) every live `app.js:<line>` was
// ALREADY stale (a +39-line sibling shift moved all five in the block above onto
// unrelated code), so a line-resolving verifier has nothing correct to preserve
// and would ship green over the exact drift it exists to catch; (b) such a
// verifier needs an "does the cited line still look right?" anchor heuristic
// that itself rots — negative maintenance; (c) the ban is one regex with zero
// per-citation upkeep (bp-honest-gates D5: "ban the SHAPE, do not enumerate").
// The re-anchor convention it enforces — enclosing FUNCTION name + a grep —
// survives any sibling shift a line number cannot.
//
// SCANS THE WHOLE SOURCE TEXT, not a comment subset. A comment-only walk was
// prototyped and REJECTED: a {string, //, /* */} state machine over 893 KB of
// app.js (template literals, regex literals) desyncs and MISSES real citations
// — a false-negative in a tripwire, the exact disease this epic removes. Full
// text cannot desync and cannot miss a citation that migrates into a string.
// The shape `app.js:<digits>` is citation-specific: measured on this tree every
// one of the seven live occurrences is a comment citation, zero are in code, so
// full-text scanning is both robust AND false-positive-free today.
//
//   COVERAGE BOUNDARY (charter D40 — an enforcement mechanism states its limits):
//     • CROSS-LANGUAGE `router.ex:<line>` cites are OUT. Re-anchoring a JS
//       comment that points at Elixir source means grepping the .ex file — a
//       distinct move filed as cch-bl-citation-drift-cross-language. E11 flags
//       only the same-repo `app.js:` shape; `router.ex:<line>` stays UNFLAGGED
//       here by design (live on this tree: __app.test.mjs + two app.js comments).
//     • SHAPE-SCOPED. Only `app.js:<digits>` (also `app.js ~<n>` / a range) is a
//       citation to E11. A prose reference like "the app.js file" is untouched;
//       a NON-numeric anchor (a function name + grep) is exactly what it asks
//       for. It cannot judge whether a cited function name is itself correct —
//       that is a semantic claim no regex owns.
export function bannedSourceCitationErrors(src, file) {
  const errs = [];
  const CITATION = /\bapp\.js[:~ ]+~?\d{2,}(?:-\d{2,})?/g;
  for (const m of src.matchAll(CITATION)) {
    const line = src.slice(0, m.index).split("\n").length;
    errs.push(
      `E11 ${file}:${line}  banned source line citation ${JSON.stringify(m[0].trim())} — ` +
        `line numbers rot on any sibling shift (charter D41 / bp-honest-gates D5). ` +
        `Re-anchor to the enclosing FUNCTION name + a grep that re-derives it ` +
        `(e.g. renderLivenessChip() with grep -n 'function renderLivenessChip'). ` +
        `Cross-language router.ex cites are OUT (cch-bl-citation-drift-cross-language).`,
    );
  }
  return errs;
}

// The files E11 scans: every top-level *.js|*.mjs|*.css plus __preview__/* of
// the same extensions. Read from the directory (never a hardcoded list) so a
// NEW harness file is covered the moment it lands — a fixed list is the
// enumerate-don't-ban shape bp-honest-gates D5 forbids.
//
// WHY .css IS IN THE SET, AND WHY THE REGEX IS NOT THE LEVER (charter D292).
// This scan read `/\.m?js$/` only — 15 files, and app.css was not one of them —
// while app.css carried THREE live `app.js:<n>` citations and the gate reported
// `0 error(s)`. The guard was green over a violation of the rule it enforces.
// The defect was REACH, not SHAPE: an `app.js:<n>` inside a stylesheet is
// unreachable at ANY regex width, so widening the CITATION pattern could not
// have found it. Paired mutation that pins the diagnosis: the identical string
// pasted into a scanned .mjs reds by name, and removed returns exit 0 — same
// string, one file away, opposite outcomes.
//
// THE OTHER HALF IS DELIBERATELY NOT HERE. Widening the CITATION alternation
// (cross-file `<name>.<ext>:<line>` shapes) surfaces 72 findings across the
// existing scan set; shipping a tripwire together with 72 repairs reds the
// fail-before gate, so that half stays on its own row,
// cch-w16-s7-citation-anchors-e11-widening. This function widens the FILE SET
// only, which surfaced exactly three — all repaired in the same commit that
// widened it, which is why the widened guard is green here rather than vacuous.
//
// SCOPE OF THE EXTENSION, stated so the next reader does not have to measure:
// the .css members of this set are app.css plus the three __css_check fixture
// stylesheets. The fixtures are deliberately malformed CSS, but E11 is a
// full-TEXT regex and never parses, so their content cannot destabilise it —
// they are scanned for citations exactly like everything else. Re-derive the
// membership with `node __css_check.mjs --citation-inventory` — the mode below
// PRINTS the set this function returns, where the `ls` recipe it replaced was a
// second implementation of the filter that could drift from the real one
// unseen.
//
// THE `root` PARAMETER EXISTS SO THE E17 REFUSALS BELOW CAN BE DRIVEN. The gate
// always calls this with no argument, i.e. against this file's own directory;
// --citation-inventory accepts an optional root so __app.test.mjs can point the
// same derivation at a directory where the set legitimately collapses and watch
// it refuse. A guard whose failure arm no test can reach is a guard nobody has
// ever seen fire.
function citationScanFiles(root = dir) {
  const out = [];
  const scanned = (f) => /\.(m?js|css)$/.test(f);
  if (!fs.existsSync(root)) return out;
  for (const f of fs.readdirSync(root)) if (scanned(f)) out.push(f);
  const pv = path.join(root, "__preview__");
  if (fs.existsSync(pv)) for (const f of fs.readdirSync(pv)) if (scanned(f)) out.push(path.join("__preview__", f));
  return out.sort();
}

// E17 — THE SCAN SET IS A CLAIM, AND NOTHING CHECKED IT (charter D41 /
// bp-honest-gates D5). citationScanFiles() derives its list from two readdir
// calls and one extension filter, and ALL THREE can silently produce nothing: a
// renamed or moved `__preview__/`, an extension pattern edited to a shape no
// file matches, a scan rooted somewhere else. E11 then iterates an empty list
// and the gate prints its clean census — a green from a scan that read NOTHING
// is byte-identical to a green from a scan that read everything. That is the
// vacuous-instrument shape this whole file exists to forbid, sitting inside the
// file itself. E17 turns each collapse mode into a NAMED, non-zero failure.
//
// WHY STRUCTURAL ARMS AND NOT A PINNED FILE LIST. An inventory of expected
// member names is exactly the enumerate-don't-ban shape D5 forbids: it rots the
// day a new harness file lands, and each stale entry teaches the next reader to
// widen the list rather than fix the derivation. These arms instead assert that
// each ARM OF THE DERIVATION produced something, and that the gate's own file is
// inside its own set — the comment above has CLAIMED "Scans this file too, so
// its own citations cannot go stale unseen" since the widening landed, and
// nothing asserted it. The self-membership arm applies only to the real root: it
// is a claim about THIS tree and means nothing about a directory the inventory
// mode was merely pointed at.
function citationScanSetRefusals(files, root = dir) {
  const out = [];
  if (!files.length) {
    return [
      `E17 ${root}  citation scan set is EMPTY — E11 would have reported a clean census over ` +
        `ZERO files. Either the scan root does not exist, or the extension filter in ` +
        `citationScanFiles() now matches nothing. A green over an empty set is not a green.`,
    ];
  }
  const PV = "__preview__" + path.sep;
  if (!files.some((f) => !f.startsWith(PV)))
    out.push(
      `E17 ${root}  citation scan set has ZERO top-level members — the top-level readdir arm ` +
        `of citationScanFiles() collapsed, so app.css / app.js / every top-level harness file ` +
        `went unscanned while E11 still reported a count.`,
    );
  if (!files.some((f) => f.startsWith(PV)))
    out.push(
      `E17 ${root}  citation scan set has ZERO __preview__/ members — the preview-harness arm ` +
        `of citationScanFiles() collapsed (a moved or renamed directory reads here exactly like ` +
        `a clean one). Re-derive with: node __css_check.mjs --citation-inventory`,
    );
  const self = path.basename(fileURLToPath(import.meta.url));
  if (root === dir && !files.includes(self))
    out.push(
      `E17 ${root}  citation scan set does not contain ${self} itself — the file's own claim ` +
        `("Scans this file too, so its own citations cannot go stale unseen") is false, and ` +
        `every citation in the gate's own comments is unmeasured.`,
    );
  return out;
}

// THE RULED ALTERNATION — the widened citation shape ruled by charter D201 and
// carried by cch-w16-s7. IT IS DELIBERATELY NOT WHAT E11 ENFORCES TODAY: E11
// bans `app.js:<line>` only (see bannedSourceCitationErrors above), and that
// shape has ZERO live hits on this tree, so the SHIPPED gate currently catches
// nothing. The ruled alternation is what E11 would ban AFTER the widening —
// loose separator for the `app.js` branch (the form the shipped gate already
// catches, and which the "prescribed" tight-everywhere regex would have
// dropped), tight `(?::~?|\s~)` for every widened target so that prose like
// "the app.css 273 raw px font-size lines" and the sidecar's `app.css <bytes> B`
// records stay clean.
//
// IT LIVES HERE, NOT IN A TASK ROW, BECAUSE EVERY QUOTED FIGURE FOR IT HAS
// ROTTED. The widening's cost has been recorded as 8, then 14, then 16/18, then
// 19, then 20 — five numbers, each true the day it was written and false by the
// next merge. --citation-inventory emits the figure as a RUN instead, so the
// only way to cite it is to re-derive it.
const CITATION_RULED_ALTERNATION = /\b(?:app\.js[:~ ]+~?|(?:app\.css|[\w.-]+\.(?:js|mjs|sh))(?::~?|\s~))\d{2,}(?:-\d{2,})?/g;

// Targeted fixture mode: `node __css_check.mjs --swallow-check <file.css>` runs
// ONLY the E9 parse-completeness guard against one file and exits non-zero if it
// fires — the committed #4251 regression proof (see __css_check.fixture.css).
{
  const i = process.argv.indexOf("--swallow-check");
  if (i !== -1) {
    const f = process.argv[i + 1];
    const errs = swallowedTokenErrors(readOrRefuse(f, f), path.basename(f));
    for (const e of errs) console.error("FAIL  " + e);
    console.log(`__css_check --swallow-check ${f}: ${errs.length} E9 error(s)`);
    process.exit(errs.length ? 1 : 0);
  }
}

// Targeted fixture mode: `node __css_check.mjs --orphan-check <file.css>` runs
// ONLY the E10 comment-nesting walk against one file and exits non-zero if it
// fires — the committed #4592/GR74 regression proof (see
// __css_check.orphan.fixture.css). Symmetric with --swallow-check above and
// added for the same reason: orphanCommentErrors had no fixture and no way to
// be run against one, so its green on app.css was unfalsified. Both fixture
// proofs are executed by __app.test.mjs, which console-harness already runs —
// a regression fixture nobody runs is an instrument that cannot fail.
{
  const i = process.argv.indexOf("--orphan-check");
  if (i !== -1) {
    const f = process.argv[i + 1];
    const errs = orphanCommentErrors(readOrRefuse(f, f), path.basename(f));
    for (const e of errs) console.error("FAIL  " + e);
    console.log(`__css_check --orphan-check ${f}: ${errs.length} E10 error(s)`);
    process.exit(errs.length ? 1 : 0);
  }
}

// Targeted fixture mode: `node __css_check.mjs --wrap-parity-check <file.css>`
// runs ONLY the E14 wrap-recipe parity scan against one file and exits non-zero
// if it fires — the committed D220 proof (see __css_check.wrapparity.fixture.css).
// Symmetric with --swallow-check and --orphan-check above, and added for the
// same reason they were: an instrument with no way to be run against a known-bad
// input is an instrument that cannot fail. Per E9's own lesson, every diagnostic
// below cites the file it ACTUALLY read, never a hard-coded app.css.
{
  const i = process.argv.indexOf("--wrap-parity-check");
  if (i !== -1) {
    const f = process.argv[i + 1];
    const { errors: errs, copies } = wrapParityErrors(readOrRefuse(f, f), path.basename(f));
    for (const e of errs) console.error("FAIL  " + e);
    console.log(
      `__css_check --wrap-parity-check ${f}: ${copies.length} wrapper-scoped wrap copy(ies) ` +
        `[${copies.map((c) => `${c.selector}:${c.line}`).join(", ")}], ${errs.length} E14 error(s)`,
    );
    process.exit(errs.length ? 1 : 0);
  }
}

// Inventory mode: `node __css_check.mjs --citation-inventory [root]` prints the
// citation scan set CROSSED WITH the ruled alternation — every file
// citationScanFiles() actually reads, each one's SHIPPED-E11 hit count and its
// RULED-alternation hit count, and the matched text with the line it sits on —
// then exits. Symmetric with --swallow-check / --orphan-check /
// --wrap-parity-check above, and placed here for the same structural reason
// they are: it must run BEFORE the gate body.
//
// WHY A SUB-MODE AND NOT AN EXPORT. `citationScanFiles` was a bare unexported
// function, and this file has no main guard of any kind — the gate runs during
// MODULE EVALUATION and ends in process.exit(). So a consumer that `import`s
// this module to derive the inventory (a) has the whole gate's stdout dumped
// over its own output and (b) NEVER GETS CONTROL BACK when the gate is red —
// which is precisely the moment the inventory is wanted, because the widening
// commit reds the gate by construction. Exporting the function alone would have
// been a trap that works only while the gate is green. The sub-mode is immune to
// the gate's exit status by construction, and is spawnSync-able.
//
// WHAT THE TWO COLUMNS BUY. `ruled` is what E11 would flag after the widening;
// `E11` is what it flags today. Their DIFFERENCE is the widening's real cost,
// measured at the moment you ask rather than quoted from a row — and on this
// tree the shipped column is ZERO everywhere, so the whole ruled figure is work
// the widening creates, not a backlog it inherits.
{
  const i = process.argv.indexOf("--citation-inventory");
  if (i !== -1) {
    const next = process.argv[i + 1];
    const root = next && !next.startsWith("--") ? path.resolve(next) : dir;
    const files = citationScanFiles(root);
    const refusals = citationScanSetRefusals(files, root);
    const PV = "__preview__" + path.sep;
    let shippedTotal = 0;
    let ruledTotal = 0;
    console.log(`__css_check --citation-inventory ${root}`);
    for (const rel of files) {
      const src = readOrRefuse(path.join(root, rel), rel);
      const shipped = bannedSourceCitationErrors(src, rel).length;
      const hits = [...src.matchAll(CITATION_RULED_ALTERNATION)];
      shippedTotal += shipped;
      ruledTotal += hits.length;
      console.log(
        `  ruled=${String(hits.length).padStart(3)}  E11=${String(shipped).padStart(3)}  ${rel}`,
      );
      for (const m of hits) console.log(`        ${rel}:${lineOf(src, m.index)}  ${JSON.stringify(m[0].trim())}`);
    }
    for (const e of refusals) console.error("FAIL  " + e);
    console.log(
      `__css_check --citation-inventory ${root}: ${files.length} file(s) scanned ` +
        `(${files.filter((f) => !f.startsWith(PV)).length} top-level, ` +
        `${files.filter((f) => f.startsWith(PV)).length} __preview__/), ` +
        `${shippedTotal} shipped-E11 hit(s), ${ruledTotal} ruled-alternation hit(s), ` +
        `${refusals.length} E17 refusal(s)`,
    );
    process.exit(refusals.length ? 1 : 0);
  }
}

// ── app.css: defined tokens, consumed tokens, defined classes ───────────────

const definedTokens = new Set();
for (const m of css.matchAll(/(?:^|[{;\s])(--[A-Za-z0-9_-]+)\s*:/g)) definedTokens.add(m[1]);
// @property --x { … } registers a custom property just as a `--x:` declaration
// does (the animated conic-ring fill --p at app.css:1717). The name is followed
// by `{`, not `:`, so the declaration scan above misses it — register it here.
for (const m of css.matchAll(/@property\s+(--[A-Za-z0-9_-]+)/g)) definedTokens.add(m[1]);

/** var(--x) consumption sites across all three files. */
function consumedTokens(src, file) {
  const out = [];
  for (const m of src.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)/g)) {
    out.push({ token: m[1], file, line: lineOf(src, m.index) });
  }
  return out;
}
// styleguide.html may DEFINE page-local --sg-* tokens in its own <style> block
// (checked below); everything else it consumes must come from app.css.
const sgLocalTokens = new Set();
for (const m of styleguideRaw.matchAll(/(?:^|[{;\s])(--[A-Za-z0-9_-]+)\s*:/g)) sgLocalTokens.add(m[1]);

// styleguide.html also DEFINES page-local .sg-* chrome classes in its own <style>
// (layout scaffolding for the spec — the not-yet-shipped grammars like the stage
// ladder, coalesced rows and domain rungs render on these, not on app.css
// component classes). Collect them the same way app.css classes are collected so
// the E2 pass can exempt them while still checking every SHIPPED-component class
// the styleguide demonstrates (.btn/.status-pill/.notice/.toast/…) against
// app.css — that is the drift value of folding styleguide.html into E2.
const sgStyle = (styleguideRaw.match(/<style>([\s\S]*?)<\/style>/) || [, ""])[1];
const sgLocalClasses = new Set();
{
  const sgCss = stripCssComments(sgStyle);
  let buf = "";
  for (const c of sgCss) {
    if (c === "{") {
      for (const m of buf.matchAll(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/g)) sgLocalClasses.add(m[1]);
      buf = "";
    } else if (c === "}" || c === ";") buf = "";
    else buf += c;
  }
}

const consumed = [
  ...consumedTokens(css, "app.css"),
  ...consumedTokens(jsRaw, "app.js"),
  ...consumedTokens(htmlRaw, "index.html"),
  ...consumedTokens(styleguideRaw, "styleguide.html").filter((c) => !sgLocalTokens.has(c.token)),
];

// Selector text = whatever precedes a "{" (declaration bodies are cleared at
// ";" and "}", so property values never leak in). Handles @media nesting.
const cssClasses = new Set();
{
  let buf = "";
  for (const c of css) {
    if (c === "{") {
      for (const m of buf.matchAll(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/g)) cssClasses.add(m[1]);
      buf = "";
    } else if (c === "}" || c === ";") buf = "";
    else buf += c;
  }
}

// ── index.html + app.js: emitted classes ────────────────────────────────────

const CLASS_TOKEN = /^-?[A-Za-z_][A-Za-z0-9_-]*$/;
const emitted = []; // { cls, file, line }
const dynamicSites = []; // { head, file, line }
const allowlistedHits = [];
const badTokens = []; // { tok, file, line } — statically unparseable (E4)

function emitToken(t, file, line) {
  if (!t) return;
  if (CLASS_TOKEN.test(t)) emitted.push({ cls: t, file, line });
  else badTokens.push({ tok: t, file, line });
}

/** Static class="..." attributes (HTML source — no dynamic parts). */
for (const m of htmlRaw.matchAll(/class="([^"]*)"/g)) {
  const line = lineOf(htmlRaw, m.index);
  for (const t of m[1].split(/\s+/).filter(Boolean)) {
    emitToken(t, "index.html", line);
  }
}

/** styleguide.html static class="..." attributes — the living spec renders the
 *  shipped components, so every class it names must have a rule in app.css (drift
 *  gate) EXCEPT its own page-local .sg-* chrome (sgLocalClasses, exempted in the
 *  E2 loop below — the styleguide analog of the --sg-* token carve-out). */
for (const m of styleguideRaw.matchAll(/class="([^"]*)"/g)) {
  const line = lineOf(styleguideRaw, m.index);
  for (const t of m[1].split(/\s+/).filter(Boolean)) {
    emitToken(t, "styleguide.html", line);
  }
}

/**
 * A class value from a `.className = "..."` assignment or a classList call.
 * A trailing single quote marks a concat boundary (dynamic tail): complete
 * tokens in the head are checked, the trailing partial token (if the head
 * does not end in whitespace) is the dynamic prefix, and the whole head must
 * be an ALLOW_PREFIXES entry. (class="..." attributes in app.js go through
 * walkClassAttr below, which additionally extracts tail fragments.)
 */
function handleClassValue(value, file, line) {
  const q = value.indexOf("'");
  if (q === -1) {
    for (const t of value.split(/\s+/).filter(Boolean)) {
      emitToken(t, file, line);
    }
    return;
  }
  const head = value.slice(0, q);
  const parts = head.split(/\s+/).filter(Boolean);
  const endsComplete = /\s$/.test(head) || head === "";
  const complete = endsComplete ? parts : parts.slice(0, -1);
  for (const t of complete) {
    emitToken(t, file, line);
  }
  if (ALLOW_PREFIXES.includes(head)) {
    allowlistedHits.push({ head, file, line });
  } else {
    dynamicSites.push({ head, file, line });
  }
}

/**
 * Walk one class="..." attribute in app.js source starting right after the
 * opening quote. The SPA builds HTML in single-quoted concatenated strings, so
 * within the attribute region the source alternates:
 *   attr text  ─'→  JS code  ─'→  attr text …   (a ' toggles string/code)
 * and double-quoted strings inside the code segments (ternary arms like
 * " is-revoked") are fragments concatenated into the attribute. Returns the
 * verbatim static head, every tail fragment tagged with whether its trailing
 * token is complete, and the walk end index. Backslash escapes are honoured.
 */
function walkClassAttr(src, start) {
  const cap = Math.min(src.length, start + 2000);
  let state = "attr"; // attr | code | dq
  let head = null;
  let dynamic = false;
  let buf = "";
  const frags = []; // { text, trailingComplete }
  let i = start;
  for (; i < cap; i++) {
    const c = src[i];
    if (state === "attr") {
      if (c === "\\") { buf += src[++i] ?? ""; continue; }
      if (c === '"') break; // attribute closed — trailing token is complete
      if (c === "'") {
        if (head === null) head = buf;
        else frags.push({ text: buf, trailingComplete: false }); // dynamic follows
        buf = "";
        dynamic = true;
        state = "code";
      } else buf += c;
    } else if (state === "code") {
      if (c === "'") { state = "attr"; buf = ""; }
      else if (c === '"') { state = "dq"; buf = ""; }
    } else { // dq — a string literal inside the code segment
      if (c === "\\") { buf += src[++i] ?? ""; continue; }
      if (c === '"') { frags.push({ text: buf, trailingComplete: true }); buf = ""; state = "code"; }
      else buf += c;
    }
  }
  if (state === "attr") {
    if (head === null) head = buf;
    else if (buf) frags.push({ text: buf, trailingComplete: true });
  }
  return { head: head ?? buf, dynamic, frags, end: i };
}

{
  let idx = 0;
  for (;;) {
    const at = jsRaw.indexOf('class="', idx);
    if (at === -1) break;
    const valueStart = at + 'class="'.length;
    const line = lineOf(jsRaw, at);
    const walk = walkClassAttr(jsRaw, valueStart);
    const dynamic = walk.dynamic; // a ' concat boundary was crossed
    // Static head — same rules as handleClassValue.
    const parts = walk.head.split(/\s+/).filter(Boolean);
    const headEndsComplete = !dynamic || /\s$/.test(walk.head) || walk.head === "";
    for (const t of headEndsComplete ? parts : parts.slice(0, -1)) {
      emitToken(t, "app.js", line);
    }
    if (dynamic) {
      if (ALLOW_PREFIXES.includes(walk.head)) allowlistedHits.push({ head: walk.head, file: "app.js", line });
      else dynamicSites.push({ head: walk.head, file: "app.js", line });
      // Tail fragments: a fragment must start with whitespace for its first
      // token to be a complete class (otherwise it suffixes the dynamic part);
      // the trailing token is complete unless more dynamic content follows.
      for (const f of walk.frags) {
        let toks = f.text.split(/\s+/);
        if (!/^\s/.test(f.text)) toks = toks.slice(1);
        if (!f.trailingComplete && !/\s$/.test(f.text)) toks = toks.slice(0, -1);
        for (const t of toks.filter(Boolean)) emitToken(t, "app.js", line);
      }
    }
    idx = Math.max(walk.end, valueStart) + 1;
  }
}

// className = "..." (+ optional concat → dynamic) and classList.add/remove/toggle("x").
for (const m of jsRaw.matchAll(/\.className\s*=\s*"([^"]*)"(\s*\+)?/g)) {
  const line = lineOf(jsRaw, m.index);
  if (m[2]) handleClassValue(m[1] + "'", "app.js", line); // mark trailing dynamic boundary
  else handleClassValue(m[1], "app.js", line);
}
for (const m of jsRaw.matchAll(/classList\.(?:add|remove|toggle)\(\s*"([^"]+)"/g)) {
  handleClassValue(m[1], "app.js", lineOf(jsRaw, m.index));
}

// ── Contrast engine (E5) ─────────────────────────────────────────────────────
// Resolve the token maps per theme: the FIRST top-level `:root { … }` block is
// light; `[data-theme="dark"] { … }` overrides it for dark. (The reduced-motion
// `:root` re-declaration sits inside @media, later in the file — the first
// match wins here by construction.) Token blocks contain no nested braces.

// Union EVERY top-level token block in source order (later declaration wins,
// the browser cascade). Anchored to column 0 (`^` + no leading space) so it
// captures the bare `:root {` / `[data-theme="dark"] {` token blocks — BOTH the
// generated block and the hand-authored one that follows — while EXCLUDING
// @media-nested `:root` (indented) and scoped rules (`[data-theme="dark"] .foo {`,
// which has non-brace text before `{`). Token blocks are flat (no nested braces),
// so the non-greedy body stops at the block's own `}`.
function parseTokenBlocks(re) {
  const map = {};
  for (const m of css.matchAll(re)) {
    for (const d of m[1].matchAll(/(--[A-Za-z0-9_-]+)\s*:\s*([^;]+);/g)) map[d[1]] = d[2].trim();
  }
  return map;
}
const lightTokens = parseTokenBlocks(/^:root\s*\{([\s\S]*?)\}/gm);
const darkOverrides = parseTokenBlocks(/^\[data-theme="dark"\]\s*\{([\s\S]*?)\}/gm);
const darkTokens = { ...lightTokens, ...darkOverrides };

// Identity ramps (charter GR5): each `html[data-bp-theme="X"] { … }` block is a
// full accent+surface token set; its `[data-theme="dark"]` sibling is the dark
// variant. Per CSS specificity `html[data-bp-theme="X"]` (0,1,1) overrides the
// base dark block (0,1,0), and `html[data-bp-theme="X"][data-theme="dark"]`
// (0,2,1) overrides everything — so a dark identity state is
// base-light ∪ base-dark ∪ identity-light ∪ identity-dark, later spread wins.
// DISCOVERED from the CSS, never hardcoded: a new identity (iris is landing in
// this same wave) must join the contrast fanout the moment its block exists —
// a fixed list would silently re-create the checked-subset dishonesty this
// detector exists to cure.
const IDENTITY_RAMPS = [
  ...new Set([...css.matchAll(/^html\[data-bp-theme="([a-z0-9-]+)"\]\s*\{/gm)].map((m) => m[1])),
];
const identityTokens = {}; // id -> { light, dark }
for (const id of IDENTITY_RAMPS) {
  identityTokens[id] = {
    light: parseTokenBlocks(new RegExp(`^html\\[data-bp-theme="${id}"\\]\\s*\\{([\\s\\S]*?)\\}`, "gm")),
    dark: parseTokenBlocks(new RegExp(`^html\\[data-bp-theme="${id}"\\]\\[data-theme="dark"\\]\\s*\\{([\\s\\S]*?)\\}`, "gm")),
  };
}

// EVERY theme state the SPA actually renders (charter GR5): base light/dark
// plus each discovered identity's light/dark. Every CONTRAST_PAIRS entry is
// resolved against all of them — the fanout is base light/dark + 2 states per
// discovered identity, and the run's own summary line reports the live counts
// (states × CONTRAST_PAIRS) rather than a number pinned in this comment, which
// went stale the moment a 5th identity landed. A new ramp fans the manifest
// automatically, so it cannot ship an unreadable pairing unseen.
const THEME_STATES = [
  ["base-light", lightTokens],
  ["base-dark", darkTokens],
];
for (const id of IDENTITY_RAMPS) {
  THEME_STATES.push([`${id}-light`, { ...lightTokens, ...identityTokens[id].light }]);
  THEME_STATES.push([
    `${id}-dark`,
    { ...lightTokens, ...darkOverrides, ...identityTokens[id].light, ...identityTokens[id].dark },
  ]);
}

/** Substitute var(--x) references until the value is literal. */
function resolveValue(name, map, seen = new Set()) {
  if (seen.has(name)) throw new Error(`token cycle at ${name}`);
  seen.add(name);
  let v = map[name];
  if (v === undefined) return undefined;
  for (let i = 0; i < 10 && /var\(/.test(v); i++) {
    v = v.replace(/var\(\s*(--[A-Za-z0-9_-]+)\s*\)/g, (_, t) => {
      const r = resolveValue(t, map, new Set(seen));
      return r === undefined ? "UNRESOLVED" : r;
    });
  }
  return v;
}

/** Parse a literal CSS color → {r,g,b,a} in 0..1, or null if not a color. */
function parseColor(v) {
  if (!v) return null;
  v = v.trim();
  let m = v.match(/^hsla?\(\s*([\d.]+)(?:deg)?[ ,]+([\d.]+)%[ ,]+([\d.]+)%\s*(?:[/,]\s*([\d.]+%?)\s*)?\)$/);
  if (m) {
    const [h, s, l] = [+m[1], +m[2] / 100, +m[3] / 100];
    const a = m[4] === undefined ? 1 : m[4].endsWith("%") ? +m[4].slice(0, -1) / 100 : +m[4];
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    const mm = l - c / 2;
    const [r, g, b] =
      h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
      : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return { r: r + mm, g: g + mm, b: b + mm, a };
  }
  m = v.match(/^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$/);
  if (m) {
    const n = parseInt(m[1], 16);
    return {
      r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255,
      a: m[2] ? parseInt(m[2], 16) / 255 : 1,
    };
  }
  m = v.match(/^#([0-9a-fA-F]{3})$/);
  if (m) {
    const [r, g, b] = m[1].split("").map((c) => parseInt(c + c, 16) / 255);
    return { r, g, b, a: 1 };
  }
  m = v.match(/^rgba?\(\s*([\d.]+)[ ,]+([\d.]+)[ ,]+([\d.]+)\s*(?:[/,]\s*([\d.]+)\s*)?\)$/);
  if (m) return { r: +m[1] / 255, g: +m[2] / 255, b: +m[3] / 255, a: m[4] === undefined ? 1 : +m[4] };
  return null;
}

const compositeOver = (fg, bg) => ({
  r: fg.a * fg.r + (1 - fg.a) * bg.r,
  g: fg.a * fg.g + (1 - fg.a) * bg.g,
  b: fg.a * fg.b + (1 - fg.a) * bg.b,
  a: 1,
});
const linear = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const luminance = (c) => 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
function contrastRatio(fg, bg) {
  const [hi, lo] = [luminance(fg), luminance(bg)].sort((a, b) => b - a);
  return (hi + 0.05) / (lo + 0.05);
}

function resolveColor(token, map, theme, errs) {
  const raw = resolveValue(token, map);
  const col = raw === undefined ? null : parseColor(raw);
  if (!col) errs.push(`E5 app.css  ${token} (${theme}) does not resolve to a parseable color (got ${JSON.stringify(raw)})`);
  return col;
}

const contrastResults = []; // { theme, fg, bg, ratio, min, why }
function runContrast(errs) {
  for (const [theme, map] of THEME_STATES) {
    for (const p of CONTRAST_PAIRS) {
      const fg = resolveColor(p.fg, map, theme, errs);
      let bg = resolveColor(p.bg, map, theme, errs);
      if (!fg || !bg) continue;
      if (p.over) {
        const over = resolveColor(p.over, map, theme, errs);
        if (!over) continue;
        bg = compositeOver(bg, over);
      } else if (bg.a < 1) {
        errs.push(`E5 app.css  pair ${p.fg}/${p.bg} (${theme}) has a translucent bg but no "over" surface declared`);
        continue;
      }
      const ratio = contrastRatio(compositeOver(fg, bg), bg);
      contrastResults.push({ theme, ...p, ratio });
      if (ratio < p.min) {
        errs.push(
          `E5 app.css  ${theme}: ${p.fg} on ${p.bg}${p.over ? ` over ${p.over}` : ""} = ${ratio.toFixed(2)}:1, ` +
            `needs ${p.min}:1 (${p.why})`,
        );
      }
    }
  }
}

// ── Focus-indicator opacity (E12) ────────────────────────────────────────────
// WHY THIS EXISTS, and why CONTRAST_PAIRS alone is not enough: the pairs assert
// TOKENS ("--ring clears 3:1 over --surface"). They cannot see which token a
// RULE consumes. Measured on the pre-fix tree: with all five --ring pairs
// present this file exited 0 while 19 focus rules still painted a
// --ring-soft band at 1.19–1.52:1. A token ratchet that the rules can walk away
// from is a vacuous green, so E12 closes the loop at the RULE level.
//
// THE PREDICATE: a `:focus` / `:focus-visible` rule's indicator band — the
// OUTERMOST box-shadow layer (inner layers are the opaque spacer that lifts the
// ring off the control), or the `outline` colour when one is painted — must
// resolve to alpha 1 in every theme state. An α<1 tint is an ARITHMETIC ceiling:
// over ANY opaque backdrop α=0.15 tops out at 1.617:1 and α=0.20 at 1.918:1, so
// no accent value can ever lift it to the 3:1 SC 1.4.11 floor.
//
// THE ESCAPE: a rule that ALSO carries an opaque `border-color` / `outline-color`
// is compliant — its indicator is that border, and the translucent shadow is a
// decorative halo around it (.fleet-row[data-id]:focus-visible and
// .site-row[data-id]:focus-visible are exactly this shape and must stay green).
// task-5acf9b5ad30f9a74 — THE TWO GAPS WAVE 7 NAMED, AND WHAT DRIVING THEM FOUND.
//
// GAP 2 IS NOT THEORETICAL. The sentence above used to end "A rule that paints
// no band at all is out of scope: it is styling something else on focus and
// inherits the shared ring block." That is TRUE of a rule that leaves the
// indicator alone, and FALSE of one that turns it OFF. `origin/main` carried
// exactly one of the second kind and E12 skipped it by construction:
//
//   app.css  .team-search input:focus { outline: none; border-color: rgba(var(--cc-line-rgb), 0.28); }
//
// The `outline` is `none`, so no band was found; `if (!band) continue` retired
// the rule before the alpha test could look at anything. MEASURED IN HEADLESS
// CHROME under `Emulation.setFocusEmulationEnabled`, keyboard-focused
// (`:focus-visible` matches): `outline-style: none`, `box-shadow: none`,
// `border-color: rgba(20,30,48,0.28)`. The sole indicator is a border moving
// from alpha 0.12 to alpha 0.28 — 1.824:1 light and 2.510:1 dark against the
// `--cc-modal` it sits on, and 1.433:1 / 1.782:1 against its own resting
// border. The element is NOT in the shared ring block's class list (that list
// is explicit and `.team-search input` is not on it) and carries no
// `.form-input`, so nothing else paints a ring for it.
//
// THE ARITHMETIC CEILING EXTENDS. This file's header quotes alpha 0.15 ceiling
// 1.617:1 and alpha 0.20 ceiling 1.918:1; the same sweep gives alpha 0.28 a
// ceiling of 2.532:1 (best case: white tint on a grey-29 backdrop) — still
// under the 3:1 floor over ANY opaque backdrop, with ANY accent.
//
// SO THE PREDICATE SPLITS. A focus rule that paints no band is out of scope
// ONLY while it leaves the UA's own indicator standing. One that ALSO declares
// `outline: none | 0` has removed the only indicator there was, and inherits
// nothing unless its own subject appears in a rule that DOES paint a band —
// the "add your class here rather than re-rolling the ring" contract the shared
// block states in prose, now checked.
//
// GAP 1 IS REAL COVERAGE OVER AN EMPTY POPULATION, AND SAYS SO. E12 scanned
// app.css alone; styleguide.html's inline <style> chrome was unchecked. Driven:
// that block declares ZERO `:focus` rules today, so extending the scan finds
// nothing and is a forward guard, not a fix. It is built anyway (the styleguide
// is the living spec and a ring authored there would have been invisible to
// every gate) and its emptiness is PRINTED, so a reader can tell a clean scan
// from an absent one.
//
// THE MEMBERSHIP TEST IS EXACT-SUBJECT, WHICH IS CONSERVATIVE ON PURPOSE. It
// cannot see that `.a .b:focus` would be covered by a band-painting `.form-input`
// rule if the element also carried that class — CSS text does not know what the
// DOM composes. A rule in that position is a FALSE POSITIVE and belongs in
// ALLOW_BANDLESS_FOCUS with a written reason, exactly like every other
// allowlist in this file. It is empty today: the one member of the population
// was a real defect and was fixed rather than allowed.
const ALLOW_BANDLESS_FOCUS = [
  // { selector: ".x:focus", why: "…" },
];

/** Substitute var() in an arbitrary declaration value until it is literal. */
function resolveLiteralValue(value, map) {
  let v = String(value).trim();
  for (let i = 0; i < 10 && /var\(/.test(v); i++) {
    v = v.replace(/var\(\s*(--[A-Za-z0-9_-]+)\s*\)/g, (_, t) => {
      const r = resolveValue(t, map);
      return r === undefined ? "UNRESOLVED" : r;
    });
  }
  return v;
}

// Colour functions FIRST so `hsl(var(--x) / 0.15)` is taken whole rather than
// as the bare var() nested inside it.
const COLOR_ATOM = /hsla?\([^()]*(?:\([^()]*\)[^()]*)*\)|rgba?\([^()]*(?:\([^()]*\)[^()]*)*\)|color-mix\([^()]*(?:\([^()]*\)[^()]*)*\)|#[0-9a-fA-F]{3,8}\b|var\(\s*--[A-Za-z0-9_-]+\s*\)/g;

/** The colour of a shadow layer / outline value: the last colour atom in it. */
function colorAtomOf(value) {
  const atoms = String(value).match(COLOR_ATOM);
  return atoms ? atoms[atoms.length - 1] : null;
}

/** Split a value on TOP-LEVEL commas (box-shadow layers). */
function splitLayers(value) {
  const out = [];
  let depth = 0, cur = "";
  for (const ch of value) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) { out.push(cur); cur = ""; } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out;
}

/** Lowest alpha this colour atom takes across every theme state; null = unparseable. */
function minAlphaAcrossThemes(atom) {
  let min = null;
  for (const [, map] of THEME_STATES) {
    const col = parseColor(resolveLiteralValue(atom, map));
    if (!col) continue;
    min = min === null ? col.a : Math.min(min, col.a);
  }
  return min;
}

/** The rule subject: the selector with its focus pseudo-classes removed. */
function focusSubjectsOf(selector) {
  return selector
    .split(",")
    .map((sel) => sel.replace(/::?focus(-visible|-within)?\b/g, "").replace(/\s+/g, " ").trim())
    .filter(Boolean);
}

/**
 * Every focus rule across the sources E12 owns. `styleguide.html`'s inline
 * <style> is scanned at its real line numbers — the offset is the block's own
 * start, so a finding there is clickable rather than relative to a substring
 * nobody can find.
 */
function focusRuleSources() {
  const out = [{ file: "app.css", text: css, lineBase: 0 }];
  for (const m of styleguideRaw.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)) {
    const open = m[0].indexOf(">") + 1;
    out.push({
      file: "styleguide.html",
      text: stripCssComments(m[1]),
      lineBase: lineOf(styleguideRaw, m.index + open) - 1,
    });
  }
  return out;
}

/** Every focus rule in every owned source, parsed once. */
function allFocusRules() {
  const rules = [];
  for (const src of focusRuleSources()) {
    for (const m of src.text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selector = m[1].trim();
      if (!/:focus\b|:focus-visible\b/.test(selector)) continue;
      // THE SELECTOR'S OWN LINE, not the match's. `([^{}]+)\{` starts matching
      // at the character after the PREVIOUS rule's `}`, so `m.index` sits on
      // whatever blank lines separate the two — measured 2 lines early on a
      // styleguide probe (reported 202 for a rule on 204). A finding a reader
      // cannot click is a finding they re-derive by hand.
      const lead = m[1].length - m[1].trimStart().length;
      rules.push({ selector, body: m[2], file: src.file, line: src.lineBase + lineOf(src.text, m.index + lead) });
    }
  }
  return rules;
}

/** Declarations of a rule body, last-wins as in the cascade. */
function declsOf(body) {
  const decls = {};
  for (const d of body.split(";")) {
    const i = d.indexOf(":");
    if (i < 0) continue;
    const prop = d.slice(0, i).trim().toLowerCase();
    if (prop.startsWith("--")) continue;
    decls[prop] = d.slice(i + 1).trim();
  }
  return decls;
}

/** The indicator band of a rule: outermost box-shadow layer, else the outline colour. */
function bandOf(decls) {
  const shadow = decls["box-shadow"];
  if (shadow && !/^none\b/i.test(shadow)) {
    const layers = splitLayers(shadow);
    const atom = colorAtomOf(layers[layers.length - 1]);
    if (atom) return { band: atom, prop: "box-shadow" };
  }
  const outline = decls["outline"] || decls["outline-color"];
  if (outline && !/^(none|0)\b/i.test(outline)) {
    const atom = colorAtomOf(outline);
    if (atom) return { band: atom, prop: decls["outline-color"] ? "outline-color" : "outline" };
  }
  return { band: null, prop: null };
}

/** How many focus rules E12 examined, by file — printed so an empty scan is visible. */
export function focusScanCensus() {
  const byFile = {};
  for (const src of focusRuleSources()) byFile[src.file] = byFile[src.file] || 0;
  for (const r of allFocusRules()) byFile[r.file] = (byFile[r.file] || 0) + 1;
  return byFile;
}

export function focusIndicatorErrors() {
  const errs = [];
  const rules = allFocusRules();
  // The subjects that DO paint a band — the membership set the suppression arm
  // below asks about. Built across every owned source, so a styleguide rule can
  // legitimately inherit an app.css ring and vice versa.
  const banded = new Set();
  for (const r of rules) {
    if (bandOf(declsOf(r.body)).band) for (const sub of focusSubjectsOf(r.selector)) banded.add(sub);
  }
  const allowed = new Set(ALLOW_BANDLESS_FOCUS.map((a) => a.selector.replace(/\s+/g, " ").trim()));

  for (const m of rules) {
    const selector = m.selector;
    const body = m.body;

    const decls = declsOf(body);
    const { band, prop: bandProp } = bandOf(decls);

    if (!band) {
      // E12b — THE SUPPRESSION ARM. No band of its own is fine while the UA's
      // indicator is left standing. `outline: none | 0` removes it, and then
      // the rule owes a replacement or a membership in one.
      const off = String(decls["outline"] || decls["outline-style"] || decls["outline-width"] || "");
      if (!/^(none|0)(\b|px|$)/i.test(off.trim())) continue;
      const key = selector.replace(/\s+/g, " ").trim();
      if (allowed.has(key)) continue;
      const subs = focusSubjectsOf(selector);
      if (subs.some((sub) => banded.has(sub))) continue; // the same subject paints one elsewhere
      // The best replacement it DOES offer, so the message names the real number
      // rather than only the absence.
      const replacement = ["border-color", "border"]
        .map((prop) => (decls[prop] ? { prop, atom: colorAtomOf(decls[prop]) } : null))
        .find((x) => x && x.atom);
      const ra = replacement ? minAlphaAcrossThemes(replacement.atom) : null;
      errs.push(
        `E12 ${m.file}:${m.line}  focus rule ${JSON.stringify(key)} turns the indicator OFF ` +
          `(outline: ${off.trim()}) and paints no band of its own` +
          (replacement
            ? `; its only replacement is ${replacement.prop}: ${replacement.atom}, which resolves to alpha ` +
              `${ra} — a translucent border is an ARITHMETIC ceiling below the 3:1 SC 1.4.11 floor over any ` +
              `opaque backdrop (alpha 0.28 ceils at 2.53:1)`
            : ` and offers no replacement at all`) +
          `. Nothing else paints a band for ${JSON.stringify(subs.join(", "))}: it is not in the shared ring ` +
          `block's class list. Add the subject to that block, or paint the house ring here ` +
          `(the .form-input:focus shape — opaque border-color: var(--ring) plus a decorative halo). ` +
          `If the subject really does inherit a band this text cannot see, add it to ALLOW_BANDLESS_FOCUS with a reason`,
      );
      continue;
    }

    const alpha = minAlphaAcrossThemes(band);
    if (alpha === null || alpha >= 1) continue;

    // The escape: an opaque border/outline colour IS the indicator.
    const escape = ["border-color", "outline-color", "border"]
      .map((p) => decls[p] && colorAtomOf(decls[p]))
      .filter(Boolean)
      .some((atom) => {
        const a = minAlphaAcrossThemes(atom);
        return a !== null && a >= 1;
      });
    if (escape) continue;

    errs.push(
      `E12 ${m.file}:${m.line}  focus rule ${JSON.stringify(selector.replace(/\s+/g, " "))} paints its ` +
        `SOLE indicator band from ${band} (${bandProp}), which resolves to alpha ${alpha} — ` +
        `a translucent band can never reach the 3:1 SC 1.4.11 floor over an opaque backdrop ` +
        `(alpha 0.15 ceils at 1.62:1). Point the band at an OPAQUE token (--ring), or give the ` +
        `rule an opaque border-color and keep the tint as a decorative halo`,
    );
  }
  return errs;
}

// ── External-host lint (E7) ──────────────────────────────────────────────────
// Resource LOADS only — <a href> navigation is allowed. Covers load-bearing
// HTML elements, CSS url(...) and @import in all three surfaces.

function externalHostFindings(src, file, isHtml) {
  const out = [];
  if (isHtml) {
    for (const m of src.matchAll(/<(link|script|img|iframe|source|video|audio|embed|object)\b[^>]*/gi)) {
      const url = m[0].match(/\b(?:href|src|data)\s*=\s*["']((?:https?:)?\/\/[^"']+)["']/i);
      if (url) out.push({ file, line: lineOf(src, m.index), what: `<${m[1].toLowerCase()}> loads ${url[1]}` });
    }
  }
  for (const m of src.matchAll(/url\(\s*["']?\s*(?:https?:)?\/\//gi)) {
    out.push({ file, line: lineOf(src, m.index), what: "url() references an external host" });
  }
  for (const m of src.matchAll(/@import\b[^;\n]*?(?:https?:)?\/\//gi)) {
    out.push({ file, line: lineOf(src, m.index), what: "@import references an external host" });
  }
  return out;
}

// ── Evaluate ─────────────────────────────────────────────────────────────────

const errors = [];

for (const c of consumed) {
  if (!definedTokens.has(c.token)) {
    errors.push(`E1 ${c.file}:${c.line}  var(${c.token}) consumed but ${c.token} is not defined in app.css`);
  }
}

const hookHits = [];
const gapHits = [];             // KNOWN_GAPS-demoted E2/E3 → printed as R3, not fatal
const matchedGaps = new Set();  // which KNOWN_GAPS entries fired (staleness check)
const gapKey = (g) => `${g.file}|${"cls" in g ? "E2:" + g.cls : "E3:" + g.head}`;
const seenMissing = new Set();
for (const e of emitted) {
  if (cssClasses.has(e.cls)) continue;
  // page-local .sg-* chrome defined in styleguide.html's own <style> (the
  // class analog of the --sg-* token carve-out).
  if (e.file === "styleguide.html" && sgLocalClasses.has(e.cls)) continue;
  if (ALLOW_HOOK_CLASSES.includes(e.cls)) {
    hookHits.push(e);
    continue;
  }
  const gap = KNOWN_GAPS.find((g) => "cls" in g && g.file === e.file && g.cls === e.cls);
  if (gap) {
    matchedGaps.add(gapKey(gap));
    const key = `${e.cls}@${e.file}`;
    if (!seenMissing.has(key)) { seenMissing.add(key); gapHits.push({ code: "E2", file: e.file, what: `class "${e.cls}"`, why: gap.why }); }
    continue;
  }
  const key = `${e.cls}@${e.file}:${e.line}`;
  if (seenMissing.has(key)) continue;
  seenMissing.add(key);
  errors.push(`E2 ${e.file}:${e.line}  class "${e.cls}" is emitted but has no rule in app.css`);
}

const seenGapHeads = new Set();
for (const d of dynamicSites) {
  const gap = KNOWN_GAPS.find((g) => "head" in g && g.file === d.file && g.head === d.head);
  if (gap) {
    matchedGaps.add(gapKey(gap));
    const key = `${d.head}@${d.file}`;
    if (!seenGapHeads.has(key)) { seenGapHeads.add(key); gapHits.push({ code: "E3", file: d.file, what: `dynamic head "${d.head}"`, why: gap.why }); }
    continue;
  }
  errors.push(`E3 ${d.file}:${d.line}  dynamic class composition with head "${d.head}" is not in ALLOW_PREFIXES`);
}

// KNOWN_GAPS entries that fired nothing this run — the owning slice fixed the gap,
// so prune the entry (mirrors staleRawAllows). Reported below, never fatal.
const staleGaps = KNOWN_GAPS.filter((g) => !matchedGaps.has(gapKey(g)));

for (const b of badTokens) {
  errors.push(
    `E4 ${b.file}:${b.line}  class token ${JSON.stringify(b.tok)} cannot be statically parsed — ` +
      `rewrite the site in the single-quoted concat style (with an ALLOW_PREFIXES entry if dynamic)`,
  );
}

// E13 — every server-side deployment status is painted. Derived from
// DEPLOY_STATUSES (the Ecto @statuses enum), never from the E3 allowlist's
// prose. `css` is comment-stripped, so a selector that survives only inside a
// comment does NOT count.
for (const st of DEPLOY_STATUSES) {
  if (cssClasses.has(`dep-${st}`)) continue;
  errors.push(
    `E13 app.css  deployment status "${st}" has no .dep-${st} rule — the ` +
      `dep-pill dep- head emits it, so it falls through to the .dep-pill base ` +
      `and paints as an untouched/queued deployment. Add a rule next to the ` +
      `other .dep-* rules in the DEPLOYMENTS section.`,
  );
}

// E15 — every delivery-log TONE is painted, or is a NAMED base-pill consent.
// Same family as E13 one surface over: the ALLOW_PREFIXES entry for
// `"wh-del-status wh-del-status--"` waives the dynamic head, so nothing measured
// the value space until here. Three ways to fail, because a value-space check
// with only the obvious arm is half a check.
{
  const emitted = emittedDeliveryTones(jsRaw);
  const declared = new Set(WH_DEL_TONES);
  const consented = new Set(WH_DEL_BASE_TONES);

  if (emitted === null) {
    errors.push(
      "E15 app.js  notifDeliveryTone() could not be located or parsed — the " +
        "wh-del-status tone value space is DERIVED from its returns, so a rename " +
        "or a rewrite must come with an update here, never a silently skipped check.",
    );
  } else {
    // (a) DRIFT: app.js and WH_DEL_TONES must name the same set.
    for (const t of emitted) {
      if (declared.has(t)) continue;
      errors.push(
        `E15 __css_check.mjs  notifDeliveryTone() returns tone "${t}", which is not in ` +
          `WH_DEL_TONES — add it there, then paint .wh-del-status--${t} or consent to ` +
          `the base pill in WH_DEL_BASE_TONES.`,
      );
    }
    for (const t of declared) {
      if (emitted.has(t)) continue;
      errors.push(
        `E15 __css_check.mjs  WH_DEL_TONES names "${t}", which notifDeliveryTone() no ` +
          `longer returns — a value space wider than reality trains the reader to ` +
          `ignore this list. Remove it.`,
      );
    }
  }

  // (b) UNPAINTED: a tone with neither a rule nor a consent falls through to the
  //     base pill by ACCIDENT, and a withheld alert reads as some other outcome.
  for (const t of WH_DEL_TONES) {
    if (cssClasses.has(`wh-del-status--${t}`)) continue;
    if (consented.has(t)) continue;
    errors.push(
      `E15 app.css  delivery tone "${t}" has no .wh-del-status--${t} rule — the ` +
        `wh-del-status-- head emits it, so it falls through to the .wh-del-status ` +
        `base pill and reads as an unrelated outcome. Add a rule beside the other ` +
        `.wh-del-status--* rules, or name it in WH_DEL_BASE_TONES if the neutral ` +
        `base pill really is its treatment.`,
    );
  }

  // (c) STALE CONSENT: a consent that absolves nothing is the new silent slack.
  for (const t of WH_DEL_BASE_TONES) {
    if (cssClasses.has(`wh-del-status--${t}`)) {
      errors.push(
        `E15 __css_check.mjs  WH_DEL_BASE_TONES consents "${t}" to the base pill, but ` +
          `.wh-del-status--${t} now HAS a rule — the consent is stale. Drop the entry ` +
          `so the rule is the thing being checked.`,
      );
    }
    if (!WH_DEL_TONES.includes(t)) {
      errors.push(
        `E15 __css_check.mjs  WH_DEL_BASE_TONES consents "${t}", which is not a tone in ` +
          `WH_DEL_TONES — a consent row that matches no branch consents to nothing.`,
      );
    }
  }
}

// E16 — every freshness dot is painted. Four ways to fail: the deriver cannot
// read the arms, the deriver read them but could not follow one, the declared set
// drifted from the arms, or a dot has no rule. No consent arm by design (see
// FRESH_DOTS above); arm (d) is what keeps that design honest.
{
  const derived = emittedFreshnessDots(jsRaw);
  if (derived === null) {
    errors.push(
      "E16 app.js  freshnessModel() could not be located or brace-matched — the " +
        "fresh-badge-- dot set is DERIVED from its arms, so a rename or a rewrite " +
        "must come with an update here, never a silently skipped check.",
    );
  } else {
    // (a) DERIVER BLINDNESS: every `dot =` in the body must be a string literal,
    //     or this reader is returning a set narrower than the code's.
    if (derived.assigns !== derived.literal) {
      errors.push(
        `E16 app.js  freshnessModel() has ${derived.assigns} \`dot =\` assignment(s) but only ` +
          `${derived.literal} are string literals — emittedFreshnessDots reads literals ONLY, so ` +
          `the derived set would be short by ${derived.assigns - derived.literal}. Keep the arms ` +
          `literal, or teach the deriver the new form; do not let it report a set it cannot see.`,
      );
    }
    // (b) DRIFT, both directions: FRESH_DOTS and the arms must name one set.
    for (const d of derived.dots) {
      if (FRESH_DOTS.includes(d)) continue;
      errors.push(
        `E16 __css_check.mjs  freshnessModel() assigns dot "${d}", which is not in FRESH_DOTS — ` +
          `add it there, then paint .fresh-badge--${d}. There is no consent to the base pill on ` +
          `this family: the bare .fresh-badge is the "Not deployed" badge.`,
      );
    }
    for (const d of FRESH_DOTS) {
      if (derived.dots.has(d)) continue;
      errors.push(
        `E16 __css_check.mjs  FRESH_DOTS names "${d}", which freshnessModel() no longer assigns — ` +
          `a value space wider than reality trains the reader to ignore this list. Remove it.`,
      );
    }
  }

  // (c) UNPAINTED: `css` is comment-stripped, so a selector surviving only inside
  //     a comment does not count.
  for (const d of FRESH_DOTS) {
    if (cssClasses.has(`fresh-badge--${d}`)) continue;
    errors.push(
      `E16 app.css  freshness dot "${d}" has no .fresh-badge--${d} rule — the ` +
        `fresh-badge fresh-badge-- head emits it, so the badge falls through to the ` +
        `BARE .fresh-badge, which siteFreshnessSeg already ships as the "Not deployed ` +
        `to production" badge. Add a rule beside the other .fresh-badge--* rules.`,
    );
  }

  // (d) PREMISE: (c)'s wording, and the decision to ship no consent list at all,
  //     both rest on the bare .fresh-badge being a real shipped state. If that
  //     emission goes, re-open the decision instead of leaving stale prose.
  if (!/class="fresh-badge"/.test(jsRaw)) {
    errors.push(
      "E16 app.js  no bare `class=\"fresh-badge\"` emission remains, but E16 ships NO consent " +
        "list on the strength of that badge existing (the never-deployed state the base look " +
        "belongs to). Re-decide: either restore the emission, or add a named consent list here " +
        "the way WH_DEL_BASE_TONES does for E15.",
    );
  }
}

// E5 — the contrast manifest, both themes.
runContrast(errors);

// E12 — rule-level focus-indicator opacity. E5 asserts TOKENS; this asserts
// which token each focus RULE actually consumes, so the ratchet cannot be
// walked away from (measured: 19 rules at 1.19–1.52:1 with E5 green).
for (const e of focusIndicatorErrors()) errors.push(e);
// task-5acf9b5ad30f9a74 — AN EMPTY SCAN IS NOT A CLEAN SCAN. E12 now reads
// styleguide.html's inline <style> as well as app.css. That block declares ZERO
// focus rules today, so the extension finds nothing; printing the per-file
// count is what lets a reader tell "checked and clean" from "never looked",
// and what will red-flag the day the living spec grows a ring nobody gates.


// E9 — parse-completeness: declarations a comment mis-close swallowed (#4251).
for (const e of swallowedTokenErrors(cssRaw)) errors.push(e);

// E10 — comment nesting coherence: an orphan `*/` swallows the next whole rule
// (#4592 — the modal root). Runs alongside E9, which sees only token blocks.
for (const e of orphanCommentErrors(cssRaw)) errors.push(e);

// E14 — wrap-recipe declaration parity (charter D220): the three hand-built
// copies share a byte-identical five-declaration core wearing three different
// jackets, and nothing asserted that the core still agrees. The copy inventory
// is printed below so the count is the SCAN's claim, never a comment's.
const wrapParity = wrapParityErrors(cssRaw);
for (const e of wrapParity.errors) errors.push(e);

// E11 — banned source line-number citation (charter D41 / bp-honest-gates D5):
// `app.js:<line>` in a comment of any scanned SPA / harness file. The shape is
// banned outright; router.ex cross-language cites are OUT (see the boundary on
// bannedSourceCitationErrors). Scans this file too, so its own citations cannot
// go stale unseen.
// E17 first: E11's census is only as honest as the set it iterates, and an
// empty or half-collapsed set makes E11's `0 error(s)` a report about nothing.
// Print the derivation with: node __css_check.mjs --citation-inventory
const citationFiles = citationScanFiles();
for (const e of citationScanSetRefusals(citationFiles)) errors.push(e);
for (const rel of citationFiles) {
  for (const e of bannedSourceCitationErrors(read(rel), rel)) errors.push(e);
}

// E8 — scoped-theme alias integrity. var() inside a custom property substitutes
// where the property is DECLARED, so a :root-only alias whose value references
// a token the dark block re-themes freezes the LIGHT value for any subtree that
// scopes [data-theme="dark"] onto a non-root element — which the styleguide's
// side-by-side panes do. Any such alias must be re-declared in the dark block.
// (Caught live: --destructive rendered the light danger inside the dark panes.)
for (const [name, value] of Object.entries(lightTokens)) {
  if (name in darkOverrides) continue;
  const themedRefs = [...value.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)\s*\)/g)]
    .map((m) => m[1])
    .filter((t) => t in darkOverrides);
  if (themedRefs.length) {
    errors.push(
      `E8 app.css  ${name} is declared only in :root but references dark-re-themed ` +
        `${themedRefs.join(", ")} — re-declare ${name} in the [data-theme="dark"] block ` +
        `or scoped-dark subtrees (styleguide panes) freeze the light value`,
    );
  }
}

// E6/R4 scan: raw color literals + raw px font-sizes outside the token blocks.
// Track whether each line sits inside the :root / [data-theme="dark"] token
// blocks (both are top-level).
const rawLiterals = [];
const pxFontSizes = []; // R4
{
  const lines = css.split("\n");
  let inTokenBlock = false;
  let depth = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Anchored: `[data-theme="dark"] .foo {` is a scoped RULE, not a token
    // block — only the bare block selectors mark token territory. The identity
    // ramps `html[data-bp-theme="X"] {` and `…[data-theme="dark"] {` (charter
    // GR5) are token blocks too, so their raw ramp values are contract, not E6.
    if (
      depth === 0 &&
      /^\s*(?::root|\[data-theme="dark"\]|html\[data-bp-theme="[a-z0-9-]+"\](?:\[data-theme="dark"\])?)\s*\{\s*$/.test(line)
    )
      inTokenBlock = true;
    for (const ch of line) {
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) inTokenBlock = false;
      }
    }
    if (inTokenBlock) continue;
    // A color function whose first argument is var(--x) is consuming a token —
    // that IS the contract, not a raw literal (e.g. hsl(var(--warn-hsl) / 0.3)).
    const hits = line.match(/#[0-9a-fA-F]{3,8}\b|\b(?:hsla?|rgba?|oklch|color-mix)\((?!\s*(?:in\s+\w+\s*,\s*)?var\()/g);
    if (hits) rawLiterals.push({ line: i + 1, text: line.trim(), n: hits.length });
    // R4: px font sizes (font-size + the `font:` shorthand) not yet on the scale.
    if (/font-size:\s*[\d.]+px/.test(line) || /\bfont:\s*[^;]*\b[\d.]+px/.test(line)) {
      pxFontSizes.push({ line: i + 1, text: line.trim() });
    }
  }
}

// E6 — every raw-literal line must be a conscious ALLOW_RAW_COLORS entry.
const rawAllowed = [];
const staleRawAllows = new Set(ALLOW_RAW_COLORS.map((a) => a.line));
for (const r of rawLiterals) {
  const hit = ALLOW_RAW_COLORS.find((a) => a.line === r.text);
  if (hit) {
    rawAllowed.push({ ...r, why: hit.why });
    staleRawAllows.delete(hit.line);
  } else {
    errors.push(`E6 app.css:${r.line}  raw color literal outside the token blocks: ${r.text}`);
  }
}

// E7 — no external resource loads in the offline surfaces.
for (const f of [
  ...externalHostFindings(htmlRaw, "index.html", true),
  ...externalHostFindings(styleguideRaw, "styleguide.html", true),
  ...externalHostFindings(css, "app.css", false),
]) {
  errors.push(`E7 ${f.file}:${f.line}  ${f.what} — the console must render fully offline`);
}

// R2: defined-but-unconsumed tokens.
const consumedSet = new Set(consumed.map((c) => c.token));
const unconsumed = [...definedTokens].filter((t) => !consumedSet.has(t)).sort();

// ── Print ────────────────────────────────────────────────────────────────────

const uniqEmitted = new Set(emitted.map((e) => e.cls));
const uniqConsumed = new Set(consumed.map((c) => c.token));

for (const h of allowlistedHits) {
  console.log(`allow  ${h.file}:${h.line}  dynamic class head "${h.head}" (ALLOW_PREFIXES)`);
}
for (const h of hookHits) {
  console.log(`allow  ${h.file}:${h.line}  hook class "${h.cls}" (ALLOW_HOOK_CLASSES — no style rule by design)`);
}
for (const r of rawAllowed) {
  console.log(`allow  app.css:${r.line}  raw color (ALLOW_RAW_COLORS: ${r.why})`);
}
for (const s of staleRawAllows) {
  console.log(`stale  ALLOW_RAW_COLORS entry no longer matches any line — prune it: ${s}`);
}

// E5 summary: worst pair per theme state, so drift toward the threshold is
// visible across every discovered state (base + each identity × light/dark) —
// one line per state, so the count is the output's, never this comment's.
for (const [theme] of THEME_STATES) {
  const rows = contrastResults.filter((r) => r.theme === theme);
  if (!rows.length) continue;
  const worst = rows.reduce((a, b) => (a.ratio / a.min < b.ratio / b.min ? a : b));
  console.log(
    `\nE5 ${theme}: ${rows.length} contrast pairs checked; tightest = ${worst.fg} on ${worst.bg}` +
      `${worst.over ? ` over ${worst.over}` : ""} at ${worst.ratio.toFixed(2)}:1 (needs ${worst.min}:1 — ${worst.why})`,
  );
}
if (process.env.CSS_CHECK_VERBOSE) {
  for (const r of contrastResults) {
    console.log(
      `      ${r.theme.padEnd(5)} ${(r.ratio >= r.min ? "ok  " : "FAIL")} ${r.ratio.toFixed(2).padStart(6)}:1 ` +
        `(≥${r.min})  ${r.fg} on ${r.bg}${r.over ? ` over ${r.over}` : ""} — ${r.why}`,
    );
  }
}

// task-5acf9b5ad30f9a74 — AN EMPTY SCAN IS NOT A CLEAN SCAN. E12 now reads
// styleguide.html's inline <style> as well as app.css. That block declares ZERO
// focus rules today, so the extension finds nothing and is a FORWARD guard;
// printing the per-file count is what lets a reader tell "checked and clean"
// from "never looked", and what makes the day the living spec grows a ring
// nobody gates visible in the log.
console.log(
  `\nE12 focus rules scanned: ` +
    Object.entries(focusScanCensus()).map(([f, n]) => `${f} ${n}`).join(", ") +
    ` — a 0 is COVERAGE, not yield: the file declares no focus rule at all`,
);

// E14 inventory: the copies the scan actually SAW, with their true line
// numbers. Printed unconditionally so a scan degrading to fewer copies is
// visible in the log even before the pins turn it red.
console.log(
  `\nE14 ${wrapParity.copies.length} wrapper-scoped .status-pill wrap copy(ies): ` +
    `${wrapParity.copies.map((c) => `${c.selector} (app.css:${c.line})`).join(", ")}`,
);

if (unconsumed.length) {
  console.log(`\nR2  defined but not yet consumed: ${unconsumed.join(", ")}`);
}
if (gapHits.length) {
  console.log(
    `\nR3  ${gapHits.length} known gap(s) in app.js/index.html demoted (owned by ` +
      `gr-backlog-css-check-missing-classes — author the CSS or remove the emission):`,
  );
  for (const g of gapHits) console.log(`      ${g.code} ${g.file}  ${g.what} — ${g.why}`);
}
for (const g of staleGaps) {
  console.log(
    `stale  KNOWN_GAPS entry no longer matches any emission — prune it (the owning slice fixed it): ` +
      `${g.file} ${"cls" in g ? `class "${g.cls}"` : `head "${g.head}"`}`,
  );
}
if (pxFontSizes.length) {
  console.log(
    `\nR4  ${pxFontSizes.length} raw px font-size line(s) outside the token blocks ` +
      `(decision-24 sweep backlog; report-only). Set CSS_CHECK_VERBOSE=1 to list them.`,
  );
  if (process.env.CSS_CHECK_VERBOSE) {
    for (const p of pxFontSizes) console.log(`      app.css:${p.line}  ${p.text}`);
  }
}

console.log(
  `\n__css_check: ${uniqEmitted.size} classes checked, ${uniqConsumed.size} tokens checked, ` +
    `${contrastResults.length} contrast pairs, ${allowlistedHits.length + hookHits.length + rawAllowed.length} allowlisted, ` +
    `${gapHits.length} known gap(s) demoted (R3), ${errors.length} error(s)`,
);

if (errors.length) {
  console.error("");
  for (const e of errors) console.error("FAIL  " + e);
  process.exit(1);
}
