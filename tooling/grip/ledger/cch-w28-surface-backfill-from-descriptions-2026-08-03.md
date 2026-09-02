<!-- doc-tier: cold | canonical-for: cch-w28-surface-backfill-from-descriptions | budget: 40000tok -->

# cch w28 — can task DESCRIPTIONS produce a `surface` value where every structured field failed?

> HISTORICAL RECORD (2026-08-03) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Re-derivation recipe + executable backfill list. Verifier artifact, wave 28, assignment `v7-backfill-from-descriptions`.
Stamp 2026-08-03. Ledger read live from `guerrilla.barkpark.cloud`, both epics, `limit=500`, FULL documents (no `--fields` projection).

## RE-DERIVE

```
TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
for p in cloud-console-hardening-epic cch-instruments-epic; do
  curl -sG 'https://guerrilla.barkpark.cloud/v1/data/query/production/task' \
    --data-urlencode "filter[parent_id]=$p" --data-urlencode 'limit=500' \
    -H "Authorization: Bearer $TOK" -o roster-$p.json
done
python3 w28_desc_classifier.py     # protocol + blind arm; script archived alongside this row
```

## THE ANSWER: NO — and the refutation is stronger than the structured-field arm's

| arm | blind accuracy on the 15 open surface-bearing rows |
|---|---|
| structured-field classifier (prior survey) | 6/15 = 40% |
| **description text, frozen weighted rules** | **7/15 = 47%** |
| description + title | 8/15 = 53% |
| description + title + brief + purpose | 7/15 = 47% |
| **`return "instruments"` — one constant, zero reading** | **11/15 = 73%** |

Every text classifier LOSES to a one-line constant. The 40% figure was never a floor worth clearing:
the blind arm is degenerate (gold distribution `instruments 11, console-spa 3, control-plane 1`), so
40% and 47% are both *below chance* for this population. Reporting "47% beats the 40% floor" would
have been the sixth clause in numeric form.

**Confidence carries no signal.** Sweeping the decision margin 1 to 15 never raises precision on valued rows:
it sits at 50-58% across the entire usable range and reaches 100% only at n=1. There is therefore no
mechanically selectable high-confidence subset — the option "scope the guard to the rows the backfill
was sure about" has no operating point under a scoring classifier.

## THE ONE THING THAT DID WORK, AND EXACTLY HOW FAR IT GOES

An **exclusivity** rule — value a row only when its description names artifacts from EXACTLY ONE family,
abstain on every row naming two or more — scores **6/6 on the blind arm and 7/7 including train**, across
THREE distinct tiers (`instruments` 4, `control-plane` 1, `console-spa` 1). It is not the majority class in
disguise: a constant `instruments` would have scored 4/6 on the same rows.

But n=7. The defensible claim is **precision >=65% at 95% confidence** (rule of three on 7/7) — which is
still below what a REFUSAL guard may act on unreviewed. Its honest use is TRIAGE, not backfill:
it converts 94 rows from "a human reads the whole description" into "a human confirms a proposed value
with the deciding sentence already quoted", and leaves 121 rows explicitly UNVALUED.

**Yield over the 215 open rows carrying no `surface`:** valued 94 (instruments 47, console-spa 19, control-plane 20, ledger 8) · **UNVALUED 121**.

## WHY THE CORPUS RESISTS: `surface` IS A THREE-DAY-OLD CONVENTION

Of 471 rows across both epics, 36 carry `surface`. **31 of those 36 were created on 2026-08-02 or 2026-08-03**
(waves 24-27). Of the 347 rows created BEFORE 2026-08-02, exactly **5** carry `surface` — 1.4%.
**144 of the 215 unvalued open rows predate the convention entirely.** The backfill is not recovering a
field someone forgot to fill; it is retrofitting a vocabulary that did not exist when those rows were written.

## `parent_id` IS NOT A PROXY — MEASURED, NOT ASSUMED

**6 of 36 surface-bearing rows (17%) disagree with their parent epic**: six rows whose `surface` names an
instrument sit under `cloud-console-hardening-epic` (`cch-w26-s5-css-check-...`, `cch-w24-s7-...`, `cch-w24-s8-...`,
`cch-w24-s5-...`, `gr-backlog-css-check-missing-classes`, `gr-backlog-reset-route-smoke`). Deriving `surface`
from `parent_id` would encode a 17% error rate into the very input the D307 guard uses to CHOOSE `parent_id`.

## RECONCILING `24 of 343` (D324) AGAINST `36 of 471` (wave 28) — TWO ROSTER DEFINITIONS

| | D324's fraction | wave 28's fraction |
|---|---|---|
| denominator | children of `cloud-console-hardening-epic` **only** | children of **both** epics (288 + 183) |
| lifecycle filter | none (all states) | none (all states) |
| moment | wave-27 Decide, before the re-parent | 2026-08-03, after it |
| value | 24 / 343 = 7.0% | 36 / 471 = 7.6% |

The denominators close exactly: **343 - 55 re-parented = 288**, today's hardening roster. Today's split is
**hardening 26/288** and **instruments 10/183**. The numerator does not close arithmetically from a single
live snapshot, because the ledger keeps no history and `surface` values were authored DURING wave 27's own
Decide (7 surface-bearing rows carry `_createdAt` of 2026-08-03). **The Paper must print both definitions or
neither** — quoting `24 of 343` and `36 of 471` side by side without the denominators reads as a contradiction.

## CONSEQUENCE FOR THE D307 DOOR GUARD

The wave pre-committed a fallback: *if the backfill is larger or messier than wave 27's re-parent, scope the
guard's population to what the backfill reached and SAY SO.* **That fallback is now the live branch.** Priced:

- A mechanical backfill of all 215 rows is refused — it would plant a wrong value on roughly 4 of every 10 rows it touched.
- The exclusivity list below covers **94 rows for human confirmation**, each with its deciding sentence quoted.
- **121 rows are UNVALUED and stay that way.** They are not a backlog item this wave can price.
- Wave 27's re-parent moved 55 rows in minutes because the destination was mechanically derivable. This is not that shape.

## THE LIST

`tier = UNVALUED` means *nobody looked successfully*, not *the row has no surface*. Do not fill these by inference.

### proposed `instruments` — 47 rows

