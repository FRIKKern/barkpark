# CCH wave 26 — instrument-class census BY ROW BODIES (2026-08-02, origin/main cfc2f2b77)

RE-DERIVATION RECIPE (four commands, all checkout-independent except the last):

    # 1. the predicate's OWN roster (published children only — this is the clause-(a) denominator)
    curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' --data-urlencode 'limit=500' \
      -H "Authorization: Bearer $BP_TOKEN"
    # 2. the successor roster (forwarded set)
    #    same call with filter[parent_id]=cch-instruments-epic
    # 3. bodies: bp task get <doc_id> -o json  -> .doc.content.{description,files,surface,acceptance_criteria}
    # 4. the two frozen inputs the arithmetic needs:
    git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | sed -n '210p;220,227p;794,799p'

COUNTING RULE (stated, so the number is defensible):
  * DENOMINATOR = seal-predicate residue = live(open|in_progress) + considering, over the
    PUBLISHED roster. Measured: 332 published children, 114 live, 1 considering => residue 115.
    `bp task get` says 334/115/1 — the 2-row delta is exactly two `drafts.*` twins, which the
    production query never returns (D105: a draft twin is a duplicate, never a row).
  * ORPHANS = residue - 3 PERMANENT_HUMAN_GATES - forwarded. Successor roster n=107,
    INTERSECTION with the epic roster = 0 (D249's structural constant). => ORPHANS = 112.
  * CLASS is read off the row BODY (description + files + surface), never the title.
    Law 0's five instrument bodies verbatim: gate | generator | harness | required-checks |
    ledger-hygiene. CONSOLE = the divergence is visible on a console surface a person can reach.
    NEITHER = api/**, ops/infra, bp CLI — Law 0 names no destination for these.
  * Every contested call is marked (*) with the reason. 8 rows carry NO acceptance_criteria key
    at all; they are counted normally (they are published, live and orphaned) — the note is that
    they can never be STAMPED, only cancelled, re-parented or override-closed.

RESIDUE PARTITION (115): INSTRUMENT 66 | CONSOLE 35 | NEITHER 14
ORPHAN PARTITION (112): INSTRUMENT 65 | CONSOLE 35 | NEITHER 12
  vs charter D249's orphan partition (90): 44 instrument / 35 console / 11 neither.
  CONSOLE is UNCHANGED at 35. The entire +22 growth is instrument-class (+21) plus one NEITHER.

## GATE (11)
- `cch-bl-css-check-gate-body-not-importable` — gate body runs at module evaluation
- `cch-w13-rv-gate-must-run-css-check` — per-slice gate composition policy
- `cch-w16-s7-citation-anchors-e11-widening` — E11 citation-anchor gate widening
- `cch-w17-bl-css-slice-gate-must-include-leg-a` — slice-gate composition policy
- `cch-w17-bl-e11-scan-set-app-css-and-shoot-sh` — E11 scan-set blindness
- `cch-w19-bl-baseline-one-integer-assertion` — cssom baseline parse can pass silently
- `cch-w19-bl-css-check-has-no-main-guard` — gate body not importable
- `cch-w19-bl-e14-shorthand-blind` — E14 shorthand blindness
- `cch-w24-bl-detail-title-row-not-a-required-wrap-host` — WRAP_REQUIRED_HOSTS membership
- `gr-backlog-css-check-missing-classes` — __css_check gaps; files include the checker itself
- `task-4f363dc65ac43203` (*) — defect IS the absence of a guard on the scrub boundary; the boundary itself is person-facing

## GENERATOR (8)
- `cch-backlog-bpbase-envelope-incomplete` — scenarios.mjs bpBase envelope
- `cch-w15-bl-detail-url-fixture-never-overflows` — no fixture can make the host overflow
- `cch-w15-bl-plan-catalog-no-fixture-seam` (*) — no scenario can inject tiers; the literal lives in app.js
- `cch-w16-bl-no-preview-plus-production-console-fixture` — no fixture carries the divergent pair
- `cch-w18-bl-attention-fixture-string-not-production-dominant` — fixture string production never produces
- `cch-w23-bl-cruel-identity-own-scenario` — scenario key for the cruel identity
- `cch-w23-bl-real-hetzner-remediation-scenario` — real remediation has no scenario to live in
- `cch-w23-bl-site-domains-cruel-family` (*) — a cruel FAMILY for the corpus; its bite lands on console geometry

## HARNESS (34)
- `cch-bl-w15-fleet-leg-scenario-axis-of-two` — overflow-guard leg scenario axis
- `cch-w15-bl-cuestuck-asks-horizontal-of-a-vertical-cue` — CUE_STUCK note asks the wrong question
- `cch-w15-bl-lega-cannot-refuse-removed-breakpoint` — breakpoint-sweep Leg A coverage refusal
- `cch-w15-bl-render-leg-node22-job` — CI job for the render leg
- `cch-w15-bl-target-reuse-ascending-order-pin` — CDP target reuse order pin
- `cch-w16-bl-legb-drives-one-of-three-heights` — declared height axis undriven
- `cch-w16-bl-tiers5-leg-runs-nowhere` — instrument no job invokes
- `cch-w17-bl-overflow-guard-honours-one-defect-flag` — guard silently drops the second --defect
- `cch-w18-bl-smoke-address-copy-assertion-matches-the-rail-row` — smoke assertion satisfied by the wrong node
- `cch-w19-bl-gr115-intermittent-ua-defaults` — intermittent guard finding; body says the parent_id patch was REJECTED and the lead should re-parent
- `cch-w19-bl-harness-width-prose-four-sites` — stale width prose in the harness/workflow
- `cch-w19-bl-topbar-620-vertical-cost-unasserted` (*) — the ASK is a committed assertion; the COST is person-facing vertical space
- `cch-w19-bl-w13-rail-pill-pooled-zero-check` — pooled zero-element protection
- `cch-w19-s1-guard-loses-in-ci` — guard mutation proof
- `cch-w21-bl-token-reveal-modal-oracle` — modal-oracle does not drive the state
- `cch-w22-bl-chip-guard-blind-below-721` — CHIP_WIDTHS starts at 721
- `cch-w22-s1-residue-modal-oracle-uninvoked` — oracle exit 2 read by nobody
- `cch-w22-s7-cruelty-ledger-effective-caps-and-classes` — cruelty-ledger instrument over every text host
- `cch-w23-bl-cruel-leg-blind-to-status-pill-detail` — leg never iterates the host
- `cch-w23-bl-site-meta-320-line-guard` — guard leg
- `cch-w23-bl-three-screens-zero-geometry-coverage` — three screens with zero geometry coverage
- `cch-w24-bl-console-harness-comment-lies-about-cell-flag` [NO acceptance_criteria] — comment in the gating job refuted by run
- `cch-w24-bl-guard-full-run-nav-flake` — full-run nav flake
- `cch-w24-bl-hash-only-nav-is-same-document` — same-document nav inherits the previous DOM
- `cch-w24-bl-nothing-pins-height-against-a-cruel-string` [NO acceptance_criteria] — no leg asserts HEIGHT
- `cch-w24-bl-phone-band-unreachable-by-the-width-sweep` [NO acceptance_criteria] — sweep's narrowest width is 619
- `cch-w24-bl-q3-fold-budget-is-a-shell-property-at-320` [NO acceptance_criteria] — budget unreachable by construction
- `cch-w24-followup-no-leg-drives-a-hash-nav` — no leg hash-navigates
- `cch-w25-bl-d298-footer-value-pair-unobservable` (*) — a probe re-measure; the shipped VALUE it questions is person-facing CSS
- `cch-w25-bl-new-theater-family-unswept` — /new is SCENARIO_RESIDUE; no sweep renders it
- `gr-backlog-qr-live-scan-proof` [PERMANENT HUMAN GATE] (*) — a proof obligation against real phones; arguably NEITHER (manual human test)
- `gr-bl-gr108-fix-overdetermined` (*) — guard cannot reproduce the defect its fix claims; also a CSS-fix question
- `task-696a2fcf95e9c4da` — permanent guard leg
- `task-d862cf7f8e1108c1` — overflow-guard never awaits fonts.ready

## REQCHECKS (4)
- `cch-bl-floor-blind-to-readme-and-uncalled` — required-checks floor script
- `cch-w11-bl-required-checks-live-suite-unrun-at-four` — required-checks.test.sh live half
- `cch-w11-residue-security-gate-registration-policy` — registration policy for a required context
- `cch-w11-s1-flip-behind-a-generator-that-cannot-lose` — required-checks.json flip + generator

## LEDGER (9)
- `cch-w12-bl-filing-law-parent-charter-half` — charter prose / filing law
- `cch-w12-bl-independent-review-owed-wave-12` — review-owed bookkeeping row
- `cch-w12-s5-successor-split-and-letterbox-fence` — seal-predicate + instruments charter
- `cch-w15-bl-publish-wall-rationale-length-opaque` (*) — bp publish-wall error message; ledger tooling not a console/gate
- `cch-w19-bl-stamp-merge-gated-flag-undocumented` (*) — bp capabilities manifest gap; ledger tooling, not console/gate
- `cch-w22-bl-attention-sibling-never-measured` — criteria closed unmet, named so the closes are readable
- `cch-w22-bl-url-remedy-candidates-never-priced` (*) — an unpaid criterion carried forward off a cascade close; its subject is a console remedy
- `cch-w24-bl-word-break-alias-has-no-ruling` [NO acceptance_criteria] (*) — a DOCTRINE gap over 16 app.css sites; no criteria at all
- `task-13f830a9c36314e0` — cssom-heads.baseline sidecar prose misattribution

## CONSOLE (35)
- `cch-bl-cloudflare-identity-echo-no-surface` — console does not say which account it points at
- `cch-bl-scroll-driven-cue-firefox-fallback` — the affordance is invisible to a Firefox person
- `cch-rtl-script-neutral-borrowing` (*) — implicit bidi rendering of an email a person reads
- `cch-w12-bl-redact-env-secrets-opt-in-on-3-of-24` (*) — provisioner scrub opt-in; SPA renders the unscrubbed string verbatim
- `cch-w13-bl-azure-subscription-display-name` — identity the console shows a person
- `cch-w13-rv-scrub-eats-bracketed-prose` — a person reads REDACTED where no secret was
- `cch-w13-s1-residue-planned-fill-and-ring` — rail paints determinacy it does not have
- `cch-w14-bl-billing-chip-truncated-above-768` — billing chip truncated at real widths
- `cch-w14-bl-site-open-phone-overflow` — page scrolls sideways on every iPhone
- `cch-w15-bl-real-nav-toggle-wave` — nav reach on short viewports
- `cch-w16-bl-instance-site-row-never-deployed-says-nothing` — the row tells a person nothing about state
- `cch-w19-bl-op-gate-dot-centring-at-320` — status dot beside line 2 of 3 a person sees
- `cch-w20-bl-attention-band-wrap-point-not-uniform` — wrap point decided by the reason string
- `cch-w20-bl-console-touch-target-comfort-44px` — touch comfort on phone
- `cch-w20-bl-console-type-floor-sub-12px` — 10px telemetry legend a person must read
- `cch-w20-bl-detail-url-text-ellipsised-on-phone` — the address loses its TLD
- `cch-w21-bl-cred-remediation-scrolls-above-the-viewport` — remediation first line above the viewport
- `cch-w21-bl-inst-head-fit-content-621-899` — instance head geometry
- `cch-w21-bl-status-pill-detail-fed-by-uncapped-error` — uncapped string into the pill a person reads (in-byte REFUTED by a surveyor)
- `cch-w22-bl-fleet-meta-inadmissible-spill` (*) — console geometry, but INADMISSIBLE today (only a system writer can fill it)
- `cch-w23-bl-cred-form-ids-have-two-hosts` — duplicate ids: the modal drives the page's fields
- `cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width` [NO acceptance_criteria] — a person sees ~15% of their own identity line
- `cch-w24-bl-word-break-alias-remaining-seven` (*) — seven app.css surfaces to triage; sibling of the doctrine row above
- `cch-w25-bl-cred-back-lands-on-a-picker-nobody-came-from` — the one control this epic made strictly worse
- `cch-w25-bl-detail-grid-instance-track-unmeasured` [NO acceptance_criteria] (*) — a bare 1fr track that may drag; 'no fixture can floor it' is the GENERATOR half
- `cch-w25-bl-flick-to-bottom-overshoots-retry` [NO acceptance_criteria] — the crudest gesture overshoots Retry by 564px
- `cch-w25-bl-site-name-drags-1885px-at-900-on-the-compact-builder` — WAVE-26 FLAGSHIP; person-facing geometry
- `cchi-w22-bl-shared-modal-card-min-content-floor` (*) — NAMED TEMPLATE: instruments-prefixed id, person-facing modal geometry body
- `gr-backlog-console-redaction-allowlist` (*) — Go-side redaction, but the divergence is secrets rendered verbatim in the console
- `gr-backlog-d24-statusmeta-sweep` — app.js/app.css pill grammar a person reads
- `gr-backlog-operator-digest-send` — a button a person cannot reach because no route exists
- `gr-backlog-operator-palette-entry` — Cmd+K palette cannot offer a nav destination
- `gr-backlog-tablet-width-audit` (*) — app.css layout defect; motivated by shoot.sh WIDTHS (harness flavour)
- `task-a5a9c63ee5b22fc3` — failed run still paints a weighted master bar
- `task-c04dde30f94b14c9` (*) — render-path audit of humanize/1; the ASK is an audit, the SUBJECT is what a person is told

## NEITHER (14)
- `cch-bl-lifecycle-token-reaper` — accounts.ex/worker reapers
- `cch-cloud-app-has-no-plug-errorhandler` (*) — api has no error handler; the SPA's api() helper degrades as a consequence
- `cch-cloud-static-gzip-html` (*) — Dockerfile gzip build; has a guard script half (gz-guard) -> arguably GATE
- `cch-email-format-missing-u-modifier` (*) — user.ex regex; consequence is a legible forged sentence a person reads
- `cch-hg-compose-network-recreation` [PERMANENT HUMAN GATE] — HUMAN GATE, docker network recreate
- `cch-w12-bl-events-422-overstamps-session` (*) — api over-stamp; a merged TEST pins it (harness half)
- `cch-w12-bl-session-touch-has-no-rescue` — accounts.ex missing rescue -> 500
- `cch-w23-bl-pat-deploy-grant-survives-demotion` — authz: PAT keeps an ability after demotion
- `cloud-console-operator-audit-log` (*) — backend audit sink for 3 admin routes; no console surface named; CONSIDERING (outside clause-a denominator)
- `gr-backlog-compose-env-passthrough-audit` (*) — docker-compose passthrough; carries a tripwire ask
- `gr-backlog-tfa-confirm-throttle` — api rate-limit defense-in-depth, filed for record
- `gr-bl-cli-test-send` — bp CLI verb
- `gr-blk-cp-deploy-rollback-stale-env` — cp-deploy.sh ops recipe
- `gr-ops-platform-admin-emails` [PERMANENT HUMAN GATE] — prod env change + restart; explicitly NOT agent-buildable

## PHANTOM (not counted)
- `drafts.cch-w22-s2-site-row-name-and-host-bounded` — absent from the production roster; its published twin `cch-w22-s2-site-row-name-and-host-bounded` is DONE.
- `drafts.task-c64f2a37d7f97bd8` — cancelled twin, also absent.
