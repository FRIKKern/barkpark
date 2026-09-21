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
//   E13 a BROKEN STATE GRAMMAR. Since the decision-24 sweep there is ONE pill
//       vocabulary: `DEPLOY_STATUS_META` in app.js maps every ledger status to
//       a `.status-pill` role (+ optional shape variant), and the second
//       `.dep-*` family is retired. Five arms, because the old one-arm shape
//       ("does .dep-<status> have a rule?") could only ever police ONE of the
//       ways this grammar breaks:
//         (a) the table could not be located or parsed in app.js — a rename must
//             come with an update here, never a silently skipped check;
//         (b) a status in DEPLOY_STATUSES the table does not cover (it would
//             fall to neutral and impersonate `queued`, the exact defect that
//             shipped twice under the old family);
//         (c) a role or variant the table names with no `.status-pill--<name>`
//             rule in app.css — the unpainted arm, one family over;
//         (d) a role outside the closed five, which would be a sixth hue
//             invented at a call site rather than declared in the family;
//         (e) the RETIRED family coming back — any `.dep-pill` / `.dep-<status>`
//             rule in app.css or `dep-pill` literal in app.js. This is the arm
//             that reds if the sweep is reverted: re-forking the grammar is the
//             regression, not any single missing rule.
//       Full boundary on DEPLOY_STATUSES / STATUS_PILL_ROLES below.
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
//   E18 an unpainted DOMAIN-CHECKLIST ROLE, and a deriver that went blind.
//       FOURTH in the E13/E15/E16 family: `dom-rung dom-rung--` is an E3
//       allowlist entry, so the role half was unmeasured and its trailing comment
//       was the only statement of the value space — a comment that named FIVE
//       roles for a SIX-role fold, omitting `unknown` (which has a rule) and
//       listing `pending` (which had none). Wrong in both directions at once,
//       and unfailable. The set is DERIVED from domainStageRows' ternary arms and
//       its `active` promotion, diffed against DOM_RUNG_ROLES both ways.
//       WEAKER THAN E16's DEFECT, AND SAID SO: the bare .dom-rung is not a
//       separately shipped state, so ruleless `pending` fell through to the right
//       muted paint by COINCIDENCE rather than impersonating anything. The remedy
//       is still a written rule — arm (d) pins that .dom-rung--pending mirrors a
//       base that still exists.
//   E19 a WAIVER THAT ABSOLVES NOTHING: an ALLOW_PREFIXES entry no dynamic
//       composition site in app.js or index.html actually has. The general form
//       of E15's stale-consent arm, applied to the E3 allowlist itself. A waiver
//       for an unemitted head can never red, so it is indistinguishable from one
//       doing real work — and it silently PRE-EXEMPTS the family if that name
//       ever returns, at which point the gate reports green over a family it has
//       never checked. Compared against `allowlistedHits`, the walker's own
//       record, so the arm and the waiver are judged on the same evidence.
//   E20 a HOOK WAIVER THAT ABSOLVES NOTHING: an ALLOW_HOOK_CLASSES entry no
//       emission in the scanned tree actually carries as a class. E19's exact
//       shape, one list over — ALLOW_HOOK_CLASSES was the ONE of this file's
//       four suppression lists with no decay arm at all, so a name deleted from
//       the console left a standing consent nobody was ever told about and the
//       run still printed `0 error(s)`. HARD, like E19 and unlike the
//       report-only `stale` lines: see the block's own comment for why the four
//       lists are not all the same severity. Judged against `hookHits`, the E2
//       loop's own record, and it runs its own controls so it cannot pass by
//       never having had a subject.
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
//         • It does not READ shorthand VALUES. A core property set through a
//           shorthand (`padding: 2px 11px`, `block-size`, `text-wrap`) is
//           TRIGGERED and REFUSED, never parsed — see the shorthand ruling
//           below for why that is the remedy and not a parser.
//       SHORTHAND (cch-w19-bl-e14-shorthand-blind). THE GAP AS MEASURED: on the
//       pre-fix tree a wrapper-scoped `.status-pill` rule written
//       `{ padding: 2px 11px }` neither TRIGGERED E14 (`padding` is not one of
//       the five pinned core NAMES, so declares-any-core never fired) nor
//       SATISFIED `padding-top`/`padding-bottom`. The asymmetry ran the bad
//       way: a drifting fourth copy in shorthand was INVISIBLE, not red — the
//       vacuous green this epic exists to kill. REPRODUCED BEFORE IT WAS FIXED:
//       the same synthetic stylesheet the driven legs build (four pinned
//       survivors plus `.op-gate .status-pill { padding: 2px 11px }`) exited 0
//       with `4 wrapper-scoped wrap copy(ies), 0 E14 error(s)` on the pre-fix
//       check and exits 1 naming `.op-gate` after it. Both directions, plus the
//       legal shorthand-with-restatement copy, are driven in __app.test.mjs.
//       TWO REMEDIES WERE ON THE TABLE AND ONE LOST.
//         (a) EXPAND THE SHORTHAND, then compare longhands — REJECTED. It buys
//             a mini CSS parser: padding's 1/2/3/4-value grammar, `!important`,
//             `var()` inside the value (unresolvable statically — `padding:
//             var(--p)` would have to answer "is padding-top 2px?" and cannot),
//             `inherit`/`initial`/`unset`, and the same grammar again for every
//             future core property. Each edge it gets wrong is a FALSE GREEN in
//             a tripwire — the disease, not the cure — and the cost recurs on
//             every core-property change. It also legitimises TWO spellings of
//             the canonical recipe, so the next reader must diff two forms to
//             see whether four copies agree.
//         (b) TRIGGER ON THE SHORTHAND AND DEMAND THE LONGHAND — CHOSEN. A core
//             shorthand makes the rule a wrap copy (so it can never be
//             invisible), and the copy is green only if every core longhand
//             that shorthand can set is RESTATED in longhand, at the canonical
//             value, LATER IN THE SAME BLOCK. No value is parsed, so there is
//             no grammar to get wrong and no `var()` it cannot answer; the
//             canonical recipe stays single-form; and `{ padding: 2px 11px;
//             padding-top: 2px; padding-bottom: 2px }` — the legitimate way to
//             add horizontal padding — still greens.
//       IT IS SOURCE-ORDER CORRECT, which the naive form is not. Requiring only
//       that the longhand be PRESENT would green `padding-top: 2px;
//       padding-bottom: 2px; padding: 3px 11px`, where the shorthand comes last
//       and wins the cascade — a false green. The longhand must appear AFTER
//       the shorthand it re-pins.
//       THE SHORTHAND SET IS PINNED AS A LITERAL (WRAP_CORE_SHORTHANDS), for
//       design choice 3's reason: derived from the copies it would shrink to
//       whatever they happen to use. It covers the physical shorthand, the
//       logical aliases and the `white-space` sub-longhands, because each of
//       them CAN set a core property's computed value and so can hide drift.
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
//   ONLY `.live-chip[data-state="stale"] .live-dot { background: … }` (re-derive:
//   grep -n '^\.live-chip\[data-state="stale"\] \.live-dot' app.css)
//   while the same-prefix `.live-chip[data-state="stale"] .live-chip-label` rule
//   on the NEXT line survived red NEITHER
//   check, so a state could lose its DOT colour — its one severity signal —
//   silently. That gap is now closed by a PER-DECLARATION probe in __app.test.mjs:
//   the test `every state's .live-dot rule DECLARES a background (per-declaration
//   fence)` loops hooks.liveDotStates, isolates each state's OWN `.live-dot {…}`
//   block (first-occurrence indexOf over the ` .live-dot {` marker, which skips the
//   `.live-dot.is-ping::after` decoy and the @media duplicate), and asserts a
//   `background:` declaration survives INSIDE it — so a background-ONLY deletion
//   reds as well as a whole-rule deletion. Mutation-proved: deleting that
//   `.live-dot` rule
//   reds it with `no .live-dot paint rule for the "stale" state … falls back to
//   var(--dim)` while the prefix fence stayed green. __css_check itself is
//   UNCHANGED and still never reads data-state — that E2 boundary declared above
//   stands; the closure lives in the app.js/app.css-paired test, not here.
//
//   @boundary capability:css-check-e2-attribute-blindness test:cloud/priv/static/__app.test.mjs#liveness chip: every state's .live-dot rule DECLARES a background (per-declaration fence)
//
// Zero dependencies. Run: node __css_check.mjs

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));

// ── THE MAIN GUARD (cch-bl-css-check-gate-body-not-importable) ─────────────
// TRUE only when this file IS the process entry point. The gate body at the
// bottom used to be bare top-level statements ending in process.exit(1), so
// `import`ing this module ran the whole gate over the importer's stdout and,
// on any error, NEVER RETURNED — which made every helper the file defines
// unreachable from a unit test. The cost was specific, not aesthetic: a REACH
// bug (the scan set quietly not looking at a kind of file) could only be
// caught by running the gate on a mutated mirror tree, so nothing cheap ever
// asked citationScanFiles() what it actually returns. With the body behind
// runGate(), __app.test.mjs asserts the SET directly.
//
// `node -e` leaves argv[1] undefined and `node --test x.test.mjs` sets it to
// the test file, so both read FALSE; a spawned `node <path>/__css_check.mjs`
// (including the mirror-tree harness, which copies this file to a tmpdir)
// reads TRUE, because argv[1] is already the resolved absolute path.
const IS_CLI = process.argv[1] ? import.meta.url === pathToFileURL(process.argv[1]).href : false;
// REFUSAL IS NOT A FINDING. Every sibling in this instrument family
// (__reason_arm_census, __me_envelope_census, __agent_event_vocabulary_census,
// __unknown_census, __binding_census) exits 2 when it cannot read its input,
// and the console-harness verdict wrapper maps 2→REFUSED / 1→MEASURED_DEFECT.
// This file's reads used to throw raw (uncaught ENOENT → exit 1), which
// reported "the tree has a measured defect" when the truth was "the instrument
// could not read its input". Exit 2 here, with the file named — a checker that
// cannot see its inputs must make NO claim about the tree, in either direction.

// ── THE ONE REFUSAL VOCABULARY (cch-w63-bl) ─────────────────────────────────
// EVERY exit-2 path in this file ends with exactly ONE line, on STDERR:
//
//     !! CSS CHECK (exit 2): REFUSED TO MEASURE — <reason>
//
// It is the same shape __preview__/exit-vocabulary.mjs already emits for the
// browser instruments, so ONE reader covers the whole console fence. Before
// this, six of console-unit's nine exit-2 sites spoke a private vocabulary
// (`REFUSED (2): …` with no `!!`) that no `!!`-anchored capture could see — a gate that CAPTURES the
// refusing instrument's own summary line would have replaced a wrong sentence
// with NO sentence, in the wave about silence.
//
// THE READER IS scripts/console-refusal-capture.mjs, and its unit test
// ENUMERATES this file from source: a new exit-2 path that does not go through
// `refuse2` reds that test. Do not add one.
const REFUSAL_NAME = "CSS CHECK";
const refuse2 = (reason) => {
  process.stderr.write(`!! ${REFUSAL_NAME} (exit 2): REFUSED TO MEASURE — ${reason}\n`);
  process.exit(2);
};