| task id | title | deciding sentence |
|---|---|---|
| `cch-w14-bl-billing-chip-truncated-above-768` | The past-due billing chip is truncated across 769-820 and again at 721 - GR116 cured 768 a | WHY IT SURVIVED: `overflow-guard.mjs` measures this chip at EXACTLY ONE WIDTH (768, its cosmetic half). |
| `cch-w20-bl-console-touch-target-comfort-44px` | 738 of 810 interactive controls are under 44x44 on phone — a COMFORT-bar row, explicitly N | 8 / targetSize over the __preview__ instruments returns nothing, and mutation-proven — `. |
| `gr-backlog-compose-env-passthrough-audit` | Compose passes nothing it does not bare-list — 22 runtime.exs env names are absent from x- | Reference implementation of the narrow form: the docker-compose assertion at the end of test/barkpark_cloud/notifications_platform_admin_env_test.exs. |
| `cch-w27-s6-failed-bar-browser-reread` | The failed provisioning bar's honest aria-valuenow is proven in the unit harness only — ne | That is proven in cloud/priv/static/__app.test.mjs against the committed __preview__/scenarios. |
| `cch-w24-bl-q3-fold-budget-is-a-shell-property-at-320` | `Q3 BELOW THE FOLD` at 320 measures the shell, not the screen — the budget is unreachable  | Driving `breakpoint-sweep --render --widths 320` reds with Q3 defects on every cell tried: `sites`/`activity` report `. |
| `cch-w26-bl-desktop-band-above-1280-unswept` | No instrument sweeps the desktop band above 1280 — the W26 leg is the first to reach 1280  | Before W26-instance-track-min-content, NO leg in overflow-guard.mjs drove 1280: GR108 tops out at 1440 for two past-due scenarios only, W13 stops at 1024, W15 at 1000, W18 at 800, every phone leg at 4 |
| `cch-w25-bl-detail-grid-instance-track-unmeasured` | The instance detail grid keeps a bare 1fr — no fixture in this epic can floor it, so nobod | It was NOT converted, and the reason is the one this epic keeps having to relearn: no leg in overflow-guard.mjs drives an INSTANCE route against a string cruel enough to floor that track, so a convers |
| `cch-w25-bl-new-theater-family-unswept` | The whole /new theater family is unswept — breakpoint-sweep never renders it, and only two | /new is SCENARIO_RESIDUE in breakpoint-sweep. |
| `cch-w24-bl-detail-title-row-not-a-required-wrap-host` | The fifth wrap copy is COUNTED but not REQUIRED — .detail-title-row is missing from WRAP_R | The E14 same-file count pin in __app.test.mjs was bumped 4 -> 5 in review and the host added to the seen-hosts loop, but it was NOT added to WRAP_REQUIRED_HOSTS in __css_check. |
| `cch-w24-bl-nothing-pins-height-against-a-cruel-string` | Nothing pins HEIGHT against a cruel string — the 512-char provision error paints a 399px-t | Every leg in overflow-guard.mjs asserts WIDTH; NOTHING asserts HEIGHT against a cruel string anywhere in this epic. |
| `cch-w24-bl-console-harness-comment-lies-about-cell-flag` | A comment inside the job that gates the console is wrong about the flag that job passes | REFUTED BY RUN: `breakpoint-sweep. |
| `cch-w24-bl-phone-band-unreachable-by-the-width-sweep` | The width sweep's narrowest width is 619, so the phone band 320-618 is unmeasured on every | `breakpoint-sweep. |
| `cch-w23-bl-cruel-leg-blind-to-status-pill-detail` | Cruel-content guard leg never iterates .status-pill-detail | FILED BY cch-w23-s1, NOT TAKEN (overflow-guard.mjs fenced to sibling slices). |
| `cch-w22-s1-residue-modal-oracle-uninvoked` | modal-oracle's exit 2 is read by nobody — wire it into a job or write down why it stays ha | MEASURED then and RE-DERIVED at the collapse: zero CI jobs and zero scripts invoke cloud/priv/static/__preview__/modal-oracle. |
| `cch-w23-bl-site-meta-320-line-guard` | Guard leg: .site-meta stays one line at 320 once a row carries a domain count | FILED BY cch-w23-s3, NOT BUILT BY IT (the brief forbade a fourth overflow-guard.mjs leg this wave). |
| `cch-w22-bl-chip-guard-blind-below-721` | No committed leg reads #billing-chip at a phone width — CHIP_WIDTHS starts at 721 | cch-w16-bl-trial-chip-truncated-on-every-phone criterion 3 requires the chip assertion in overflow-guard.mjs to cover at least 320 and be proven able to fail there. |
| `cch-w21-bl-token-reveal-modal-oracle` | The one-time token reveal is a modal state no modal oracle drives | The token reveal is now measured for READABILITY by overflow-guard's W21-token-reveal-readable leg (16 cells, both themes, 320-430) — but it is still the only high-stakes modal in the console that mod |
| `cch-w19-bl-topbar-620-vertical-cost-unasserted` | The 620 topbar band spends ~60px of the phone's first screen and nothing committed asserts | cch-w17-s-topbar-phone-band-wrap criterion 4 asked for the first committed VERTICAL assertion for this surface; S2 could not ship it because every rendered instrument lives under cloud/priv/static/__p |
| `cch-w19-bl-css-check-has-no-main-guard` | __css_check.mjs cannot be imported: no main-guard, and citationScanFiles is not exported | cloud/priv/static/__css_check. |
| `cch-w19-bl-baseline-one-integer-assertion` | A two-integer cssom baseline stops passing silently — one grep the preflight runs, and the | THE FIX IS ONE ASSERTION: the sidecar must carry EXACTLY ONE bare-integer line (`grep -cE '^[0-9]+$' cloud/priv/static/__preview__/cssom-heads. |
| `cch-w17-bl-overflow-guard-honours-one-defect-flag` | overflow-guard silently runs only the FIRST --defect flag, so a caller who asks for two le | `cloud/priv/static/__preview__/overflow-guard. |
| `cch-w16-bl-tiers5-leg-runs-nowhere` | The five-tier seam runs nowhere — --tiers5 is an instrument no job invokes | cch-w16-s1 shipped breakpoint-sweep. |
| `cch-w15-bl-cuestuck-asks-horizontal-of-a-vertical-cue` | CUE_STUCK asks a HORIZONTAL fit question of the folded sidebar's VERTICAL cue, so 39 of 39 | breakpoint-sweep. |
| `cchi-w26-bl-font-pinned-evidence-narrates-instead-of-reporting` | The FONT PINNED evidence lines print unconditionally — the string narrates the pin instead | The font pin IS real and IS paid — `overflow-guard.mjs:183` imports `FONT_PIN_JS` from `font-pin. |
| `cchi-w25-bl-label-63-pinned-by-inequality-and-the-trailing-hyphen` | Nothing pins the DNS label's UNBROKEN-run length — the only assertion is <= 63, and clean_ | registry_test.exs asserts only `String. |
| `cchi-w23-bl-guard-population-register` | The guard's 68 singular selectors get a population register: a written reason or a printed | The wave-23 sweep classified all 68 `querySelector(` occurrences in overflow-guard.mjs and found that the overwhelming majority are legitimate STRUCTURAL SINGLETONS — but not one of them carries the w |
| `cchi-w22-bl-guard-selector-conversion-instances-grid` | overflow-guard's .instances-grid card assertion is green by construction — it reads card 0 | `overflow-guard.mjs:944` reads `var g=document. |
| `cchi-w22-bl-modal-oracle-never-visits-a-phone-width` | modal-oracle runs at 1440 ONLY and never clicks #a2f-start — every modal in the console is | Neither `breakpoint-sweep. |
| `task-d5c2ffba2ce7b562` | A slice that adds a preview scenario runs smoke.mjs in its own gate — the census refuses w | The slice committed a new scenario (fleet-cruel-content), correctly taught breakpoint-sweep. |
| `cchi-w20-bl-css-check-citation-inventory-mode` | citationScanFiles is unexported behind a gate with no main guard — cch-w16-s7's criterion  | `citationScanFiles` is a bare unexported `function` at __css_check. |
| `cchi-w20-bl-no-vertical-assertion-phone-topbar` | Nothing measures the phone topbar's vertical cost — the 620 wrap grows it 56px to ~116.5px | The criterion as filed claimed 'the first committed assertion of a VERTICAL dimension for this surface (D188)' — that premise is now FALSE and the row must not inherit it: overflow-guard.mjs already a |
| `cchi-w18-bl-seal-predicate-header-asserts-absent-wiring` | seal-predicate.mjs's header asserts a wiring that does not exist — the second self-refutin | `seal-predicate. |
| `cchi-w18-bl-overflow-guard-server-cap-and-leaked-child` | overflow-guard's 8000ms server cap manufactures FALSE exit-2 refusals under load, and the  | `SERVER_CAP = 8000` (overflow-guard.mjs:309). |
| `cchi-w18-bl-overflow-guard-chip-epsilon-undeclared` | overflow-guard's chip check carries an undeclared, unmarked ±1px epsilon on EVERY width | `overflow-guard.mjs:630` reads `const cut = chip. |
| `cch-w16-bl-export-recipe-manufactures-false-reds` | The charter's own export recipe manufactures reds that are not on main — every builder who | MEASURED, three shapes, three different answers for the SAME commit: PATH-SCOPED export (`git archive origin/main cloud/priv/static`): `node --test cloud/priv/static/__app.test.mjs` reports `# pass 75 |
| `cch-w13-bl-supportrow-constant-hints-uncovered` | supportRowHtml renders four constant-paced pace hints that no test pins | Driving them individually, supportRowHtml emits FOUR pending constant-paced pace hints, and NO test in __app.test.mjs pins any of them. |
| `cch-w13-bl-overflow-guard-and-modal-oracle-ungated` | The epic's two browser instruments are run by no workflow, so extending them buys zero reg | Wave 13's band slice extends overflow-guard.mjs with a detail-route sweep - the right place for it, but it stops a regression only for whoever runs it by hand. |
| `gr-bl-overflow-guard-route-blind` | overflow-guard.mjs never applies a scenario deepLink, so no instance-detail panel is measu | The frozen overflow-guard.mjs navigates bare `?scen=<name>&theme=<t>` URLs and contains ZERO occurrences of `deepLink` or `location. |
| `gr-blk-accent-scenario-sweep` | Sweep the 74 scenarios never measured under the four non-default accents | gr-p5r7-tablet-overflow is landing a committed browser guard (cloud/priv/static/__preview__/overflow-guard. |
| `gr-blk-hashchange-listener-wiring-proof` | The hashchange modal-close is proven at the DECISION, never at the WIRING | Why it is unproven: init() is only ever REGISTERED in the __app.test.mjs vm sandbox (document. |
| `gr-backlog-coherence-fixture-durable` | Make coherence.html READ the TUI goldens instead of embedding them, so a foreign cycle can | The structural problem stays: cloud/priv/static/__preview__/coherence. |
| `gr-backlog-scenario-drive-field` | Promote the account-modal shot conventions to a scenarios.mjs field | sh derives '&modal=account' from the 'account-modal*' NAME PREFIX (its own header states this is a convention, not a contract, and says to promote it to a scenarios.mjs field once the tail zone is qui |
| `cch-bl-d34-wrapper-list-correction` | D34's 8-wrapper auth list is incomplete — the router has 12 session wrappers, and the char | With the corrected sets (12 session + 2 machine) the prototype's 62/45/5/12 reproduces byte-identically, which is why the committed census pin (cloud/test/barkpark_cloud/web/router_head_fence_census_t |
| `gr-bl-shootsh-scen-suggester-false-done` | shoot.sh scenario suggester — the fix was marked done but never landed on main | origin/main's cloud/priv/static/__preview__/shoot. |
| `cch-w12-followup-smoke-who-axis-expectation` | The smoke "activity" expectation still asserts nothing about the Who axis it can now see | cch-w12-s1 gave the "activity" scenario a members roster (ada/lin/rex), so smoke.mjs can now SEE the Who axis on the epics own default Activity fixture - but EXPECTATIONS. |
| `cch-w12-bl-seal-predicate-header-comment-stale` | seal-predicate.mjs's own header comment is stale: it says CCH-D5 is rung 3 and clause (b)  | `cloud/priv/static/__preview__/seal-predicate. |
| `cch-w12-followup-login-fixture-gap` | The preview harness has no successful-login fixture, so no identity change can ever be DRI | The logged-out branch of render() is the one seam where a console lie about IDENTITY can be built - it serves both the sign-out click and the 401 auto-bounce, neither of which reloads - and it is the  |

### proposed `console-spa` — 19 rows

| task id | title | deciding sentence |
|---|---|---|
| `cch-w25-bl-cred-back-lands-on-a-picker-nobody-came-from` | The credential sheet's Back button sends a launch person to a picker they never came from | That picker has EXACTLY ONE reference in cloud/priv/static/app.js — this back button — so it is not an entry door at all: nobody arrives at the credential sheet through it. |
| `cch-w23-bl-cred-form-ids-have-two-hosts` | The credential form's ids are rendered by two hosts, so the modal drives the page's fields | `#cred-submit`, `#cred-label`, `#cred-token` and the four `#cred-az-*` inputs are each rendered by TWO hosts: the providers page's connect card (app.js providerConnectCardHtml) and the credential moda |
| `cch-w19-bl-op-gate-dot-centring-at-320` | The operator gate's status dot sits beside line 2 of a 3-line sentence at 320 — the defect | op-gate { align-items: center }` (`app.css:5099`) puts the pill at 1029-1053 — dot centre 1041, i. |
| `cch-w15-bl-real-nav-toggle-wave` | A REAL nav toggle is the only shell with headroom — and it is a wave, not a slice | DO NOT ship it as a slice beside other app.css work. |
| `cch-w13-s1-residue-planned-fill-and-ring` | The planned rail still LOOKS determinate: the master-bar fill and the active ring are draw | Discovered while building task-1f8bcab494ac0a3a (wave 13 S1) and DELIBERATELY not taken - both remaining pieces need app.css, which belonged to sibling slices this wave (charter D159). |
| `gr-backlog-operator-palette-entry` | Cmd+K palette cannot offer Operator: paletteNavItems() is a static argument-free registry | WHY: paletteNavItems() (cloud/priv/static/app.js ~14601) is a static registry that takes NO arguments - it hardcodes seven nav entries plus SETTINGS_VIEWS. |
| `cchi-w27-bl-preview-deploy-meta-unmeasured` | The preview row's .deploy-meta is claimed bounded by derivation, never by measurement | THE CLAIM MADE THERE, and it is a SENTENCE, not a measurement: on a preview row, previewRow() (cloud/priv/static/app.js:10273-10278) builds . |
| `cchi-w27-bl-preview-detail-caption-unmeasured` | The preview row's deployDetailHtml caption renders the builder's unbounded stage detail an | deployDetailHtml (cloud/priv/static/app.js:10307) renders d. |
| `cch-w25-bl-d298-footer-value-pair-unobservable` | D298's break-word/anywhere pair is MASKED on the deploy rail — re-measure it with the step | new-step-detail` neutralised in the probe (mutation-only, never shipped), which isolates the footer and either reproduces 1011 or does not; or (b) accept that the footer's value is chosen by THE WRAP  |
| `task-13f830a9c36314e0` | The W19-S2 sidecar prose misattributes the flattened-selector move 1218 to 1221 to its own | topbar (app.css:794), . |
| `cch-w16-bl-no-preview-plus-production-console-fixture` | No console fixture carries a cancelled preview beside a live production deploy — the fresh | The console half of that ruling therefore has no browser-level guard, and a regression in app.js's freshness paint would be invisible to every harness in this epic. |
| `cch-w15-bl-detail-url-fixture-never-overflows` | No design-corpus fixture makes .detail-url-text actually overflow, so its ellipsis is unpr | That row is correctly CLOSED — the ellipsis rule ships at app.css:4594 and the adjacent copy-btn at app. |
| `cch-w15-bl-lega-cannot-refuse-removed-breakpoint` | The sweep's coverage refusal is one-directional — a REMOVED breakpoint stays green and pri | Removing a declared `@media` breakpoint from app.css therefore leaves Leg A at **exit 0** while it prints a line that cannot be true — `4 breakpoints [620,720,768,899] -> 13 boundary widths [. |
| `cchi-w26-bl-deploy-rail-fail-value-has-no-leg-that-can-lose` | The deploy-rail footer's wrap value cannot lose — flipping it is byte-identical in all six | `app.css:5055-5057` is honest about it ("chosen by the RULE at the head of this file rather than by a pixel difference this surface can show"), but a value whose only guard is a sentence is not guarde |
| `cchi-w23-bl-plural-layer-second-order-refusals` | Three plural guard legs count their rows and never count the sub-hosts they assert on | inst-tabs` — renaming the SOLE emitting template (`<nav class="inst-tabs">`, app.js:5656) leaves `W21-inst-head-320-copy-reachable` at rc=0 with BYTE-IDENTICAL output, including its own second ok-line |
| `cchi-w21-s6-ci-renders-a-boundary-cell` | CI renders a breakpoint the sweep actually derived — today its only rendered width is off  | So ZERO of the eighteen boundary widths this epic derived from app.css's own @media rules is ever rendered in CI. |
| `gr-blk-serve-stale-guard` | serve.mjs port-collision guard: a foreign worktree's server silently serves the wrong byte | A preview server left running by a FOREIGN worktree squatted the port and served 187302 B (the primary checkout's origin/main app.css) while the probe's own tree held 189086 B. |
| `cch-bl-preview-selector-residue` | Preview shim residue: document-level attribute loops, the compound token selector, and the | Six document-level attribute loops in app.js stay dead. |
| `cch-bl-smoke-document-attr-selectors-still-dead` | Six document-level attribute loops stay dead: the smoke shim's document.querySelectorAll h | Wave 10 widens ELEMENT-level `querySelectorAll` to attribute selectors, which frees 15 of the 21 bare-`[attr]` call sites in `app.js`. |

### proposed `control-plane` — 20 rows

| task id | title | deciding sentence |
|---|---|---|
| `cch-w26-bl-deployment-failed-email-still-unhumanized` | The deployment_failed and agent_unreachable alert emails still send raw jargon | event_email.ex detail/1 is still the body for :deployment_failed and :agent_unreachable, and it is FailureCopy. |
| `cch-w23-bl-pat-deploy-grant-survives-demotion` | A deploy PAT minted as admin keeps deploying after the user is demoted to member | create_personal_access_token/3` (accounts.ex:838), which calls `pat_abilities_allowed?(Authz. |
| `cch-email-format-missing-u-modifier` | email_format accepts NBSP because it carries no /u modifier — the email column is wider th | accounts/user.ex:31 defines email_format with no u modifier, so PCRE reads whitespace as ASCII-only. |
| `cch-w13-rv-scrub-eats-bracketed-prose` | The failure scrub still redacts a bracketed placeholder that holds no secret | Wave 13 review added a `@prose_value` stop-list to FailureCopy's Bearer and key=value clauses, which killed five live false positives on ordinary failure text ("no bearer token found in the request",  |
| `cch-bl-floor-blind-to-readme-and-uncalled` | The required-checks floor guards contexts only, is blind to readme loss, and no workflow c | It refused with code label_spine, and the cause was one field: the `infra` tag's rationale read "CI wiring", 9 characters, against @min_rationale 20 in api/lib/barkpark/content/label_spine.ex:60. |
| `task-4f363dc65ac43203` | A new raw-failure JSON channel can be added without the display-boundary scrub — nothing g | Wave 13 S2 shipped FailureCopy. |
| `cch-w13-bl-azure-subscription-display-name` | Price a SERVER-CONFIRMED azure account identity, not an echo of what the person typed | verify/1 (cloud/lib/barkpark_cloud/azure/client.ex:184-193) returns %{subscription_id: Map. |
| `cch-w11-s1-flip-behind-a-generator-that-cannot-lose` | Console gate and Cloud gate become required — behind a generator that can no longer lose a | THE ARITHMETIC, DERIVED (D129): committed base 2 -> generator emits 6 -> naive jq-merge union 8 -> minus the 3 promoted security leaves = 5 -> minus `Required-check spec gate` = 4, byte-exactly ["Clou |
| `cch-w12-bl-session-touch-has-no-rescue` | touch_session_last_used has no rescue while its PAT twin does — a DB hiccup inside before_ | `cloud/lib/barkpark_cloud/accounts.ex:1875-1883` wraps the PAT last-used stamp in `try/rescue` + `Logger. |
| `gr-backlog-operator-digest-send` | POST /v1/operator/digest/send - the cut Send-one-now button's route (GR40 successor) | deliver_fleet_digest (cron-only, daily_digest_worker.ex:30) and GR28 forbids a button without a route. |
| `task-1ed6264c65762b37` | Book the w27-s2 SSE scrub as a secret-boundary claim needing an independent second review  | cch-w27-s2 added FailureCopy. |
| `task-fda5b6f19f1e06c9` | A site READ TOKEN 401 is classified as 'the hosting provider rejected our credentials' — t | FailureCopy. |
| `cch-w23-bl-site-domains-cruel-family` | site.domains joins the cruelty ledger with a FORMAT-LEGAL generator, not a length one | Cap 253, enforced by `validate_change` + `@domain_format` (registry/site.ex:28, :431-436) — so it is INVISIBLE to a `validate_length` census, which is exactly D252's point about census-driven ledgers. |
| `cchi-w25-bl-live-protection-requires-two-while-the-spec-declares-four` | Console gate and Cloud gate were committed as REQUIRED and never applied — live protection | json` declares FOUR required contexts (Cloud gate, Console gate, Elixir gate, PR references an active task) with enforced:true and enforce_admins:true, added by #8394 (dcd8c9cef, 2026-07-31, "feat(gat |
| `cchi-w20-bl-console-harness-advisory-prose-stale` | Two prose blocks in console-harness.yml claim Console gate is ADVISORY while the committed | yml:283-287` and `:485-489` both read: 'HONEST SCOPE: `Console gate` … is ADVISORY today — the live required set is `Elixir gate` and `PR references an active task`. |
| `cch-w16-bl-publish-door-has-no-published-row-cas` | The publish door is a semantic pre-gate, not a concurrency fence — the published row still | FILED HERE FOR VISIBILITY, NOT FOR OWNERSHIP — the code is `api/lib/barkpark_cloud`'s sibling `api/lib/barkpark/content/lifecycle.ex`, a live PDS wave works that tree, and the right owner is the PDS e |
| `cch-w11-bl-aggregator-decide-shape-ratchet` | cloud.yml and console-harness.yml have byte-identical decide() discipline today — nothing  | yml and elixir. |
| `cch-bl-bp-graph-drift-stale-protection-claims-2` | bp-graph-drift still cites the 404 'Branch not protected' measurement | Protection has been live since 2026-07-28 with enforce_admins:true and contexts [Elixir gate, PR references an active task] (charter D104/D106), so the parenthetical is false and the ADVISORY label re |
| `cch-cloud-gz-guard-ci-wiring` | Wire scripts/cloud-static-gz-guard.sh into CI — today it is a committed tripwire that noth | gitignore, cloud/lib/barkpark_cloud/web/router.ex and scripts/cloud-static-gz-guard. |
| `cch-bl-nul-native-path-matcher` | The path matchers read NUL-separated bytes, so a newline inside a directory prefix stops b | Wave 10 replaced the diff producer in elixir. |

### proposed `ledger` — 8 rows

| task id | title | deciding sentence |
|---|---|---|
| `cch-w19-bl-stamp-merge-gated-flag-undocumented` | `bp task stamp --merge-gated` exists but is absent from the capabilities manifest | `bp capabilities -o json` lists task stamp's flags as [criterion, criterion-text, met, evidence, miss, note] and `bp task stamp --help` prints the same six. |
| `cch-w19-bl-gr115-intermittent-ua-defaults` | GR115-bpconsole-dead-rule reported UA defaults on one ubuntu run and clean on the next | Parent: cloud-console-hardening-epic (the parent_id patch was rejected validation_failed at build time; the lead should re-parent). |
| `cchi-w26-bl-stranded-draft-is-a-silent-plus-one` | A stranded draft shadows a finished slice and would raise orphans 112 to 113 if anyone pub | `bp task get cloud-console-hardening-epic` reports 334 children and 116 live; the seal predicate's own roster (the production query) reports 332 and 115. |
| `cch-w16-bl-stamp-readback-said-landed-then-gone` | A stamp whose own read-back said 'the store holds it' was found reverted one write later — | INDEPENDENT re-read (bp task get -o json, fresh process): criterion 0 met=true 2102 chars, criterion 1 met=FALSE evidence LENGTH 0, criterion 2 met=false with the note present. |
| `cch-finding-roster-tooling-contract` | STANDING FINDING: how to read a task roster without being lied to | bp task get EPIC -o json then . |
| `gr-backlog-orphan-reap-signature` | A reap that matches on process name alone kills concurrent sessions' live work — match on  | Three of four verifiers found zero orphaned headless Chrome; a fourth found and reaped five genuine orphans (4 Chrome + 1 serve. |
| `cch-w12-bl-mirror-syncs-unpublished-drafts` | The GitHub bridge mirrors UNPUBLISHED drafts to real issues, and deleting the draft leaves | `bp task create` produced documents at `status: draft`, `_draft: true` - and each acquired `content. |
| `task-4a591a26279e7d24` | No gate stops a hardcoded population count from re-entering console-harness.yml | Filed by the wave-7 reviewer because bp task create was returning 500 at build time (charter D95). |

### UNVALUED — 121 rows (explicitly not guessed)

| task id | title | why no value |
|---|---|---|
| `cch-w25-bl-site-name-drags-1885px-at-900-on-the-compact-builder` | A site named honestly drags the instance Sites card 1885px sideways at 900 — D289 cleared  | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w14-bl-site-open-phone-overflow` | The site detail page scrolls sideways on every iPhone in portrait, and no instrument has e | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w20-bl-detail-url-text-ellipsised-on-phone` | The instance detail head loses the TLD too — .detail-url-text ellipsises the canonical add | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w21-bl-cred-remediation-scrolls-above-the-viewport` | The longest real provider remediation string scrolls its own first line 21px above the vie | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-bl-cloudflare-identity-echo-no-surface` | Cloudflare connections say WHICH account they point at (no surface today) | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width` | The account menu's identity lines show ~15% of their content on a 900px desktop and nothin | names no artifact family |
| `cch-w24-bl-word-break-alias-has-no-ruling` | The wrap doctrine is written in `overflow-wrap` vocabulary while 16 sites use the `word-br | names no artifact family |
| `cch-cloud-app-has-no-plug-errorhandler` | The cloud app has no Plug.ErrorHandler — every raise on every route is a bare 500 with no  | names no artifact family |
| `cchi-w22-bl-shared-modal-card-min-content-floor` | Every other modal body shares the same min-content floor — only the account modal was refl | names no artifact family |
| `cch-rtl-script-neutral-borrowing` | A genuinely RTL email still borrows the neutrals around it — esc-strip kills the override, | names no artifact family |
| `cch-w22-s7-cruelty-ledger-effective-caps-and-classes` | Make cruel the DEFAULT: a name-keyed cruelty ledger over every text host, deriving EFFECTI | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cch-w22-bl-fleet-meta-inadmissible-spill` | `.fleet-meta` and `.fleet-infra` spill 1586px under a 255-char region — the host is unprot | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cch-w21-bl-inst-head-fit-content-621-899` | The instance head is still fit-content between 621 and 899, where the shared detail head s | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w21-bl-status-pill-detail-fed-by-uncapped-error` | The status pill's WHY sentence is fed by a string nothing caps — worker socket to pill, th | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cch-w20-bl-attention-band-wrap-point-not-uniform` | The 769-899 attention band wraps at a different point per row, because the status pill has | names no artifact family |
| `cch-w20-bl-console-type-floor-sub-12px` | 228 text instances compute below the console's own 12px type floor — and this epic refuses | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w16-bl-instance-site-row-never-deployed-says-nothing` | The instance workspace's Sites card says NOTHING about a never-deployed site — now that it | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cch-bl-scroll-driven-cue-firefox-fallback` | The two-state scroll cue is INVISIBLE in Firefox — both .set-matrix and the archives CLI c | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w12-s5-successor-split-and-letterbox-fence` | Fence the seal predicate's dead letterbox, then split the epic: instrument rows get a REAL | names 2 artifact families (instruments,ledger) — not exclusive |
| `cch-w12-bl-independent-review-owed-wave-12` | Wave 12 owes an INDEPENDENT second review on three high-flip-risk slices — filed as a row  | names no artifact family |
| `cch-w12-bl-events-422-overstamps-session` | A 422 no_team from GET /v1/events still advances last_used_at — and a merged test pins tha | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-w12-bl-redact-env-secrets-opt-in-on-3-of-24` | The provisioner's secret scrub is OPT-IN and set on 3 of 24 step sites — unscrubbed remote | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cch-cloud-static-gzip-html` | styleguide.html is in the gzip-enabled allowlist but no .gz is built for it — 40,625 bytes | names no artifact family |
| `cch-w11-residue-security-gate-registration-policy` | Security gate went GREEN mid-wave — decide whether it is registrable, because the generato | names no artifact family |
| `cch-w11-bl-required-checks-live-suite-unrun-at-four` | The live half of required-checks.test.sh has never been run at four contexts — only the he | names no artifact family |
| `gr-backlog-console-redaction-allowlist` | Provisioner console redaction is a fixed allowlist — harden against future secret-shaped n | names no artifact family |
| `gr-bl-gr108-fix-overdetermined` | GR108's landed fix is over-determined — removing .topbar-right > * { min-width: 0 } does N | names 2 artifact families (instruments,console-spa) — not exclusive |
| `gr-blk-cp-deploy-rollback-stale-env` | cp-deploy.sh's documented `docker start` rollback recipe serves stale env from the dormant | names no artifact family |
| `gr-backlog-tfa-confirm-throttle` | Defense-in-depth only: POST /v1/account/two-factor/confirm has no rate limiter (ruled NOT  | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-bl-lifecycle-token-reaper` | The other short-lived user_tokens contexts still accrete — reset / confirm / change_email  | names 2 artifact families (instruments,control-plane) — not exclusive |
| `gr-backlog-tablet-width-audit` | Console-wide 768px tablet-width audit - other components may share the unguarded-breakpoin | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-hg-compose-network-recreation` | HUMAN GATE: recreate the cloud compose network once so the pinned ipam subnet can attach | names no artifact family |
| `gr-ops-platform-admin-emails` | OPS GATE: set PLATFORM_ADMIN_EMAILS on the live control plane so the operator console is r | names no artifact family |
| `gr-backlog-qr-live-scan-proof` | Live-scan the shipped 2FA QR with real authenticator apps - byte-identity is not a phone | names no artifact family |
| `gr-bl-cli-test-send` | bp cloud webhook test-send — the CLI verb the SPA's Send test button has no chip for | names no artifact family |
| `task-3b59e1ea682c03a1` | Two D310 tails stand after w27-s2: provision steps and console carry capture with no class | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `task-877bfc465162e104` | Wire the CLASSIFYING rail-fail fixture into a scenario — it is exported and routed nowhere | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-w27-bl-seal-predicate-stale-tree-unrefused` | The seal predicate accepts a STALE or DIRTY git root — the third provenance failure mode,  | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-backlog-bpbase-envelope-incomplete` | The preview barkpark row envelope is missing six fields the server serializes on every row | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-w26-bl-choice-picker-css-unproduced` | The deleted provider picker left .choice-* rules in app.css with no producer | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w16-bl-legb-drives-one-of-three-heights` | Leg B renders at ONE height while HEIGHTS declares three (390/667 never driven) | names no artifact family |
| `cch-w23-bl-real-hetzner-remediation-scenario` | The real hetzner remediation has no scenario to live in (a new SCENARIOS key reds the brea | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w23-bl-cruel-identity-own-scenario` | The cruel account identity gets its own named scenario instead of riding account-modal-rev | names 2 artifact families (instruments,control-plane) — not exclusive |
| `task-696a2fcf95e9c4da` | Permanent guard leg: the site row's three text hosts, cruel by fixture (W22-S2 follow-on) | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cch-w22-bl-attention-sibling-never-measured` | Two attention-row criteria closed unmet: the .instance-card-head sibling was never measure | names no artifact family |
| `cch-w22-bl-url-remedy-candidates-never-priced` | The instance-card-url remedy was chosen without pricing its alternatives — criterion 1 of  | names no artifact family |
| `cch-w19-bl-e14-shorthand-blind` | E14 is blind to the shorthand form of the wrap recipe — a padding: 2px 11px fourth copy is | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w19-bl-w13-rail-pill-pooled-zero-check` | W13's rail-pill guard is POOLED, so routes that render no rail assert nothing under a gree | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w19-s1-guard-loses-in-ci` | The overflow guard is proven able to LOSE — two CI contexts move together on a deliberate  | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cch-w19-bl-harness-width-prose-four-sites` | The width prose is stale at FOUR sites, not two — and two of them are named by no filed ro | names 2 artifact families (instruments,console-spa) — not exclusive |
| `task-d862cf7f8e1108c1` | overflow-guard.mjs never awaits document.fonts.ready — every pinned number can be measured | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w18-bl-smoke-address-copy-assertion-matches-the-rail-row` | smoke.mjs:1386 asserts the address copy affordance but is satisfied by the rail's host row | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cch-w18-bl-attention-fixture-string-not-production-dominant` | The attention-pill fixture serves a string production almost never produces — every pin in | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cch-w17-bl-css-slice-gate-must-include-leg-a` | A CSS slice that adds or removes a @media breakpoint must run breakpoint-sweep Leg A in it | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w17-bl-e11-scan-set-app-css-and-shoot-sh` | E11 cannot see two file classes it now bans citations INTO: app.css cites itself twice, an | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w16-s7-citation-anchors-e11-widening` | A citation that can go stale without failing stops being possible — E11 widens, and all fo | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cch-bl-w15-fleet-leg-scenario-axis-of-two` | overflow-guard's W15 fleet leg drives 2 of the fleet-bearing scenarios, and cannot refuse  | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w15-bl-publish-wall-rationale-length-opaque` | The publish wall refuses a short tag rationale and never says so — it costs minutes to loc | names no artifact family |
| `cch-w15-bl-target-reuse-ascending-order-pin` | CDP target reuse is 8.3x faster and byte-identical — but ONLY ascending, and nothing pins  | names no artifact family |
| `cch-w15-bl-plan-catalog-no-fixture-seam` | PLAN_CATALOG is a hardcoded literal — no scenario can ever render a five-tier billing scre | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w23-bl-three-screens-zero-geometry-coverage` | Three console screens have no geometry coverage at all, and two shipped payments there are | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w15-bl-render-leg-node22-job` | A widened sweep --render leg needs its own node-22 browser job — it cannot live in console | names no artifact family |
| `cch-w12-bl-filing-law-parent-charter-half` | The filing law is written into the instruments charter but NOT into the parent charter — t | names no artifact family |
| `cch-w13-rv-gate-must-run-css-check` | A slice that emits a new class runs __css_check in its own gate | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w26-bl-eight-live-rows-can-never-be-stamped` | Eight live rows carry no acceptance_criteria key at all — they can only leave by cancel or | names 2 artifact families (console-spa,ledger) — not exclusive |
| `cchi-w26-bl-two-unhumanized-failure-tails` | deprovision_error renders raw in the SPA and provision_steps/console are scrubbed but neve | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cchi-w26-bl-8500-decision-packet-and-the-relabel-trap` | #8500 is decision-ready and unblocks ~65 of 112 orphans — with a trap that makes a re-pare | names 2 artifact families (instruments,ledger) — not exclusive |
| `cchi-w25-bl-w21-bp-tl-fail-cell-is-an-identity-under-anywhere` | The W21 cruel cell can no longer fail on .bp-tl-fail — a 5000-char token gives a byte-iden | names no artifact family |
| `cchi-w23-bl-d253-inert-ellipsis-correction-five-sites` | The refuted inert-ellipsis doctrine is live in five places, one of them the string an oper | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w22-bl-guard-port-contention-silently-measures-a-foreign-tree` | The stale-server refusal only fires once bytes DIVERGE — a builder measuring an unmodified | names no artifact family |
| `cchi-w22-bl-breakpoint-sweep-prose-says-75` | Three prose sites in breakpoint-sweep.mjs still say 75 residue and 100 scenarios while the | names no artifact family |
| `cchi-w22-bl-cruel-corpus-uncovered-caps-second-tranche` | Three reachable text hosts have ZERO fixture coverage — and one 255-cap field is rendered  | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `cchi-w22-bl-seal-predicate-claims-merge-blocking-force` | seal-predicate.mjs still certifies merge-blocking force the live branch does not have — a  | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cchi-w21-bl-ledger-disposition-wave-21` | Wave 21's named repayment: 14 merge-gate-scheduled closes, five duplicate clusters, three  | names 3 artifact families (instruments,console-spa,ledger) — not exclusive |
| `cchi-w21-bl-guard-readiness-poll-nondeterministic` | overflow-guard's readiness poll flakes on a loaded host, and its refusal is indistinguisha | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts` | The cruel corpus stops at two hosts — .detail-url-text, .status-pill-detail and member ema | names no artifact family |
| `cchi-w21-bl-clip-no-cue-exempts-inert-ellipsis` | breakpoint-sweep's CLIP_NO_CUE exempts an ellipsis that can never paint — a false green fo | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w20-bl-guard-greens-when-its-hosts-disappear` | The overflow guard goes VACUOUSLY GREEN when its hosts are display:none — it still claims  | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w20-bl-breakpoint-sweep-fonts-blind` | breakpoint-sweep.mjs is as font-blind as the overflow guard and no row covers it — D218's  | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w20-bl-phone-band-billing-chip-unguarded` | No committed leg asserts #billing-chip below 721 — the merged 620 topbar fix could be reve | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cchi-w18-bl-e11-scan-set-third-blind-spot-baseline` | cssom-heads.baseline is a THIRD E11 scan-set blind spot the filed row does not name — 3 ci | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w16-bl-slice-gates-omit-instruments-that-scan-the-file` | A slice gate that omits an instrument scanning the file it edits is not a gate — s2 shippe | names 3 artifact families (instruments,console-spa,ledger) — not exclusive |
| `cch-w16-bl-seal-predicate-certifies-an-unenforceable-gate` | The seal predicate certifies defects as merge-blocking through a gate that cannot block a  | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-w14-s1-continuous-breakpoint-sweep` | The responsive sweep walks the stylesheet's own breakpoints and asks three questions at ea | names 4 artifact families (instruments,control-plane,console-spa,ledger) — not exclusive |
| `cch-w14-bl-sweep-navwall-pin-removal` | Remove the breakpoint sweep's nav-wall pin once the folded shell stops pushing .content 74 | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w14-bl-tablet-width-audit-rescope` | The tablet-width audit row is re-scoped against the sweep that discharges its criterion 0, | names 2 artifact families (console-spa,ledger) — not exclusive |
| `cch-w13-bl-fresh-badge-unknown-dead-class` | freshnessModel emits a dot class with no CSS rule, and the comment two lines above says th | names 2 artifact families (instruments,console-spa) — not exclusive |
| `gr-backlog-cssom-parity-count-skew` | CSSOM parity: rule on the Set-vs-multiset exposure, correct the duplicate-selector census  | names no artifact family |
| `gr-blk-cssom-parity-harden` | cssom-parity: promote COUNT SKEW to fatal, and widen past app.css | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-bl-webhook-delete-oracle` | The preview's webhook delete leg — the two blockers cch-w10 named, cleared | names 2 artifact families (instruments,console-spa) — not exclusive |
| `gr-backlog-css-brace-detector` | __css_check: structural brace/comment-balance detector (E10) | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-bl-thirtyone-done-rows-cite-branch-shas` | Thirty-one done rows cite branch SHAs where standing law 1 demands merge SHAs — reconcile  | names no artifact family |
| `cch-bl-citation-drift-cross-language` | Citation-drift ban does not span the JS/Elixir boundary — router.ex-side line citations st | names 3 artifact families (instruments,control-plane,console-spa) — not exclusive |
| `gr-bl-reap-orphaned-preview-port-squatters` | An orphaned test squatter has held guard port 4199 for hours — reap it and stop the guard  | names 2 artifact families (instruments,console-spa) — not exclusive |
| `gr-blk-oracle-modal-callsite-coverage` | The CSSOM oracle certifies one consumer of openModal, not the shared primitive's other 15+ | names no artifact family |
| `cch-bl-destroy-verbs-stateless-family` | Twelve more destroy verbs report success over an unchanged list in the browser preview — t | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-bl-styleguide-inline-css-uncertified` | styleguide.html ships ~194 lines of inline CSS that the parity gate never certifies, and i | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `gr-bl-github-mirror-reparent-residue` | A re-parented task keeps its old GitHub sub-issue link and its stale parent marker — body  | names 2 artifact families (control-plane,ledger) — not exclusive |
| `cch-bl-rescue-dangling-charter-commits` | Eight charter commits survive only as dangling objects in the shared checkout and are one  | names no artifact family |
| `gr-backlog-accent-matrix-rereview` | Re-run and actually review the full accent matrix - every prior non-evergreen claim in thi | names no artifact family |
| `cch-w2-revoke-oracle-round2` | Click-oracle round 2: the six constant-toast destructive DELETEs get wire coverage | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-bl-boundary-marker-registry` | The @boundary-marker registry — auto-enforce D41 so a new boundary comment cannot ship as  | names no artifact family |
| `gr-blk-a2fwire-coverage` | a2fWire()'s click -> api -> repaint chain has zero unit coverage — only static a2fPaint ma | names 2 artifact families (instruments,console-spa) — not exclusive |
| `gr-bl-seal-guard-port-and-stderr` | The seal guard binds a fixed port and the predicate discards its stderr — a mechanical fai | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-bl-smoke-shim-fidelity` | Smoke shim fidelity: model DOM detachment, and stop delivering clicks to disabled elements | names 2 artifact families (instruments,console-spa) — not exclusive |
| `gr-blk-shootsh-guard-regression` | shoot.sh's four new guards have no automated coverage — a regression test for the harness' | names no artifact family |
| `gr-p5-session-preview-delete-routes` | Preview scenarios answer BOTH session DELETE routes, not just the GET | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w12-bl-e12-blind-to-border-width` | __css_check's E12 focus guard is blind to border WIDTH — its opaque-border escape is textu | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w10-diff-producer-sweep` | reland-check.yml and deploy.yml carry the same quotepath/rename false-green | names no artifact family |
| `cch-bl-branch-tips-never-rebased` | Wave-2's four branches merged without ever being rebased — record the posture or the next  | names 2 artifact families (control-plane,console-spa) — not exclusive |
| `cch-bl-unpushed-base-branches` | Four wave-1 base branches exist only as local refs in the primary checkout — a force-push  | names no artifact family |
| `task-5acf9b5ad30f9a74` | E12 focus-band coverage gaps: styleguide.html inline CSS and band-less :focus rules are un | names 3 artifact families (instruments,console-spa,ledger) — not exclusive |
| `cch-bl-task-create-intermittent-500` | D105 is REFUTED: task create is not a wholesale outage, it is an intermittent internal_err | names 2 artifact families (instruments,ledger) — not exclusive |
| `task-43f7662b33e8e0b7` | Clause (b) can PASS for the first time: the sign-in rate limiter gets measured, and the ha | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-bl-elixir-ratchet-blind-to-cloud-test` | The elixir path-escape ratchet certifies the exact hole it exists to catch: it declares no | names 2 artifact families (instruments,control-plane) — not exclusive |
| `cch-adopt-check-runs-lib-in-required-checks` | required-checks-generate.sh and -verify.sh adopt scripts/lib/check-runs.sh instead of each | names no artifact family |
| `cch-w10-merge-gates-doc-drift-security-topology` | merge-gates.md still describes security.yml as workflow-level paths-filtered — wave 10 del | names no artifact family |
| `task-9b3778f52ca05984` | Wave Papers publish with tables readers cannot render: string cells pass the writer, fail  | names no artifact family |
| `cch-w11-bl-breakglass-blind-to-stale-checkout` | A real 74-second protection outage left ZERO rows in the break-glass log — the offline com | names no artifact family |
| `cch-w11-bl-unmodelled-delete-route-arms` | Four destroy verbs answer the preview's terminal catch-all 200 — they would report success | names 2 artifact families (instruments,console-spa) — not exclusive |
| `cch-w12-bl-cve-gate-is-oracle-blind` | The blocking CVE gate is oracle-blind: mix_audit reports clean while Hex's own feed report | names no artifact family |