const readOrRefuse = (abs, label) => {
  try {
    return fs.readFileSync(abs, "utf8");
  } catch (e) {
    console.error(`FAIL(2): required input ${label} not readable at ${abs} — ${e.message}`);
    refuse2(`required input ${label} is not readable at ${abs} (${e.message}). __css_check will not report a result it could not measure.`);
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
  // gr-backlog-d24: `"dep-pill dep-"` stood here and is REMOVED with the family.
  // Deploy status chips now compose `status-pill status-pill--` like every other
  // status affordance, so they are covered by that entry below — and E19 would
  // red on this one anyway the moment the last emitting site went, which is the
  // durable half of the removal.
  "deploy-fail",       // deploy-fail row: + (failureTone === "blocked" ? " deploy-fail--blocked" : "")
  "deploy-console",    // + (open ? "" : " is-collapsed")
  "tier",              // + " tier-current" / " tier-free" conditionals
  "auth-tab",          // /new auth tabs: + (mode ? " is-active" : "")
  "new-console",       // + (collapsed ? " is-collapsed" : "")
  "new-step ",         // + cls (done | active | failed)
  "status-pill status-pill--", // statusPill(): + role (ok | info | warn | danger | neutral)
  // cch: `rollup-card rollup-card--` and `bp-tl-step bp-tl-step--` stood here and
  // were REMOVED. Neither head is emitted by app.js any more (rollupCard() and the
  // bp-tl-step row family are both gone), and none of the modifiers their comments
  // named had a rule anywhere. A waiver for a head nobody emits can never red, so
  // it is indistinguishable from one doing real work — and it would silently
  // pre-exempt the family the day the name came back. E19 below now makes that
  // shape red on its own, which is the durable half: this pair was found by a
  // person reading the list, the next one is found by the gate.
  "bp-console",                 // timelineConsoleHtml(): + (collapsed ? " is-collapsed" : "")
  "inst-tab",                   // instanceTabStripHtml(): + (on ? " is-active" : "")
  "wh-del-status wh-del-status--", // delivery status pill: + tone — the value space is NOT this comment's; it is WH_DEL_TONES below, and E15 checks it
  "tlv-badge tlv-badge--",      // tlvRowHtml(): + variant (event | verify | verify-fail | audit)
  "vf-chip vf-chip--",          // verifyChipHtml(): + role (pass | fail | unknown)
  "usage-card usage-card--",    // usageMeterHtml(): + rowTone (warn | over)
  // gr-w1 (cloud GUI remake): dynamic sites whose composed classes all have
  // rules in app.css today — verified via `.<family>` grep before allowing.
  // cch-r21l: `"inst-life-pill "` stood here and is REMOVED with the family. The
  // instance lifecycle chip now composes `status-pill status-pill--` like every
  // other state affordance (LIFECYCLE_PILL_ROLE -> statusMetaPill), so it is
  // covered by that entry above — and E19 would red on this one anyway the
  // moment the last emitting site went, which is the durable half of the removal.
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
  "dom-rung dom-rung--",           // domainRungChip(): + role — the value space is NOT this comment's; it is DOM_RUNG_ROLES below, and E18 checks it
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

// ── E13: the DEPLOY STATE GRAMMAR, derived instead of described ────────────
// This list began as the value space of a `dep-pill dep-` E3 allowlist entry:
// that entry waived the whole dynamic head, so before the list existed NOTHING
// checked which suffixes the head could take, and the comment on it claimed
// five statuses while the server had six — `cancelled` shipped with no rule at
// all and fell through to the .dep-pill base, which was byte-identical to
// .dep-queued, so a terminal abort painted as "still waiting". A comment cannot
// fail; this list can.
//
// gr-backlog-d24 kept the list and moved what it is CHECKED AGAINST. There is
// no `.dep-*` family any more: app.js's DEPLOY_STATUS_META maps each status
// below to a role (+ optional shape variant) in the one `.status-pill` family,
// and E13 now reads that table out of app.js and holds it total over this list.
// The list therefore states the server's value space and NOTHING about the
// mapping — which is the property that made the old check weak, because the
// mapping was spread across five hand-written class attributes.
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

// The CLOSED role set of the unified pill family. A sixth name here would be a
// hue invented at a call site instead of declared in the family, which is how
// two families happened the first time — so E13 arm (d) refuses it by NAME, not
// merely by "has a rule" (a typo'd role with a stray matching rule would pass
// the unpainted arm and still be wrong).
const STATUS_PILL_ROLES = ["ok", "info", "warn", "danger", "neutral"];

// app.js's DEPLOY_STATUS_META, read out of the source. DERIVED, never
// enumerated: an enumerated copy is the mapping somebody REMEMBERED, and the
// whole point of decision 24 is that there is exactly one place the mapping
// lives. Returns null when the table cannot be located or brace-matched — an
// empty scan is not a clean scan, so arm (a) makes that a hard error.
function deployStatusMetaTable(js) {
  return roleTableOf(js, "DEPLOY_STATUS_META");
}

// The same brace-matched read, for any `var <NAME> = { key: {role,variant}, … }`
// role table in app.js. cch-r21l added LIFECYCLE_PILL_ROLE as a second such
// table (the instance lifecycle chip's absorption into the .status-pill family),
// and a SECOND hand-rolled parser is a second thing to keep in step — so the
// deploy reader above is expressed through this one rather than beside it.
function roleTableOf(js, name) {
  if (js == null) return null;
  const start = js.indexOf(`var ${name} = {`);
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
  const body = js.slice(open + 1, i);
  const table = new Map();
  for (const m of body.matchAll(/([a-z][a-z0-9_]*)\s*:\s*\{([^{}]*)\}/g)) {
    const role = /\brole\s*:\s*"([a-z][a-z0-9-]*)"/.exec(m[2]);
    const variant = /\bvariant\s*:\s*"([a-z][a-z0-9-]*)"/.exec(m[2]);
    table.set(m[1], { role: role ? role[1] : null, variant: variant ? variant[1] : null });
  }
  return table.size === 0 ? null : table;
}

// The KEY SET of a flat `var <NAME> = { key: "…", … }` object in app.js. Used by
// E13 arm (g) to hold LIFECYCLE_PILL_ROLE's domain against LIFECYCLE_PILL_LABEL's,
// so a sixth lifecycle state cannot arrive with a label and no role (which would
// fall the chip through to a bare neutral pill — the impersonation shape).
function flatObjectKeys(js, name) {
  if (js == null) return null;
  const start = js.indexOf(`var ${name} = {`);
  if (start === -1) return null;
  let i = js.indexOf("{", start);
  const open = i;
  let depth = 0;
  for (; i < js.length; i++) {
    if (js[i] === "{") depth++;
    else if (js[i] === "}" && --depth === 0) break;
  }
  if (depth !== 0) return null;
  const body = js.slice(open + 1, i);
  const keys = new Set();
  for (const m of body.matchAll(/([a-z][a-z0-9_]*)\s*:/g)) keys.add(m[1]);
  return keys.size === 0 ? null : keys;
}

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

// ── E18: the .dom-rung-- ROLE SET, derived instead of described ─────────────
// `"dom-rung dom-rung--"` in ALLOW_PREFIXES waives the dynamic head, and until
// now the only statement about what it composes was that entry's own trailing
// comment. That comment named FIVE roles — ok | failed | active | pending |
// proxied — and domainStageRows folds SIX: it omitted `unknown`, which HAS had a
// rule since cch-w29, and it listed `pending`, which had NONE. So the comment was
// wrong in both directions at once, and nothing could tell you: a comment cannot
// fail. The set below is a DECLARATION only; emittedDomainRungRoles() reads the
// arms and E18 reds if the two disagree either way.
//
// WHY THIS ONE GETS NO CONSENT ARM EITHER, and the reason differs from E16's. On
// the fresh-badge family, a rule-less modifier IMPERSONATED a real state, because
// the bare .fresh-badge is itself the "never deployed" badge. Here the bare
// .dom-rung had no other consumer at all — domainRungChip always composes
// `dom-rung dom-rung--<role>`, and `pending` was the only one of the six roles
// that ever reached the base — so the fall-through was landing on the correct
// muted paint by luck, not by statement. That is a weaker defect than cch-w64's
// and it is recorded as such, but the remedy is the same: .dom-rung--pending is
// now authored explicitly, and arm (c) requires a rule for all six. Nothing is
// permitted to rely on an unwritten fall-through again.
const DOM_RUNG_ROLES = ["ok", "failed", "proxied", "pending", "unknown", "active"];

// The roles domainStageRows actually produces. Derived, never enumerated. The
// initializer is a ternary CHAIN, so the roles are read out of the RESULT
// positions only (`? "x"` arms and the trailing `: "x";` default) — never every
// string in the expression, which would also scoop up the `status === "…"`
// comparands and hand E18 a set wider than the code's. Reassignments (`role =
// "active"`, the markNextStep promotion) are read separately. Returns null when
// the function cannot be located or brace-matched; reports arm/assignment COUNTS
// beside the literals so an arm this reader cannot follow is a hard error rather
// than a silently shorter set — an empty scan is not a clean scan.
function emittedDomainRungRoles(js) {
  const start = js.indexOf("function domainStageRows(");
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

  const initStart = body.search(/\bvar\s+role\s*=/);
  if (initStart === -1) return null;
  const initEnd = body.indexOf(";", initStart);
  if (initEnd === -1) return null;
  const init = body.slice(initStart, initEnd + 1);

  const roles = new Set();
  // Ternary result arms: `? "ok"`.
  const armLits = [...init.matchAll(/\?\s*"([a-z][a-z0-9-]*)"/g)];
  for (const m of armLits) roles.add(m[1]);
  // The chain's trailing default: `: "unknown";`.
  const tail = init.match(/:\s*"([a-z][a-z0-9-]*)"\s*;\s*$/);
  if (tail) roles.add(tail[1]);
  const arms = (init.match(/\?/g) || []).length;

  // Reassignments elsewhere in the body (the `active` promotion).
  const reassigns = [...body.slice(initEnd).matchAll(/(?:^|[^.\w$])role\s*=(?!=)/g)].length;
  const reassignLits = [...body.slice(initEnd).matchAll(/(?:^|[^.\w$])role\s*=\s*"([a-z][a-z0-9-]*)"/g)];
  for (const m of reassignLits) roles.add(m[1]);

  return {
    roles,
    arms,
    armLiterals: armLits.length,
    tail: !!tail,
    reassigns,
    reassignLiterals: reassignLits.length,
  };
}

// Classes that intentionally have no style rule: they are JS/structural hooks
// (selector targets, event delegation markers), not visual classes. Each is
// printed on every run, and E20 below now REQUIRES each to fire: removing the
// hook from the markup no longer merely "should" remove the entry, it reds the
// gate until someone does.
//
// THE ENTRY THIS ARM FOUND ON ITS FIRST RUN: "notif-smtp", carrying the reason
// `querySelector(".notif-smtp") — SMTP fieldset container`. The console never
// emitted it as a class; notifEmailSectionHtml() writes `id="notif-smtp"` (grep
// -n 'function notifEmailSectionHtml' app.js) and every reader is the ID
// selector `$("#notif-smtp")` — `grep -n 'notif-smtp' app.js` shows every site
// is `#notif-smtp` or a `notif-smtp-*` input id, and none is a class. So
// the entry waived nothing and its stated reason was false in the same breath,
// which is the whole reason a list needs an arm rather than a convention.
const ALLOW_HOOK_CLASSES = [
  "view",              // section container app.js shows/hides per route ($$(".view"))
  "modal-body",        // openModal() innerHTML target (selected by #modal-body)
  "session-revoke",    // querySelectorAll(".session-revoke") — revoke button in the sessions panel
  "token-revoke",      // querySelectorAll(".token-revoke[data-id]") — per-token revoke button
  "token-ab",          // querySelectorAll(".token-ab") — ability checkboxes in the new-token modal
  "fleet-open-studio", // querySelectorAll(".fleet-open-studio") — Open Studio button per fleet row
  "new-plan",          // querySelectorAll(".new-plan") — plan-choice buttons on the /new pricing step
  "wh-event-cb",       // querySelectorAll(".wh-event-cb") — event checkboxes in the create-webhook modal
  "launch-region",     // querySelector(".launch-region") — region <select>, styled by .form-input; S7 change hook
  "launch-connect-provider", // querySelector(".launch-connect-provider") — connect CTA, styled by .btn; S7 click hook
  "launch-catalog-retry",    // querySelector(".launch-catalog-retry") — retry button, styled by .btn; S7 click hook
  "tier-free",         // querySelector(".tier-free .btn") in __preview__/breakpoint-sweep.mjs (tierLabelProbeJs) — the tier-floor-render probe's Free-tier anchor; styled by .tier/.btn, no rule of its own
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
  { fg: "--dim", bg: "--surface", min: 4.5, why: ".status-pill--stopped pill text (a cancelled deploy) — the chip is hollow (background: transparent), so its label composites straight onto the .deploys card" },
  { fg: "--primary-fg", bg: "--primary", min: 4.5, why: "avatar label / step dots" },
  { fg: "--btn-fg", bg: "--btn-bg", min: 4.5, why: ".btn-primary label" },
  { fg: "--btn-danger-fg", bg: "--btn-danger-bg", min: 4.5, why: ".btn-danger label" },
  { fg: "--primary", bg: "--bg", min: 4.5, why: "links" },
  { fg: "--primary", bg: "--surface", min: 4.5, why: "links on cards" },
  { fg: "--ok", bg: "--surface", min: 4.5, why: "success text (.plan-rec, .new-eyebrow.ok)" },
  { fg: "--ok-strong", bg: "--ok-soft", over: "--surface", min: 4.5, why: ".runway-sub trial chip (green=accent: strong text voice on the soft tint, GR6)" },
  { fg: "--danger", bg: "--surface", min: 4.5, why: "error text (.deploy-fail, .wh-del-err)" },
  { fg: "--danger", bg: "--danger-soft", over: "--surface", min: 4.5, why: ".wh-del-status--danger / .tlv-badge--verify-fail / .dom-rung--failed text on a soft danger tint" },
  { fg: "--warn-strong", bg: "--warn-soft", over: "--surface", min: 4.5, why: ".deploy-fail--blocked text on a soft warn tint" },
  // cch-w64-s6: `.dep-deferred` keeps the warn hue but gives up the filled chip
  // (it no longer holds a build slot), so its ground is the CARD itself — the
  // one pair the tinted variant would not have owed.
  { fg: "--warn-strong", bg: "--surface", min: 4.5, why: ".status-pill--warn.status-pill--hollow pill text (a deferred deploy) on an open chip" },
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
// EVERY PROPERTY THAT CAN SET A CORE PROPERTY WITHOUT NAMING IT — the physical
// shorthand, the logical aliases (`writing-mode: horizontal-tb` is the console's
// only mode, so block-start/end ARE top/bottom here) and `white-space`'s own
// sub-longhands. Pinned as a literal for design choice 3's reason. A rule that
// declares any of these is a wrap copy and owes the longhand RESTATED AFTER it;
// nothing here is value-parsed. Ruling and the rejected alternative: the
// SHORTHAND paragraph of this file's E14 header entry.
const WRAP_CORE_SHORTHANDS = [
  ["padding", ["padding-top", "padding-bottom"]],
  ["padding-block", ["padding-top", "padding-bottom"]],
  ["padding-block-start", ["padding-top"]],
  ["padding-block-end", ["padding-bottom"]],
  ["block-size", ["height"]],
  ["min-block-size", ["min-height"]],
  ["white-space-collapse", ["white-space"]],
  ["text-wrap", ["white-space"]],
  ["text-wrap-mode", ["white-space"]],
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
// cch-w24-s2 added `.detail-title-row` as the FIFTH copy — a COMMA MEMBER of
// the `.instance-card-head` prelude, not a new block (Δheads 0). It was
// COUNTED (the harness's same-file count pin went 4 -> 5) but not REQUIRED,
// so a scan degrading to 4-of-5 that lost exactly the failed instance's OWN
// detail header — the one screen a person opens to read WHY provisioning
// failed — still reported clean. `cch-w24-bl-detail-title-row-not-a-required-
// wrap-host` closes that, and the cascade is the point: every fixture
// stylesheet E14 runs against now owes the fifth copy, which is what makes a
// required host a pin rather than a note.
const WRAP_REQUIRED_HOSTS = [".attention-row", ".detail-rail", ".detail-title-row", ".fleet-status", ".instance-card-head"];
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
    // Source POSITION of each property's LAST declaration. The shorthand arm is
    // order-sensitive by construction (a longhand only re-pins a shorthand that
    // came BEFORE it), so position is data, not decoration.
    const posOf = new Map();
    let nth = 0;
    for (const seg of body.split(";")) {
      const c = seg.indexOf(":");
      if (c === -1) continue;
      const prop = seg.slice(0, c).trim().toLowerCase();
      if (!/^[a-z-]+$/.test(prop)) continue;
      declared.set(prop, seg.slice(c + 1).trim().replace(/\s*!important$/, ""));
      posOf.set(prop, nth++);
    }
    // DESIGN CHOICE 1 — the trigger is the DECLARATION, not the selector. A
    // wrapper-scoped rule that touches none of the five is not a wrap copy and
    // is not even counted. A core SHORTHAND counts as declaring the core: it is
    // how a fourth copy used to go invisible (see the header's SHORTHAND
    // ruling), so the trigger reads the shorthand set too.
    const startedWith = [
      ...WRAP_CORE.filter(([p]) => declared.has(p)).map(([p]) => p),
      ...WRAP_CORE_SHORTHANDS.filter(([p]) => declared.has(p)).map(([p]) => p),
    ];
    if (!startedWith.length) continue;
    // Which core longhands are set through a shorthand and NOT re-pinned in
    // longhand at the canonical value after it. No shorthand value is parsed —
    // remedy (b), not remedy (a).
    const shadowedBy = new Map();
    for (const [sp, longs] of WRAP_CORE_SHORTHANDS) {
      const at = posOf.get(sp);
      if (at === undefined) continue;
      for (const [lp, canonical] of WRAP_CORE) {
        if (!longs.includes(lp)) continue;
        const li = posOf.get(lp);
        if (li !== undefined && li > at && declared.get(lp) === canonical) continue;
        shadowedBy.set(lp, sp);
      }
    }
    for (const part of prelude.split(",")) {
      const hit = part.match(WRAPPER_SCOPED_PILL);
      if (!hit) continue;
      const selector = part.trim().replace(/\s+/g, " ");
      const line = lineOf(stripped, m.index + prelude.indexOf(part.replace(/^\s+/, "")));
      copies.push({ selector, host: hit[1].trim().replace(/\s+/g, " "), line, declared });
      const missing = WRAP_CORE.filter(([p, v]) => declared.get(p) !== v || shadowedBy.has(p)).map(
        ([p, v]) =>
          `${p}: ${v} (${
            shadowedBy.has(p)
              ? `set through the shorthand \`${shadowedBy.get(p)}: ${declared.get(shadowedBy.get(p))}\`, ` +
                `which E14 does not parse — restate \`${p}: ${v}\` in longhand AFTER that shorthand`
              : declared.has(p)
                ? `declared "${declared.get(p)}"`
                : "not declared"
          })`,
      );
      if (missing.length) {
        errs.push(
          `E14 ${file}:${line}  ${selector} declares ${startedWith
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
// prototyped and REJECTED: a {string, //, /* */} state machine over the ~1,651 KiB
// of app.js (template literals, regex literals) desyncs and MISSES real citations
// — a false-negative in a tripwire, the exact disease this epic removes. Full
// text cannot desync and cannot miss a citation that migrates into a string.
// THAT SIZE IS MEASURED, AND THE PREVIOUS ONE WAS NOT: this sentence said
// "893 KB" long after the file had nearly doubled past it. Re-derive it, never
// quote it forward — `wc -c cloud/priv/static/app.js` reads 1,690,235 bytes at
// the commit that corrected this line. A justification carrying a number that
// is half of reality is the same shape as an allowlist entry that waives
// nothing: still persuasive, no longer true, and nothing in the run checks it.
// The shape `app.js:<digits>` is citation-specific: measured on this tree every
// one of the seven live occurrences is a comment citation, zero are in code, so
// full-text scanning is both robust AND false-positive-free today.
//
//   COVERAGE BOUNDARY (charter D40 — an enforcement mechanism states its limits):
//     • CROSS-LANGUAGE `.ex`/`.exs` cites are OUT. Re-anchoring a JS comment
//       that points at Elixir source means grepping a file OUTSIDE
//       cloud/priv/static — a distinct move, owned by
//       cch-bl-citation-drift-cross-language. E11's alternation names only
//       same-tree extensions (.js/.mjs/.css/.sh), so `router.ex:<line>` and
//       friends stay UNFLAGGED here BY DESIGN. The live population is stated as
//       a DERIVATION, never a count — every figure ever written for it (3, then
//       5) was false by the next merge. Re-derive it with:
//         grep -rnE '\.(ex|exs):[0-9]{2,}' cloud/priv/static \
//           --include='*.mjs' --include='*.js' --include='*.css'
//     • FOREIGN FROZEN ARTIFACTS ARE OUT. `*.html:<line>` cites point at
//       design/handover/…/*.dc.html — a frozen handover artifact outside this
//       directory that does not receive the sibling shifts app.css does. Not in
//       the alternation; not a citation to E11.
//     • `.sh` AND EVERY OTHER TEXT SIDECAR ARE NOW SCANNED — THE ASYMMETRY IS
//       GONE (cchi-w18). This bullet used to record the opposite: the scan set
//       matched an allowlist of three extensions, so a shell instrument's own
//       cites, and every recorded `.baseline`, were STRUCTURALLY UNREACHABLE at
//       any regex width while a cite of the same shape one file away reddened.
//       That was the REACH-not-SHAPE defect charter D292 fixed for app.css,
//       left standing for everything else. citationScanFiles() now admits any
//       TEXT file in the two arms (see the predicate above), which closed it and
//       surfaced fourteen live citations across three previously-unreachable
//       files — all re-anchored in the same commit that widened the set, so the
//       widened guard is green here rather than vacuous, exactly as D292 was.
//       Re-derive the set and its per-file cross with
//       `node __css_check.mjs --citation-inventory`. Rows:
//       cch-w17-bl-e11-scan-set-app-css-and-shoot-sh (app.css + shoot.sh) and
//       cchi-w18-bl-e11-scan-set-third-blind-spot-baseline (the baselines).
//     • THE BARE ANCHOR — A KNOWN-UNREACHABLE FORM, NOT AN OVERSIGHT. A
//       citation that drops the filename and keeps only the number, written as
//       a colon or a parenthesised colon immediately before the digits, carries
//       NO filename for any filename-anchored regex to bind to, so it is
//       unreachable at every regex width AND at every scan-set width — widening
//       the FILE SET (which this gate now does by text shape) cannot reach it
//       either, because the defect is in the CITATION, not in the reach. It is
//       the same class as the `if $. == <n>` recipe. Banning it is NOT free and
//       is deliberately NOT done: the shape collides with legitimate CSS and
//       prose (a bare number after a colon is a declaration value, a port, a
//       viewport width, a byte count), so a ban here would be a false-positive
//       engine rather than a tripwire. Re-derive the live population — never
//       quote a count, every figure written for one in this tree has gone stale:
//         grep -cP '(?<![A-Za-z0-9_.\-]):\d{3,5}-\d{3,5}' app.css   # bare ranges
//         grep -oP '\(:\d{3,5}\)' app.css | wc -l                    # bare singles
//       Owner row: cchi-w18-bl-e11-scan-set-third-blind-spot-baseline.
//     • app.css's OWN self-citations are DEFERRED, and the deferral is a SHAPE
//       exemption, not a set exclusion. app.css joined the scan set in D292 so
//       that `app.js:<n>` inside the stylesheet reds — that stays. The WIDENED
//       shapes (`app.css:<n>` and `<name>.<ext>:<n>`) are skipped for app.css
//       itself: re-anchoring them is a comment-only edit to this wave's most
//       contended file, which would serialize a gate change behind every CSS
//       slice in flight for zero measurement value. Same owner row as shoot.sh
//       above. `--citation-inventory`'s `ruled` column still COUNTS them, so
//       the deferral is visible in a run rather than invisible in a regex.
//     • SHAPE-SCOPED, AND THE SEPARATOR IS DELIBERATELY ASYMMETRIC. Loose
//       `[:~ ]+~?` for the `app.js` branch; tight `(?::~?|\s~)` for every
//       widened target. This is a design choice, not an accident. The loose
//       form is safe for `app.js` (nobody writes "app.js <n>" as prose) and the
//       shipped gate already catches the bare-space, the double-space-tilde and
//       the range forms of `app.js` + a number — a tight-everywhere regex would
//       DROP all three, a net loss. The three forms are NOT spelled out as
//       literal examples anywhere, and no fixture holds them: EVERY file in the
//       scan set — this one, the test file, the harness sidecars — would red E11
//       against ITSELF for writing one, which is why the test that needs a
//       banned citation assembles it from parts at runtime instead of typing it
//       (grep -n "NEVER WRITTEN WHOLE" __app.test.mjs). The separator forms are
//       therefore DEFINED HERE AND ONLY HERE, as the two separator branches of
//       the alternation itself:
//         grep -n "^const CITATION_RULED_ALTERNATION" __css_check.mjs
//       That single line IS the enumeration; diff its `app.js` branch's
//       separator class against the widened branch's and the asymmetry this
//       paragraph describes is the difference between them. If you came here
//       looking for a fixture that lists the forms, there is none, and inventing
//       one to satisfy a recipe would put a banned citation into the scan set.
//       Loose for the new targets is toxic: it reds the `app.css <bytes> B`
//       size records in __preview__/cssom-heads.baseline (count them, never
//       quote them: `grep -cE 'app\.css [0-9]+ B' __preview__/cssom-heads.baseline`
//       — the sidecar gains a record on every wave that re-measures) plus
//       `app.css: 620` INSIDE a scanned file, __preview__/breakpoint-sweep.mjs.
//       That last one is the decisive argument: it is not a sidecar false
//       positive, it would red the gate. A prose reference like "the app.js
//       file" is untouched; a NON-numeric anchor (a function name + grep) is
//       exactly what E11 asks for. It cannot judge whether a cited function
//       name is itself correct — that is a semantic claim no regex owns.
export function bannedSourceCitationErrors(src, file) {
  const errs = [];
  const base = String(file).replace(/\\/g, "/").split("/").pop();
  for (const m of src.matchAll(CITATION_RULED_ALTERNATION)) {
    // app.css's own widened-shape cites are deferred (see the boundary above).
    // `app.js:<n>` inside app.css still reds — that is D292's whole point.
    if (base === "app.css" && !m[0].startsWith("app.js")) continue;
    const line = src.slice(0, m.index).split("\n").length;
    errs.push(
      `E11 ${file}:${line}  banned source line citation ${JSON.stringify(m[0].trim())} — ` +
        `line numbers rot on any sibling shift (charter D41 / bp-honest-gates D5). ` +
        `Re-anchor to the enclosing FUNCTION name (or, for a stylesheet, the SELECTOR) ` +
        `plus a grep that re-derives it ` +
        `(e.g. renderLivenessChip() with grep -n 'function renderLivenessChip'). ` +
        `Cross-language .ex cites are OUT (cch-bl-citation-drift-cross-language).`,
    );
  }
  return errs;
}

// The files E11 scans: every TEXT file anywhere under the scan root. Both
// halves of that sentence are predicates — the shape half (is it text?) and the
// reach half (is it under the root?) — because a list of extensions and a list
// of directory arms are the same enumerate-don't-ban shape bp-honest-gates D5
// forbids, and BOTH of them rotted here, in that order. A new harness file, and
// now a whole new harness SUBDIRECTORY, is covered the moment it lands.
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
// THE SCAN PREDICATE IS A RULE, NOT AN EXTENSION LIST (charter D41 /
// bp-honest-gates D5: "ban the SHAPE, do not enumerate"). This filter read
// `/\.(m?js|css)$/` — an ALLOWLIST OF THREE EXTENSIONS — so every sidecar,
// shell instrument and recorded baseline in the same two directories was
// structurally unreachable at any regex width, exactly the REACH-not-SHAPE
// defect D292 fixed for app.css and the coverage boundary above filed against
// itself. An extension list is a SNAPSHOT: it covers what existed the day it
// was written, and a new sidecar lands unscanned and silent.
//
// The replacement asks the only question E11 actually needs answered — CAN
// THIS FILE CARRY A CITATION, i.e. is it text? — and asks it of the BYTES,
// never of the name. A NUL byte in the sniff window is the binary signal
// (favicon.ico is the one member of these two directories it excludes today;
// re-derive that with `node __css_check.mjs --citation-inventory`). Anything
// textual is in, whatever it is called, the day it lands.
//
// WHY NOT A SKIP LIST OF BINARY EXTENSIONS. Same disease, opposite sign: a
// two-item skip list in this repo turned out to really be eight. The bytes
// cannot go stale; a list of names always does.
const CITATION_TEXT_SNIFF_BYTES = 4096;
function isTextFile(abs) {
  let fd;
  try {
    fd = fs.openSync(abs, "r");
  } catch {
    return false;
  }
  try {
    const buf = Buffer.alloc(CITATION_TEXT_SNIFF_BYTES);
    const n = fs.readSync(fd, buf, 0, CITATION_TEXT_SNIFF_BYTES, 0);
    return buf.subarray(0, n).indexOf(0) === -1;
  } catch {
    return false;
  } finally {
    fs.closeSync(fd);
  }
}

// THE REACH IS A RULE TOO, NOT A LIST OF ARMS (the second half of the same
// defect). The predicate above fixed WHAT SHAPE of file is admitted; this walk
// fixes WHERE the gate is allowed to look. It used to be exactly two
// readdir calls — the scan root and `__preview__/` — which is an ENUMERATION
// wearing a derivation's clothes: it covers the directories that existed the
// day it was written, and every subdirectory that lands afterwards is
// structurally unreachable at any regex width and at any text predicate. That
// is not a hypothetical. While the text-shape widening was in flight, this tree
// already held nested fixture subtrees under `__preview__/fixtures/` (each with
// its own recorded baseline and proof script), a top-level `__fixtures__/`, and
// `fonts/` — none of which either arm descends into. A two-arm list had already
// failed before the change that introduced it finished merging.
//
// The replacement asks the only question REACH needs answered — IS THIS FILE
// UNDER THE SCAN ROOT? — and answers it by descending, so a new subdirectory is
// covered the day it lands rather than the day someone remembers to add an arm.
//
// EVERY EXCLUSION IS A PREDICATE WITH GROUNDS. There is no name list here, and
// deliberately none for `node_modules/` or build output: neither exists under
// this root, and a named exclusion for a thing that is not there can never fire
// — E19's own shape (a waiver that absolves nothing), one level up at the
// directory. The three that DO fire are properties of the entry itself:
//
//   1. NOT A REGULAR FILE (after directories are descended). A socket, FIFO or
//      device node carries no reviewable comment and opening one can BLOCK the
//      gate forever. Judged from the dirent, never from the name.
//   2. A SYMBOLIC LINK, of either kind. A link can point outside the tree
//      (scanning files this gate does not own) or back into it (an unbounded
//      walk, and the same file counted under two names, so one repair reads as
//      two). A link TARGET that genuinely lives under this root is still
//      scanned — under its own real path, exactly once.
//   3. BINARY BYTES — the NUL sniff above. Unchanged, and it is what keeps the
//      newly reachable `fonts/*.woff2` out by their CONTENT rather than by
//      their extension.
//
// Re-derive the whole set, and what the widening cost, with
// `node __css_check.mjs --citation-inventory` — never from a number quoted here.
export function citationScanFiles(root = dir) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  const walk = (absDir, rel) => {
    let entries;
    try {
      entries = fs.readdirSync(absDir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      if (ent.isSymbolicLink()) continue; // exclusion 2
      const abs = path.join(absDir, ent.name);
      const childRel = rel ? path.join(rel, ent.name) : ent.name;
      if (ent.isDirectory()) {
        walk(abs, childRel);
        continue;
      }
      if (!ent.isFile()) continue; // exclusion 1
      if (!isTextFile(abs)) continue; // exclusion 3
      out.push(childRel);
    }
  };
  walk(root, "");
  return out.sort();
}

// E17 — THE SCAN SET IS A CLAIM, AND NOTHING CHECKED IT (charter D41 /
// bp-honest-gates D5). citationScanFiles() derives its list from one recursive
// walk under one root, filtered by one text predicate, and every part of that
// can silently produce nothing: a renamed or moved `__preview__/`, a predicate
// edited to a shape no file matches, a descent quietly flattened back to a
// readdir of the root, a scan rooted somewhere else. E11 then iterates an empty list
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
export function citationScanSetRefusals(files, root = dir) {
  const out = [];
  if (!files.length) {
    return [
      `E17 ${root}  citation scan set is EMPTY — E11 would have reported a clean census over ` +
        `ZERO files. Membership here is an invariant, not a mechanism: a file is in the set ` +
        `when it lives under this scan root and its bytes read as text. So an empty set means ` +
        `one of exactly two things — nothing lives under this root (missing, moved, or bare), ` +
        `or nothing under it reads as text. Re-derive with: node __css_check.mjs ` +
        `--citation-inventory ${root}. A green over an empty set is not a green.`,
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
  // THE DESCENT ARM. The reach half of the derivation collapses in a way the
  // two arms above cannot see: flatten the walk back to a readdir of each arm's
  // own directory and every member is still present at depth 0 and depth 1, so
  // both totals stay healthy while every nested fixture subtree — its recorded
  // baselines, its proof scripts — silently stops being scanned. A set with no
  // member below the first level is either that collapse or a tree with no
  // nested content at all; both are worth a named refusal rather than a clean
  // census, for the same reason the arms above are.
  if (!files.some((f) => f.split(path.sep).length > 2))
    out.push(
      `E17 ${root}  citation scan set has ZERO members below the first level — the recursive ` +
        `descent in citationScanFiles() collapsed (a walk flattened back to a readdir per arm ` +
        `reads here exactly like a tree with no subdirectories), so every nested fixture ` +
        `subtree went unscanned while E11 still reported a count. ` +
        `Re-derive with: node __css_check.mjs --citation-inventory`,
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
// carried by cch-w16-s7. IT IS WHAT E11 ENFORCES, as of that row's build:
// bannedSourceCitationErrors above matches against THIS constant, so there is
// exactly one citation shape in this file and no second copy to drift. Loose
// separator for the `app.js` branch (the form the shipped gate already caught,
// and which the "prescribed" tight-everywhere regex would have DROPPED — the
// bare-space, the double-space-tilde and the range forms alike, a net loss), tight
// `(?::~?|\s~)` for every widened target so that prose like "the app.css 273 raw
// px font-size lines" and the sidecar's `app.css <bytes> B` records stay clean.
//
// IT IS A `const` DECLARED BELOW ITS ONLY OTHER CONSUMER ON PURPOSE — every call
// site (the inventory mode, runGate() at the bottom, external importers) runs
// after module evaluation has reached this line, so the TDZ window is empty.
// Keeping the regex beside its ruling prose beats splitting the argument from
// the pattern.
//
// IT LIVES HERE, NOT IN A TASK ROW, BECAUSE EVERY QUOTED FIGURE FOR IT HAS
// ROTTED. The widening's cost has been recorded as 8, then 14, then 16/18, then
// 19, then 20 — five numbers, each true the day it was written and false by the
// next merge. --citation-inventory emits the figure as a RUN instead, so the
// only way to cite it is to re-derive it.
const CITATION_RULED_ALTERNATION = /\b(?:app\.js[:~ ]+~?|(?:app\.css|[\w.-]+\.(?:js|mjs|sh))(?::~?|\s~))\d{2,}(?:-\d{2,})?/g;

// ── SYNCHRONOUS OUTPUT FOR THE FOUR spawnSync-CONSUMED SUB-MODES ────────────
//
// THE DEFECT THIS DELETES (studio r21d, task-a510820f5b757050). Each of the
// four targeted sub-modes below ends in `process.exit(...)`, and every one of
// them is consumed by `__app.test.mjs` through a `spawnSync` whose stdout is a
// PIPE. On this platform a child's stdout to a pipe is NON-BLOCKING and
// ASYNCHRONOUS, so `console.log` does not write — it QUEUES. `process.exit()`
// tears the process down without draining that queue, and every byte still
// sitting on it is DISCARDED. The consumer sees a clean, well-formed,
// SHORTER-THAN-TRUE report and cannot tell it apart from a real one.
//
// MEASURED, NOT ASSUMED. The pipe's buffer here is 8192 bytes: a child that
// emits 9000+ bytes and then calls process.exit(0) delivers exactly 8192 to a
// spawnSync parent, 8 runs out of 8, at every size from 9000 up to 660000.
// Below the buffer size nothing is ever lost. The inventory sub-mode emits 9624
// bytes over this tree — 1432 bytes MORE than the buffer — so it survives only
// while the parent keeps draining mid-stream. It usually does, which is why 280
// isolated spawns found nothing; under the full harness, where the parent is
// busy, the observed rate was 1 red in 14 runs. The captured stdout of that red
// stopped at 8154 bytes — the last whole row that fits under 8192. The cut is
// the buffer boundary, not a scan that ended early.
//
// WHY THIS DRAINS RATHER THAN RACES. `fs.writeSync` hands the bytes to the
// KERNEL before it returns, so when the loop finishes there is nothing left on
// any JS-side queue for process.exit to throw away — no callback to schedule,
// no event-loop turn to lose, no drain event to miss. The two ways a
// non-blocking fd can decline are both handled as WAITING, never as dropping: a
// PARTIAL write advances the offset and re-offers only the remainder, and
// EAGAIN (the reader is behind) sleeps a millisecond and re-offers the SAME
// remainder. The loop does not terminate until the kernel has accepted every
// byte. EPIPE is the one honest stop: the reader is gone, so there is no
// consumer left to shorten a report for.
//
// USE THESE, NOT console.log / console.error, inside any block that ends in
// process.exit(). Mixing the two REORDERS output, because console.* queues on
// the stream and these bypass it.
const SUBMODE_BACKOFF = new Int32Array(new SharedArrayBuffer(4));
const emitSync = (fd, text) => {
  const buf = Buffer.from(text, "utf8");
  let off = 0;
  while (off < buf.length) {
    try {
      off += fs.writeSync(fd, buf, off, buf.length - off);
    } catch (e) {
      if (e.code === "EAGAIN") {
        Atomics.wait(SUBMODE_BACKOFF, 0, 0, 1);
        continue;
      }
      if (e.code === "EPIPE") return;
      throw e;
    }
  }
};
const outSync = (line) => emitSync(1, line + "\n");
const errSync = (line) => emitSync(2, line + "\n");

// Targeted fixture mode: `node __css_check.mjs --swallow-check <file.css>` runs
// ONLY the E9 parse-completeness guard against one file and exits non-zero if it
// fires — the committed #4251 regression proof (see __css_check.fixture.css).
{
  const i = process.argv.indexOf("--swallow-check");
  if (i !== -1) {
    const f = process.argv[i + 1];
    const errs = swallowedTokenErrors(readOrRefuse(f, f), path.basename(f));
    for (const e of errs) errSync("FAIL  " + e);
    outSync(`__css_check --swallow-check ${f}: ${errs.length} E9 error(s)`);
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
    for (const e of errs) errSync("FAIL  " + e);
    outSync(`__css_check --orphan-check ${f}: ${errs.length} E10 error(s)`);
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
    for (const e of errs) errSync("FAIL  " + e);
    outSync(
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
// WHY A SUB-MODE AS WELL AS AN EXPORT. `citationScanFiles` is exported now (the
// gate body sits behind IS_CLI, so an importer gets control back), but the
// sub-mode is NOT redundant: it reports the set as the CLI process actually
// derives it, which is the only way to check the export against the thing the
// gate runs — __app.test.mjs asserts list equality between the two. It is also
// immune to the gate's exit status by construction and is spawnSync-able, which
// matters exactly when the gate is red: the widening commit reds it by
// construction, and that is the moment the inventory is wanted.
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
    outSync(`__css_check --citation-inventory ${root}`);
    for (const rel of files) {
      const src = readOrRefuse(path.join(root, rel), rel);
      const shipped = bannedSourceCitationErrors(src, rel).length;
      const hits = [...src.matchAll(CITATION_RULED_ALTERNATION)];
      shippedTotal += shipped;
      ruledTotal += hits.length;
      outSync(
        `  ruled=${String(hits.length).padStart(3)}  E11=${String(shipped).padStart(3)}  ${rel}`,
      );
      for (const m of hits) outSync(`        ${rel}:${lineOf(src, m.index)}  ${JSON.stringify(m[0].trim())}`);
    }
    for (const e of refusals) errSync("FAIL  " + e);
    outSync(
      `__css_check --citation-inventory ${root}: ${files.length} file(s) scanned ` +
        `(${files.filter((f) => !f.includes(path.sep)).length} at the root, ` +
        `${files.filter((f) => f.startsWith(PV)).length} under __preview__/, ` +
        `${files.filter((f) => f.split(path.sep).length > 2).length} below the first level), ` +
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
// does (the animated conic-ring fill --p; grep -n '^@property --p ' app.css).
// The name is followed
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
//
// THE ESCAPE MUST BE ABLE TO PAINT (cch-w12-bl-e12-blind-to-border-width). The
// escape used to be granted by reading the ALPHA of a colour out of the focus
// rule's OWN block and nothing else. A colour is not an indicator: a
// `border-color` on an edge whose width is 0 or whose style is `none` paints
// exactly nothing, and the guard certified it. PROVEN BY MUTATION on the
// pre-fix tree: with `.fleet-row { border: 0 }` and
// `.fleet-row[data-id]:focus-visible { outline: none; border-color: var(--ring);
// box-shadow: 0 0 0 2px var(--ring-soft) }` left verbatim, __css_check exited 0
// with 0 error(s) — a focused row with NO indicator at all, blessed. It was not
// hypothetical either: `.inst-sites-card .site-row { border: none; …;
// border-top: 1px solid var(--border) }` left three of four sides at `0px none`
// under the shared focus rule, and only the rendered driving of
// cch-w12-s3-sites-card-focus-perimeter found it.
//
// SO THE ESCAPE NOW RESOLVES THE BOX, NOT THE BLOCK. For the focus rule's
// SUBJECT (the selector with its focus pseudo-classes stripped) E12 resolves
// `border-width` / `border-style` — and `outline-width` / `outline-style` for an
// `outline-color` escape — across every rule in the owned sources that can apply
// to that subject, in cascade order (specificity, then source order), with the
// focus rule's own block applied last because it wins while focused. The escape
// holds only if ALL FOUR sides paint. Three sides are not a perimeter, and the
// one shipped case that exploited this was exactly a top-only hairline.
//
// TWO THINGS MAKE IT SEE `.inst-sites-card`, and both are load-bearing:
//   • A rule is RELEVANT when its LAST compound is a token-subset of the
//     subject's last compound — it constrains the subject element with a subset
//     of what the subject requires, so it matches a superset of elements there.
//     `.site-row` is relevant to `.site-row[data-id]`; `.fleet-row` is not.
//   • Extra ANCESTOR steps do not make a rule irrelevant, they make it
//     CONDITIONAL. `.inst-sites-card .site-row` applies to SOME of the elements
//     `.site-row[data-id]` matches, so it is evaluated as its own CONTEXT:
//     unconditional rules, plus that one, plus the focus rule. A context in
//     which the escape cannot paint is a red, because a keyboard user in that
//     context has no indicator. Checking only the unconditional cascade would
//     have missed the one defect that actually shipped.
//
// THE DEFAULT IS UNPAINTABLE, DELIBERATELY. `border-*-style`'s initial value is
// `none`, so a subject that no rule gives a border to fails the escape. That is
// the correct answer, not a false red: a rule claiming "my indicator is the
// border" when nothing anywhere gives the element a border has no indicator.
//
// COVERAGE BOUNDARY (charter D40 — a check states what it does NOT own):
//   • It reads @media-conditioned rules UNCONDITIONALLY. A `border: 0` that
//     only lands under a breakpoint is a real loss of the indicator at that
//     width, so counting it is right; but it cannot say "only below 700px".
//   • It ignores `!important` ordering and the logical box properties
//     (`border-block`, `border-inline`): neither appears in the owned sources,
//     and both would need the same widening if one ever does.
//   • A width that is a `var()` or a `calc()` is treated as NON-zero — it
//     cannot resolve one statically, and guessing zero would be a false red in
//     a tripwire.
//   • It cannot know the DOM. A subject whose border arrives from a class the
//     element also carries but no selector here mentions is a FALSE POSITIVE;
//     the honest fix is that rule paying its own indicator, not an allowlist.
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

/** Border/outline styles that paint nothing however wide the edge is. */
const UNPAINTABLE_STYLES = new Set(["none", "hidden"]);
const BORDER_STYLE_KEYWORDS = new Set([
  "none", "hidden", "dotted", "dashed", "solid", "double", "groove", "ridge", "inset", "outset",
]);
const SIDES = ["top", "right", "bottom", "left"];
/** One simple selector: attribute, pseudo, id/class, universal, or type. Ordered. */
const SIMPLE_SELECTOR = /\[[^\]]*\]|::?[A-Za-z-]+(?:\([^()]*\))?|[.#][A-Za-z0-9_-]+|\*|[A-Za-z][A-Za-z0-9_-]*/g;

/** Split a declaration value on TOP-LEVEL whitespace, so `var(--a, 1px)` stays whole. */
function splitValueTokens(value) {
  const out = [];
  let depth = 0, cur = "";
  for (const ch of String(value)) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (depth === 0 && /\s/.test(ch)) { if (cur) out.push(cur); cur = ""; } else cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}

/** A width that computes to zero. `thin|medium|thick`, `var()` and `calc()` are NOT. */
function widthIsZero(w) {
  const v = String(w).trim().toLowerCase();
  if (!v || /^(thin|medium|thick)$/.test(v)) return false;
  const n = Number.parseFloat(v);
  return Number.isFinite(n) && n === 0 && !/[a-z]*\(/.test(v);
}

/** Does this {width, style} edge paint anything? */
function edgePaints(edge) {
  return !UNPAINTABLE_STYLES.has(String(edge.style).trim().toLowerCase()) && !widthIsZero(edge.width);
}

/** The initial box: every border side and the outline at `medium none`. */
function initialBoxState() {
  const st = { outline: { width: "medium", style: "none" } };
  for (const side of SIDES) st[side] = { width: "medium", style: "none" };
  return st;
}

/**
 * Apply one declaration block to a box state. A SHORTHAND resets its longhands
 * to their initial values — that is precisely why `border: 0` (width 0, style
 * `none`) and `border: none` (style `none`, width `medium`) both kill the edge
 * while `border-width: 0` leaves the style alone, and it is the mechanism the
 * mutation proof exercises.
 */
function applyBoxDecls(state, decls) {
  const shorthand = (value) => {
    let width = "medium", style = "none";
    for (const t of splitValueTokens(value)) {
      const lt = t.toLowerCase();
      if (BORDER_STYLE_KEYWORDS.has(lt)) style = lt;
      else if (/^(thin|medium|thick)$/.test(lt) || /^[-+]?[\d.]+[a-z%]*$/.test(lt)) width = lt;
    }
    return { width, style };
  };
  const spread = (value) => {
    const v = splitValueTokens(value);
    if (!v.length) return null;
    const [a, b = a, c = a, d = b] = v;
    return { top: a, right: b, bottom: c, left: d };
  };
  for (const [rawProp, rawValue] of Object.entries(decls)) {
    const prop = rawProp.toLowerCase();
    const value = String(rawValue).replace(/\s*!important\s*$/i, "").trim();
    if (prop === "border") {
      const sh = shorthand(value);
      for (const side of SIDES) state[side] = { ...sh };
    } else if (prop === "border-width" || prop === "border-style") {
      const key = prop.slice(7);
      const m = spread(value);
      if (m) for (const side of SIDES) state[side][key] = key === "style" ? m[side].toLowerCase() : m[side];
    } else if (prop === "outline") {
      state.outline = { ...shorthand(value) };
    } else if (prop === "outline-width") {
      state.outline.width = value;
    } else if (prop === "outline-style") {
      state.outline.style = value.toLowerCase();
    } else if (SIDES.includes(prop.slice(7))) {
      state[prop.slice(7)] = { ...shorthand(value) };
    } else {
      const m = prop.match(/^border-(top|right|bottom|left)-(width|style)$/);
      if (m) state[m[1]][m[2]] = m[2] === "style" ? value.toLowerCase() : value;
    }
  }
}

/** The compound steps of a complex selector, combinators dropped. */
function selectorSteps(sel) {
  return String(sel).replace(/\s*[>+~]\s*/g, " ").trim().split(/\s+/).filter(Boolean);
}
/** Is every simple selector of compound `a` also in compound `b`? */
function stepGeneralises(a, b) {
  const bt = new Set(String(b).match(SIMPLE_SELECTOR) || []);
  const at = String(a).match(SIMPLE_SELECTOR) || [];
  return at.length > 0 && at.every((t) => bt.has(t));
}
/** CSS specificity as one comparable number (ids, then class/attr/pseudo, then type). */
function specificityOf(sel) {
  let a = 0, b = 0, c = 0;
  for (const t of String(sel).match(SIMPLE_SELECTOR) || []) {
    if (t.startsWith("#")) a++;
    else if (t.startsWith("::")) c++;
    else if (t.startsWith(".") || t.startsWith("[") || t.startsWith(":")) b++;
    else if (t !== "*") c++;
  }
  return a * 10000 + b * 100 + c;
}
/**
 * How a rule part relates to a focus subject: "always" (it applies to every
 * element the subject matches), "context" (it applies to SOME of them, behind
 * extra ancestors) or null (it cannot reach the subject element at all).
 */
function ruleReach(rulePart, subject) {
  const r = selectorSteps(rulePart), sub = selectorSteps(subject);
  if (!r.length || !sub.length) return null;
  if (!stepGeneralises(r[r.length - 1], sub[sub.length - 1])) return null;
  let i = 0;
  for (const step of r.slice(0, -1)) {
    while (i < sub.length - 1 && !stepGeneralises(step, sub[i])) i++;
    if (i >= sub.length - 1) return "context";
    i++;
  }
  return "always";
}

/** Every rule in every owned source, in source order, parsed once. */
let _cascadeRules = null;
function allCascadeRules() {
  if (_cascadeRules) return _cascadeRules;
  _cascadeRules = [];
  let order = 0;
  for (const src of focusRuleSources()) {
    for (const m of src.text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const lead = m[1].length - m[1].trimStart().length;
      _cascadeRules.push({
        selector: m[1].trim(),
        decls: declsOf(m[2]),
        file: src.file,
        line: src.lineBase + lineOf(src.text, m.index + lead),
        order: order++,
      });
    }
  }
  return _cascadeRules;
}

/** Does this block touch the border/outline box at all? */
function declaresBox(decls) {
  return Object.keys(decls).some((p) => /^(border|outline)(-|$)/.test(p) && !/-color$|-radius$|-image|-offset$|-collapse$|-spacing$/.test(p));
}

/** Is this declaration value's colour opaque in every theme state? */
function opaqueValue(value) {
  const atom = value && colorAtomOf(value);
  if (!atom) return false;
  const a = minAlphaAcrossThemes(atom);
  return a !== null && a >= 1;
}

/**
 * Does this resolved box plus merged focus declarations leave the subject an
 * indicator that can actually be SEEN? Three ways to pass, and each needs BOTH
 * halves — a colour that paints on an edge that exists:
 *   (a) all four border sides paint and an opaque border colour is set,
 *   (b) the outline paints and an opaque outline colour is set,
 *   (c) the band itself (outermost box-shadow layer) is already opaque.
 * Three painting sides is not a perimeter, which is why (a) is `every`.
 */
function indicatorSurvives(state, merged) {
  if (SIDES.every((side) => edgePaints(state[side])) && (opaqueValue(merged["border-color"]) || opaqueValue(merged["border"]))) return true;
  if (edgePaints(state.outline) && (opaqueValue(merged["outline-color"]) || opaqueValue(merged["outline"]))) return true;
  const { band } = bandOf(merged);
  if (band) {
    const a = minAlphaAcrossThemes(band);
    if (a !== null && a >= 1) return true;
  }
  return false;
}

/** Are `steps` a subsequence of `within`, matching each step by generalisation? */
function stepsImplied(steps, within) {
  let i = 0;
  for (const step of steps) {
    while (i < within.length && !stepGeneralises(step, within[i])) i++;
    if (i >= within.length) return false;
    i++;
  }
  return true;
}

/** Every focus rule PART that reaches a subject, with its reach and prefix. */
function focusPartsFor(subject) {
  const out = [];
  for (const rule of allCascadeRules()) {
    if (!/:focus\b|:focus-visible\b/.test(rule.selector)) continue;
    for (const rawPart of rule.selector.split(",")) {
      const part = rawPart.replace(/::?focus(-visible|-within)?\b/g, "").replace(/\s+/g, " ").trim();
      if (!part) continue;
      const reach = ruleReach(part, subject);
      if (!reach) continue;
      out.push({ ...rule, part, reach, prefix: selectorSteps(part).slice(0, -1), spec: specificityOf(rawPart) });
      break;
    }
  }
  return out;
}

/**
 * The context, if any, in which this focus rule's OPAQUE-COLOUR escape has
 * nothing to paint on. Walks the subject's contexts (see the ESCAPE MUST BE
 * ABLE TO PAINT ruling): the unconditional cascade alone, then that cascade
 * plus each conditional box-declaring rule in turn. Every focus rule that also
 * reaches the subject IN THAT CONTEXT is applied on top — a context-specific
 * focus override is the honest fix for this defect and must not be re-reported
 * as the defect. Returns null when every context keeps an indicator.
 */
function escapePaintFailure(focusRule) {
  for (const subject of focusSubjectsOf(focusRule.selector)) {
    const focusParts = focusPartsFor(subject);
    const uncond = [], cond = [];
    for (const rule of allCascadeRules()) {
      if (!declaresBox(rule.decls)) continue;
      if (/:focus\b|:focus-visible\b/.test(rule.selector)) continue;
      for (const rawPart of rule.selector.split(",")) {
        const part = rawPart.trim();
        const reach = ruleReach(part, subject);
        if (!reach) continue;
        (reach === "always" ? uncond : cond).push({ ...rule, part, spec: specificityOf(part) });
        break;
      }
    }
    const byCascade = (x, y) => x.spec - y.spec || x.order - y.order;
    for (const extra of [null, ...cond]) {
      const contextSteps = extra ? selectorSteps(extra.part).slice(0, -1) : [];
      const state = initialBoxState();
      for (const r of [...uncond, ...(extra ? [extra] : [])].sort(byCascade)) applyBoxDecls(state, r.decls);
      const inContext = focusParts
        .filter((f) => f.reach === "always" || stepsImplied(f.prefix, contextSteps))
        .sort(byCascade);
      const merged = {};
      for (const f of inContext) {
        applyBoxDecls(state, f.decls);
        Object.assign(merged, f.decls);
      }
      if (indicatorSurvives(state, merged)) continue;
      const edges = SIDES.filter((side) => !edgePaints(state[side]))
        .map((side) => `${side} ${state[side].width}/${state[side].style}`);
      return {
        subject,
        edges: edges.length ? edges : [`outline ${state.outline.width}/${state.outline.style}`],
        killer: extra || [...uncond].sort(byCascade).pop() || null,
      };
    }
  }
  return null;
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

    // The escape: an opaque border/outline colour IS the indicator — but ONLY if
    // that edge can actually PAINT. A colour on a zero-width or `style: none`
    // edge paints nothing; see the ESCAPE MUST BE ABLE TO PAINT ruling above.
    const escapeProp = ["border-color", "outline-color", "border"].find((p) => opaqueValue(decls[p]));
    if (escapeProp) {
      const fail = escapePaintFailure(m);
      if (!fail) continue;
      errs.push(
        `E12 ${m.file}:${m.line}  focus rule ${JSON.stringify(selector.replace(/\s+/g, " "))} paints its band ` +
          `from ${band} (${bandProp}) at alpha ${alpha} and takes the OPAQUE-BORDER escape via ` +
          `${escapeProp}: ${decls[escapeProp]} — but that edge CANNOT PAINT for ${JSON.stringify(fail.subject)}. ` +
          `Resolving border/outline width and style across every rule that reaches the subject (cascade order, ` +
          `focus rules last) leaves ${fail.edges.join(", ")} (width/style)` +
          (fail.killer
            ? `, set by \`${fail.killer.part}\` at ${fail.killer.file}:${fail.killer.line}` +
              ` — and no focus rule applying in that context restores one`
            : ` — nothing gives the subject a border or outline at all`) +
          `. A COLOUR on a zero-width or style:none edge paints NOTHING, so the rule's only real indicator there ` +
          `is the translucent band, which can never reach the 3:1 SC 1.4.11 floor over an opaque backdrop. ` +
          `Give the subject a border that paints on all four sides in that context, or paint the indicator with ` +
          `an inset \`outline\` (the .inst-sites-card .site-row shape — no layout cost, all four sides)`,
      );
      continue;
    }

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
//
// EVERYTHING BELOW IS THE GATE BODY, and it runs only from runGate(). Exported
// so a test can drive it deliberately; called at the bottom only when IS_CLI.
//
// THE BODY IS LEFT AT ITS ORIGINAL INDENTATION ON PURPOSE. Re-indenting ~545
// lines would bury the one structural change in a wall of whitespace AND would
// risk altering the gate's own output: the diagnostics below are multi-line
// template literals, whose interior newline-plus-whitespace is DATA. The
// indentation is cosmetic; the strings are the contract.
export function runGate() {

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

// E13 — the deploy STATE GRAMMAR is one vocabulary, total, painted, and the
// retired second family has not come back. Derived from DEPLOY_STATUSES (the
// Ecto @statuses enum) and from app.js's DEPLOY_STATUS_META, never from the E3
// allowlist's prose. `css` is comment-stripped, so a selector that survives
// only inside a comment does NOT count — which is what lets the retired
// family's tombstone comment in app.css name `.dep-queued` without reviving it.
// statusMetaPill()'s own body — the ONE sanctioned home of a `status-pill` class
// literal in app.js. Brace-matched from the declaration rather than line-sliced,
// so the arm that reads it cannot be fooled by the function growing or moving.
// Returns null when the declaration is absent, which arm (f) treats as a FAILURE
// and not as "nothing to check".
function statusMetaPillBody(src) {
  if (src == null) return null;
  const at = src.indexOf("function statusMetaPill(");
  if (at < 0) return null;
  const open = src.indexOf("{", at);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const ch = src[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  return null;
}

{
  const meta = deployStatusMetaTable(jsRaw);

  // (a) VACUOUS-GREEN GUARD. Every other arm reads this table; a table this
  //     reader cannot find would make all four of them silently pass.
  if (meta === null) {
    errors.push(
      "E13 app.js  DEPLOY_STATUS_META could not be located or parsed — every other " +
        "arm of E13 reads it, so a rename or a rewrite must come with an update to " +
        "deployStatusMetaTable() here, never a silently skipped check.",
    );
  } else {
    const roles = new Set(STATUS_PILL_ROLES);

    // (b) TOTALITY. A status the table does not cover falls to `neutral` with no
    //     variant at runtime — which is the `queued` look, the impersonation that
    //     shipped twice under the old family.
    for (const st of DEPLOY_STATUSES) {
      if (meta.has(st)) continue;
      errors.push(
        `E13 app.js  deployment status "${st}" has no DEPLOY_STATUS_META entry — ` +
          `statusMeta() falls it through to the neutral role with no variant, which ` +
          `is the QUEUED look, so a ${st} deploy would impersonate one still waiting ` +
          `its turn. Add the entry beside the others.`,
      );
    }

    for (const [st, m] of meta) {
      // (d) CLOSED ROLE SET.
      if (m.role === null) {
        errors.push(
          `E13 app.js  DEPLOY_STATUS_META["${st}"] declares no role — the emitter ` +
            `would compose \`status-pill status-pill--\` with nothing after it.`,
        );
      } else if (!roles.has(m.role)) {
        errors.push(
          `E13 app.js  DEPLOY_STATUS_META["${st}"] names role "${m.role}", which is ` +
            `not one of the closed five (${STATUS_PILL_ROLES.join(" | ")}) — a sixth ` +
            `hue invented at a call site instead of declared in the family is how two ` +
            `pill families happened the first time. Use a declared role, or widen ` +
            `STATUS_PILL_ROLES here in the same commit as its .status-pill-- rule.`,
        );
      }
      // (c) PAINTED. Role and variant both have to exist in app.css.
      for (const [kind, name] of [["role", m.role], ["variant", m.variant]]) {
        if (!name) continue;
        if (cssClasses.has(`status-pill--${name}`)) continue;
        errors.push(
          `E13 app.css  DEPLOY_STATUS_META["${st}"] names ${kind} "${name}" but there ` +
            `is no .status-pill--${name} rule — the class rides into the DOM and ` +
            `paints as the bare base pill. Add the rule beside the other ` +
            `.status-pill--* rules in the STATUS PILL section.`,
        );
      }
    }
  }

  // (e) THE RETIRED FAMILY HAS NOT COME BACK. This is the arm that reds if the
  //     decision-24 sweep is reverted or re-forked: the defect is not any one
  //     missing rule, it is a SECOND vocabulary for the same idea existing at
  //     all — which is what made the two earlier impersonations invisible.
  const revived = [...cssClasses].filter(
    (c) => c === "dep-pill" || DEPLOY_STATUSES.some((st) => c === `dep-${st}`),
  ).sort();
  if (revived.length) {
    errors.push(
      `E13 app.css  the RETIRED .dep-* pill family is back: ${revived
        .map((c) => "." + c)
        .join(", ")}. Deploy status chips are .status-pill + a DEPLOY_STATUS_META ` +
        `role since decision 24; a second family painting the same idea is the ` +
        `regression this arm exists to catch, not a styling choice.`,
    );
  }
  // app.js is scanned for the class inside a QUOTED string only, so the
  // tombstone comments that explain the retirement (and name the dead classes)
  // are not themselves a revival; styleguide.html is scanned for the attribute.
  for (const [file, re, src] of [
    ["app.js", /["'][^"'\n]*\bdep-pill\b/, jsRaw],
    ["styleguide.html", /class="[^"\n]*\bdep-pill\b/, styleguideRaw],
  ]) {
    if (src == null || !re.test(src)) continue;
    errors.push(
      `E13 ${file}  emits a \`dep-pill\` class literal — the family is retired. ` +
        `Render the chip through deployStatusPill()/statusMetaPill() so there stays ` +
        `exactly one state grammar.`,
    );
  }

  // (f) ONE EMITTER, STATED AS A RULE AND NOT AS A LIST. Arm (e) retired the
  //     SECOND family; this arm is what keeps the surviving one from re-forking
  //     inside itself. The decision-24 prose claimed "there are no hand-written
  //     pill class attributes left" while seven call sites still opened their own
  //     `<span class="status-pill status-pill--…">` — the assertion was the false
  //     part, and nothing measured it. The check is a PREDICATE, never an
  //     enumeration of the sites that happened to exist on the day: EVERY
  //     `class="status-pill…` literal in app.js must sit inside statusMetaPill's
  //     own body. A new hand-built chip anywhere else reds here on its first
  //     commit, with no skip list to go stale.
  {
    const body = statusMetaPillBody(jsRaw);
    if (body === null) {
      errors.push(
        "E13 app.js  statusMetaPill() could not be located — this arm reads its body " +
          "to decide which pill literals are the sanctioned ones, so a rename must " +
          "come with an update to statusMetaPillBody() here, never a skipped check.",
      );
    } else {
      const LIT = /class="status-pill/g;
      const inside = (body.match(LIT) || []).length;
      const total = (jsRaw.match(LIT) || []).length;
      const outside = total - inside;
      if (inside === 0) {
        errors.push(
          "E13 app.js  statusMetaPill()'s body emits no `class=\"status-pill` literal " +
            "at all — the emitter this arm measures against no longer emits the family, " +
            "so every count below would be vacuous.",
        );
      } else if (outside > 0) {
        errors.push(
          `E13 app.js  ${outside} \`class="status-pill…\` literal(s) are emitted OUTSIDE ` +
            `statusMetaPill() — a hand-built status chip is a second grammar for the ` +
            `same idea, which is exactly what decision 24 absorbed. Render it through ` +
            `statusMetaPill(meta, extraClass, attrs) (or statusPill / deployStatusPill, ` +
            `which delegate to it); \`extraClass\` carries an extra class and \`attrs\` a ` +
            `pre-escaped title / data-* attribute string, so no call site needs its own ` +
            `span.`,
        );
      }
    }

    // cch-r21l — THE SAME PREDICATE, WIDENED TO THE SECOND ABSORBED FAMILY.
    // Arm (f) above measures the SURVIVING family's literals; `.inst-life-pill`
    // was a THIRD grammar for a state the ladder already paints (the fleet row
    // renders the same lifecycle state through statusMetaPill), so absorbing it
    // without a checked predicate would just re-run the decision-24 mistake —
    // the sentence "there is one state grammar" with nothing measuring it.
    //
    // TWO WAYS IT CAN COME BACK, both refused BY NAME:
    //   · a class LITERAL in app.js (the hand-built span in the pure render), or
    //   · a RULE in app.css (comment-stripped, so the tombstone that names the
    //     dead classes is not itself a revival).
    // The third way — the imperative `className = "inst-life-pill " + …` repaint
    // in the decommission handler — is caught by the literal scan too, because
    // the class name is spelled in a quoted string either way. That site is
    // exactly the one no class-attribute scan could ever see, which is why the
    // regex below is keyed on the NAME and not on the attribute.
    const ABSORBED = ["inst-life-pill", "inst-life-dot", "inst-life-label"];
    const revivedCss = ABSORBED.filter((c) => cssClasses.has(c)).sort();
    if (revivedCss.length) {
      errors.push(
        `E13 app.css  the RETIRED .inst-life-pill chip family is back: ${revivedCss
          .map((c) => "." + c)
          .join(", ")}. The instance lifecycle chip is .status-pill + a ` +
          `LIFECYCLE_PILL_ROLE role since cch-r21l; a second family painting the ` +
          `same state is the regression this arm exists to catch, not a styling ` +
          `choice.`,
      );
    }
    for (const [file, src] of [["app.js", jsRaw], ["styleguide.html", styleguideRaw]]) {
      if (src == null) continue;
      const back = ABSORBED.filter((c) => new RegExp(`["'][^"'\n]*\\b${c}\\b`).test(src)).sort();
      if (!back.length) continue;
      errors.push(
        `E13 ${file}  emits a \`${back.join("\`, \`")}\` class literal — the ` +
          `.inst-life-pill chip family is retired. Render the chip through ` +
          `lifecycleStatePillHtml(state), which delegates to statusMetaPill, so ` +
          `there stays exactly one state grammar and exactly one author for it.`,
      );
    }
  }

  // (g) THE ABSORBED FAMILY'S ROLE TABLE IS TOTAL AND PAINTED. Same shape as
  //     arms (b)/(c)/(d) above, one surface over: LIFECYCLE_PILL_ROLE must cover
  //     every state LIFECYCLE_PILL_LABEL declares, name only closed roles, and
  //     every role/variant it names must have a .status-pill--* rule. A state
  //     with a label and no role falls through to a bare neutral chip — the
  //     impersonation shape that made `.dep-cancelled` read as `queued`.
  {
    const roleTable = roleTableOf(jsRaw, "LIFECYCLE_PILL_ROLE");
    const labelKeys = flatObjectKeys(jsRaw, "LIFECYCLE_PILL_LABEL");
    if (roleTable === null || labelKeys === null) {
      errors.push(
        "E13 app.js  LIFECYCLE_PILL_ROLE and/or LIFECYCLE_PILL_LABEL could not be " +
          "located or parsed — this arm reads both, so a rename or a rewrite must " +
          "come with an update to roleTableOf()/flatObjectKeys() here, never a " +
          "silently skipped check.",
      );
    } else {
      const roles = new Set(STATUS_PILL_ROLES);
      for (const st of [...labelKeys].sort()) {
        if (roleTable.has(st)) continue;
        errors.push(
          `E13 app.js  lifecycle state "${st}" has a LIFECYCLE_PILL_LABEL entry but ` +
            `no LIFECYCLE_PILL_ROLE entry — lifecycleStatePillHtml() falls it through ` +
            `to the neutral role with no variant, so a ${st} box would wear the same ` +
            `chip as one nobody has classified. Add the role beside the others.`,
        );
      }
      for (const [st, m] of roleTable) {
        if (!labelKeys.has(st)) {
          errors.push(
            `E13 app.js  LIFECYCLE_PILL_ROLE["${st}"] names a state LIFECYCLE_PILL_LABEL ` +
              `does not declare — the chip would render the literal word "Unknown" in a ` +
              `${m.role || "?"}-coloured pill. Give it a label or drop the role.`,
          );
          continue;
        }
        if (m.role === null || !roles.has(m.role)) {
          errors.push(
            `E13 app.js  LIFECYCLE_PILL_ROLE["${st}"] names role "${m.role}", which is ` +
              `not one of the closed five (${STATUS_PILL_ROLES.join(" | ")}).`,
          );
        }
        for (const [kind, name] of [["role", m.role], ["variant", m.variant]]) {
          if (!name) continue;
          if (kind === "role" && !roles.has(name)) continue;
          if (cssClasses.has(`status-pill--${name}`)) continue;
          errors.push(
            `E13 app.css  LIFECYCLE_PILL_ROLE["${st}"] names ${kind} "${name}" but there ` +
              `is no .status-pill--${name} rule — the class rides into the DOM and ` +
              `paints as the bare base pill.`,
          );
        }
      }
    }
  }
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

// E18 — every domain-checklist ROLE is painted. Same four failure shapes as E16:
// the deriver cannot read domainStageRows, it read it but could not follow an arm,
// the declared set drifted from the arms, or a role has no rule. Arm (d) pins the
// premise that makes the no-consent decision above reviewable rather than inherited.
{
  const derived = emittedDomainRungRoles(jsRaw);
  if (derived === null) {
    errors.push(
      "E18 app.js  domainStageRows() could not be located, brace-matched, or its `var role =` " +
        "initializer found — the dom-rung-- role set is DERIVED from that fold, so a rename or " +
        "a rewrite must come with an update here, never a silently skipped check.",
    );
  } else {
    // (a) DERIVER BLINDNESS, both halves of the fold. Every ternary arm and every
    //     later `role =` must be a string literal, or this reader returns a set
    //     narrower than the code's and (b) goes quietly vacuous.
    if (derived.arms !== derived.armLiterals) {
      errors.push(
        `E18 app.js  domainStageRows()'s role ternary has ${derived.arms} arm(s) but only ` +
          `${derived.armLiterals} yield a string literal — emittedDomainRungRoles reads literals ` +
          `ONLY, so the derived set would be short by ${derived.arms - derived.armLiterals}. Keep ` +
          `the arms literal, or teach the deriver the new form; do not let it report a set it cannot see.`,
      );
    }
    if (!derived.tail) {
      errors.push(
        "E18 app.js  domainStageRows()'s role ternary chain no longer ends in a literal default " +
          "(`: \"unknown\";`). That default is the arm that catches every status the server invents, " +
          "so a non-literal there is exactly the role most likely to reach the DOM unpainted.",
      );
    }
    if (derived.reassigns !== derived.reassignLiterals) {
      errors.push(
        `E18 app.js  domainStageRows() reassigns \`role\` ${derived.reassigns} time(s) but only ` +
          `${derived.reassignLiterals} to a string literal — the markNextStep promotion is how ` +
          `\`active\` enters the set at all, and a computed one is invisible to this reader.`,
      );
    }
    // (b) DRIFT, both directions: DOM_RUNG_ROLES and the fold must name one set.
    //     This is the arm that would have caught the ALLOW_PREFIXES comment, which
    //     was wrong in BOTH directions simultaneously (it omitted `unknown` and it
    //     listed `pending` as though painted).
    for (const r of derived.roles) {
      if (DOM_RUNG_ROLES.includes(r)) continue;
      errors.push(
        `E18 __css_check.mjs  domainStageRows() produces role "${r}", which is not in ` +
          `DOM_RUNG_ROLES — add it there, then paint .dom-rung--${r}. There is no consent to ` +
          `the base pill on this family.`,
      );
    }
    for (const r of DOM_RUNG_ROLES) {
      if (derived.roles.has(r)) continue;
      errors.push(
        `E18 __css_check.mjs  DOM_RUNG_ROLES names "${r}", which domainStageRows() no longer ` +
          `produces — a value space wider than reality is how the entry's old comment came to ` +
          `name five roles for a six-role fold. Remove it.`,
      );
    }
  }

  // (c) UNPAINTED: `cssClasses` is built from comment-stripped CSS, so a selector
  //     surviving only inside a comment does not count. This is the arm that reds
  //     on the filed defect: before this commit .dom-rung--pending had no rule.
  for (const r of DOM_RUNG_ROLES) {
    if (cssClasses.has(`dom-rung--${r}`)) continue;
    errors.push(
      `E18 app.css  domain role "${r}" has no .dom-rung--${r} rule — the ` +
        `dom-rung dom-rung-- head emits it, so the chip falls through to the BARE ` +
        `.dom-rung and paints whatever that happens to say. Add a rule beside the ` +
        `other .dom-rung--* rules, even when the base already looks right: an ` +
        `unwritten fall-through is not a treatment, it is a coincidence.`,
    );
  }

  // (d) PREMISE: (c)'s "even when the base already looks right" and the decision to
  //     ship no consent list both rest on the bare .dom-rung being a real authored
  //     rule that pending's own rule mirrors. If the base goes, the mirroring rule
  //     is stranded and the reasoning must be re-opened rather than left as prose.
  if (!cssClasses.has("dom-rung")) {
    errors.push(
      "E18 app.css  the base .dom-rung rule is gone, but .dom-rung--pending is authored as an " +
        "EXACT restatement of it (see its comment in app.css). Re-decide: either restore the " +
        "base, or give pending a treatment that stands on its own.",
    );
  }
}

// E19 — a waiver must absolve something. Every ALLOW_PREFIXES entry is a standing
// consent for a dynamic class head, and consent for a head nobody emits is consent
// absolving nothing: it can never red, so it is indistinguishable from an entry
// doing real work, and it silently pre-exempts the family the day that name comes
// back — the gate would then report green over a family it had never checked.
//
// THIS IS THE GENERAL FORM OF WHAT E15's CONSENT ARM DOES FOR ONE LIST. It found
// nothing new when it was written (the two dead entries it was built for —
// `rollup-card rollup-card--` and `bp-tl-step bp-tl-step--` — were removed in the
// same commit), and that is the intended steady state: this arm exists so the NEXT
// one is found by the gate instead of by a person reading the list.
//
// `allowlistedHits` is the walker's own record of entries it actually used, so this
// compares the list against the same evidence the E3 waiver is granted on — not
// against a second, differently-shaped grep that could disagree with it.
{
  const used = new Set(allowlistedHits.map((h) => h.head));
  for (const head of ALLOW_PREFIXES) {
    if (used.has(head)) continue;
    errors.push(
      `E19 __css_check.mjs  ALLOW_PREFIXES entry "${head}" waived nothing on this run — no ` +
        `dynamic class composition in app.js or index.html has that head. A waiver for an ` +
        `unemitted head can never fail, so it reads as live consent forever and pre-exempts ` +
        `the family if the name returns. Delete the entry; re-add it with the emission.`,
    );
  }
}

// E21 — THE GR57 FIXED-BLUE INVARIANT, held in BOTH directions.
//
// WHY THIS EXISTS. `--info` (= `--cc-blue`) is the console's deliberately
// accent-INDEPENDENT blue: GR57 rules that `.btn-link` colours itself
// `var(--primary)`, which IS the user-selectable accent (redefined in ten
// `[data-bp-theme]` blocks across five identities), so the design's fixed-blue
// links would render terracotta under ember and orchid under charple. GR57's
// words: "Ship a scoped variant, never repurpose `--primary`."
//
// That invariant has now been mis-read TWICE by a five-accent screenshot matrix
// as a bug — "a fixed blue that ignores the accent on 11 screens" — because a
// reviewer looking at pixels cannot see a ruling that lives in a charter. The
// charter itself records the first retraction (gr-p5r7-reshoot-verify: "its
// builder nearly reported a defect that GR57 documents as deliberate"). A
// written finding does not fire by itself; this arm is the finding made
// mechanical, so the THIRD reviewer meets a gate with the reason in it.
//
// THREE ARMS, and the first is a precondition because a guard that can go
// vacuous is not a guard:
//   (a) `--cc-blue` must be declared exactly twice — once in `:root`, once in
//       `[data-theme="dark"]`. Zero declarations means the token was renamed
//       and arms (b)/(c) would pass having measured nothing.
//   (b) NO CONSUMER RULE reads the ramp token. Consumers read the ROLE token
//       `--info`; the only permitted `var(--cc-blue)` references are the two
//       `--info:` alias declarations themselves. A ramp token with consumers is
//       a second front door: retune `--info` and those rules do not follow.
//       (gr-r21m-defect-jk found two — `.trial-chip`, `.billing-chip--trial`.)
//   (c) NO `[data-bp-theme]` BLOCK may declare `--info`, `--info-hsl` or
//       `--cc-blue`. This is the direction GR57 actually cares about, and it is
//       unguarded today: an identity block could quietly accent-ify the blue and
//       every fixed-blue link in the product would fan per theme with no test
//       anywhere noticing.
//
// MEASURED, so the next reader does not over-trust arm (c): its `--cc-blue`
// comparand is SUBSUMED by arm (a). Inserting `--cc-blue: #c46a2a` into the
// ember block reds as "found 3" from (a) — (a) counts declarations file-wide and
// runs first — so (c) never sees it. (c) was mutation-proven on the two
// comparands that ARE only its own: `--info:` and `--info-hsl:` in the ember
// block each red on the `html[data-bp-theme="ember"]` selector with (a) silent. `--cc-blue` is kept in (c)'s
// list anyway: it costs nothing and it survives the day (a) is re-pointed.
{
  const declRe = /--cc-blue\s*:/g;
  const declCount = (css.match(declRe) || []).length;
  if (declCount !== 2) {
    errors.push(
      `E21 app.css  expected exactly 2 \`--cc-blue:\` declarations (:root + [data-theme="dark"]) ` +
        `but found ${declCount}. The token was renamed, deleted or duplicated, so arms (b) and (c) ` +
        `below would pass having measured NOTHING. Re-point this arm at whatever replaced it, or ` +
        `delete E21 and say in the same commit that GR57's fixed blue is gone.`,
    );
  } else {
    // (b) every var(--cc-blue) must sit on a line whose own declaration is the
    //     `--info:` alias. Line-scoped, so a consumer rule can never hide behind
    //     an alias elsewhere in the file.
    for (const [i, line] of css.split("\n").entries()) {
      if (!/var\(--cc-blue\)/.test(line)) continue;
      if (/--info\s*:\s*var\(--cc-blue\)/.test(line)) continue;
      errors.push(
        `E21 app.css:${i + 1}  a rule reads the RAMP token \`var(--cc-blue)\` directly: ` +
          `${line.trim()}\n      Consumers read the ROLE token \`var(--info)\` — which is what this ` +
          `rule's own background/border tints already use. Reaching past the role is a second front ` +
          `door: retune --info for contrast and this rule silently does not follow.`,
      );
    }
    // (c) GR57's own invariant: the identity blocks must not touch the blue.
    const themeBlockRe = /(html)?\s*\[data-bp-theme=[^\]]*\][^{]*\{([^}]*)\}/g;
    let m, themeBlocks = 0;
    while ((m = themeBlockRe.exec(css)) !== null) {
      themeBlocks += 1;
      const body = m[2];
      for (const tok of ["--cc-blue", "--info-hsl", "--info"]) {
        const re = new RegExp("(^|[^-\\w])" + tok + "\\s*:");
        if (!re.test(body)) continue;
        errors.push(
          `E21 app.css:${lineOf(css, m.index)}  the identity block \`${m[0].slice(0, m[0].indexOf("{")).trim()}\` ` +
            `declares \`${tok}\`. GR57 makes --info/--cc-blue the ACCENT-INDEPENDENT blue precisely ` +
            `because it is declared only in :root and [data-theme="dark"]: the design's fixed-blue links ` +
            `("Change password", "Copy", "Show all N") must read the same under all five identities. ` +
            `An override here fans every one of them per accent with nothing else in the tree noticing. ` +
            `If the fixed blue is being retired, retire GR57 and this arm in the same commit.`,
        );
        break;
      }
    }
    if (themeBlocks < 10) {
      errors.push(
        `E21 app.css  arm (c) found only ${themeBlocks} [data-bp-theme] block(s); the five identities ` +
          `declare ten (light + dark each). A short scan means the block regex stopped matching, so ` +
          `"no identity overrides the blue" would be a statement about blocks this run never read.`,
      );
    }
  }
}

// E20 — a HOOK waiver must absolve something, same rule as E19 one list over.
//
// WHY THIS EXISTS. This file runs four suppression lists, and until this arm
// landed only three could notice an entry going dead: ALLOW_PREFIXES has E19
// (hard), KNOWN_GAPS computes `staleGaps`, ALLOW_RAW_COLORS computes
// `staleRawAllows`. ALLOW_HOOK_CLASSES had neither — its only uses were the
// membership test in the E2 loop and the `allow` print of the hits that DID
// fire. MEASURED before the fix: inserting a fictional entry into the array
// left the run at exit 0, the summary unchanged, and produced ZERO output
// naming it. A class deleted from the console therefore left a standing consent
// nobody was told about, and the next reader learned a class exists that does
// not.
//
// HARD ERROR, NOT A `stale` LINE — the asymmetry between the four lists is a
// DECISION, stated here so the next reader does not have to infer it:
//   · KNOWN_GAPS and ALLOW_RAW_COLORS report-only because each DEMOTES a real,
//     already-true violation that another slice owns. Their stale line asks a
//     third party to prune; making that fatal would red this gate on someone
//     else's cleanup, which is precisely backwards.
//   · ALLOW_PREFIXES (E19) and ALLOW_HOOK_CLASSES are consent granted BY this
//     gate's own owners over this gate's own files. Nothing outside the console
//     can make one of these entries go stale, so the person who breaks it is
//     the person who can fix it in the same commit. Hard.
//   · And the failure mode is the worse one: an unfired hook entry silently
//     PRE-EXEMPTS the class the day the name comes back, at which point E2
//     reports green over a class it never checked.
//
// Judged against `hookHits` — the E2 loop's own record of the entries it really
// used — so the arm and the waiver are decided on the same evidence, never on a
// second, differently-shaped grep that could disagree with it.
function hookAllowlistErrors(allowlist, hookHits, emittedCount) {
  const errs = [];
  // (a) PRECONDITION — the arm must HAVE a subject. Both of these would make
  //     the (b) loop pass by measuring nothing, which is the exact disease the
  //     arm was written to cure; a guard that can go vacuous is not a guard.
  if (!emittedCount) {
    errs.push(
      "E20 __css_check.mjs  the class census produced ZERO emitted classes, so `hookHits` is " +
        "empty for a reason that has nothing to do with the allowlist. Every ALLOW_HOOK_CLASSES " +
        "entry would read as stale and the E2 loop reported on nothing at all — fix the walker " +
        "or the scan root; do not read this run's class verdicts as a result.",
    );
  }
  if (!allowlist.length) {
    errs.push(
      "E20 __css_check.mjs  ALLOW_HOOK_CLASSES is EMPTY, so this decay arm has nothing to " +
        "check and would pass forever without measuring anything (KNOWN_GAPS' stale arm sits " +
        "in exactly that state today). If the console genuinely has no ruleless hook classes " +
        "left, delete this arm and its call in the same commit and say so — an emptied list " +
        "under a live arm is an arm that cannot lose.",
    );
  }
  if (errs.length) return errs;
  // (b) STALENESS — one line per entry that waived nothing on this run.
  const used = new Set(hookHits.map((h) => h.cls));
  for (const cls of allowlist) {
    if (used.has(cls)) continue;
    errs.push(
      `E20 __css_check.mjs  ALLOW_HOOK_CLASSES entry "${cls}" waived nothing on this run — ` +
        `nothing under the scan root emits it as a class, so this consent can never fail and ` +
        `is indistinguishable from an entry doing real work. It also PRE-EXEMPTS the class the ` +
        `day the name returns, at which point E2 reports green over a class it never checked. ` +
        `Delete the entry; re-add it with the emission. (An id selector is not a class: check ` +
        `whether the reason on the entry says \`.${cls}\` while the code says \`#${cls}\`.)`,
    );
  }
  return errs;
}

for (const e of hookAllowlistErrors(ALLOW_HOOK_CLASSES, hookHits, emitted.length)) errors.push(e);

// E20's OWN CONTROLS, run inside the measurement rather than in a test that
// could stop being run. The shipped call above can only ever print a clean
// nothing; these three say whether that nothing was MEASURED. Each drives the
// same function the gate uses, on this run's real `hookHits`.
{
  const probe = "zz-css-check-control-class-that-is-never-emitted";
  const ctlStale = hookAllowlistErrors([probe], hookHits, emitted.length);
  if (!(ctlStale.length === 1 && ctlStale[0].includes(probe))) {
    errors.push(
      `E20 __css_check.mjs  the ALLOW_HOOK_CLASSES decay arm FAILED ITS OWN CONTROL: a ` +
        `fabricated entry "${probe}", which nothing emits, produced ${ctlStale.length} error(s) ` +
        `instead of exactly one naming it. The clean ALLOW_HOOK_CLASSES verdict this run printed ` +
        `is therefore not evidence of anything.`,
    );
  }
  if (!hookAllowlistErrors([], hookHits, emitted.length).length) {
    errors.push(
      "E20 __css_check.mjs  the ALLOW_HOOK_CLASSES decay arm FAILED ITS OWN CONTROL: an EMPTY " +
        "allowlist was accepted silently, so emptying the array would retire the arm without " +
        "anyone deciding to.",
    );
  }
  if (!hookAllowlistErrors([probe], [], 0).length) {
    errors.push(
      "E20 __css_check.mjs  the ALLOW_HOOK_CLASSES decay arm FAILED ITS OWN CONTROL: a census " +
        "that emitted ZERO classes was accepted silently, so a walker that stopped finding its " +
        "subject would read as a clean allowlist.",
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

// E14 — wrap-recipe declaration parity (charter D220): the hand-built copies
// share a byte-identical five-declaration core wearing different jackets, and
// nothing asserted that the core still agrees. The copy inventory is printed
// below so the count is the SCAN's claim, never a comment's — which is why
// this sentence no longer states a number: it said "three" through two
// additions (W20-S6's `.attention-row`, cch-w24-s2's `.detail-title-row`) and
// was wrong for both. This gate body scans app.css ALONE (`cssRaw`); the
// fixtures reach E14 only through the targeted `--wrap-parity-check <file>`
// sub-mode.
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
  // NOT process.exit(1) — THE FIFTH INSTANCE of the sub-mode defect documented
  // beside the emitSync helper above, found by this row's own stability arm.
  // This body prints ~9.5KB, well past the 8192-byte pipe buffer, and the
  // mirror harness in __app.test.mjs reads it through a spawnSync. On the GREEN
  // path the gate simply falls off the end, so Node drains stdout before the
  // process dies and nothing is ever lost — which is why the clean leg has
  // never flaked. On THIS path the old `process.exit(1)` tore the process down
  // with bytes still queued, and the mutation leg went red 1 run in 22 with a
  // truncated capture.
  //
  // `process.exitCode` states the SAME verdict without the teardown: the
  // statement below is the last in runGate, `if (IS_CLI) runGate()` is the last
  // statement in the file, and the gate holds no timers or open handles, so
  // returning here ends the program with nothing left to run. Node then exits
  // on its own — flushing stdout and stderr first — and reports 1. Exit code
  // identical, output no longer a race.
  process.exitCode = 1;
  return;
}

} // end runGate

if (IS_CLI) runGate();
