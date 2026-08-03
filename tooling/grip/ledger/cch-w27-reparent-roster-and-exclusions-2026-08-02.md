# CCH wave 27 — re-parent roster, exclusions, and the post-condition recipe

Derived 2026-08-02 by the wave-27 verifier `reparent-roster-and-exclusions`.
Ledger reads are LIVE (guerrilla); every number below is re-derivable by the
commands quoted. Nothing here was written to the ledger by this row.

## 1. The census at derivation time

    python3 -c "import json,subprocess,collections;\
    a=json.loads(subprocess.check_output(['bp','task','get','cloud-console-hardening-epic','-o','json']));\
    b=json.loads(subprocess.check_output(['bp','task','get','cch-instruments-epic','-o','json']));\
    print('PARENT',a['child_count'],collections.Counter(c['lifecycle_status'] for c in a['children']));\
    print('SUCC',b['child_count'],collections.Counter(c['lifecycle_status'] for c in b['children']));\
    print('INTERSECT',len(set(x['doc_id'] for x in a['children'])&set(x['doc_id'] for x in b['children'])))"

    PARENT 345 Counter({'done': 189, 'open': 120, 'cancelled': 35, 'considering': 1})
    SUCC   113 Counter({'open': 101, 'done': 6, 'cancelled': 6})
    INTERSECT 0

Destination is live and reachable: `cch-instruments-epic` status=`published`,
lifecycle=`open`, `parent_id=None`. INTERSECT 0 proves no row is double-counted,
i.e. `bp task move` re-parents rather than adding a second edge.

## 2. Exclusions actually applied

Wave 12's `cch-w12-s5-successor-split-and-letterbox-fence` criterion-4 evidence
carries the two lists verbatim. Parse them out of the ledger, do not retype:

    bp task get cch-w12-s5-successor-split-and-letterbox-fence -o json \
      | python3 -c "import json,sys;e=json.load(sys.stdin)['doc']['content']['acceptance_criteria'][4]['evidence'];\
    print(e.split('MOVED (62):')[1].split('| KEPT (40):')[0]);print('---');print(e.split('| KEPT (40):')[1].split('| DEVIATIONS')[0])"

* MOVED (62) — all 62 verified ALREADY GONE from the parent roster
  (`open ∩ moved = []`, and INTERSECT 0 above). Exclusion is a no-op today but
  is retained so a future re-derivation cannot silently re-move them.
* KEPT (40) — 24 of the 40 are still open under the parent; all 24 excluded.
  The other 16 have since closed or been cancelled.

Pool after exclusions: **120 open − 24 still-open KEPT = 96 candidate rows.**

## 3. The classification rule (wave 12's, unchanged)

A row MOVES only if its BODY names a divergence between what an INSTRUMENT
claims and what it measures, is invisible to a person using the console, and
sits inside the instruments charter fence (CI gates/machinery,
`cloud/priv/static/__preview__/**`, `__css_check`/`cssom-parity`/`shoot.sh`,
test rigs and oracles, the ledger and its tooling, the epic-cycle method).
A row naming anything a person can see, click or be misled by STAYS, and a row
that is genuinely both STAYS.

Result: **57 MOVE / 39 KEEP.** Registration-class rows stay (charter fence puts
registration decisions explicitly OUT) — that is why
`cch-bl-floor-blind-to-readme-and-uncalled` is a KEEP despite being an
instrument row.

## 4. The executable list (57)

Run one per line; each is idempotent and ~0.7 s.

    bp task move <id> cch-instruments-epic --yes

cch-w12-bl-filing-law-parent-charter-half
cch-w13-rv-gate-must-run-css-check
cch-w15-bl-lega-cannot-refuse-removed-breakpoint
cch-w15-bl-render-leg-node22-job
cch-w15-bl-plan-catalog-no-fixture-seam
cch-w15-bl-target-reuse-ascending-order-pin
cch-w15-bl-publish-wall-rationale-length-opaque
cch-w15-bl-cuestuck-asks-horizontal-of-a-vertical-cue
cch-bl-w15-fleet-leg-scenario-axis-of-two
cch-w15-bl-detail-url-fixture-never-overflows
cch-w16-s7-citation-anchors-e11-widening
cch-w16-bl-tiers5-leg-runs-nowhere
cch-w16-bl-legb-drives-one-of-three-heights
cch-w16-bl-no-preview-plus-production-console-fixture
cch-w17-bl-e11-scan-set-app-css-and-shoot-sh
cch-w17-bl-overflow-guard-honours-one-defect-flag
cch-w17-bl-css-slice-gate-must-include-leg-a
cch-w18-bl-attention-fixture-string-not-production-dominant
cch-w18-bl-smoke-address-copy-assertion-matches-the-rail-row
task-d862cf7f8e1108c1
cch-w19-s1-guard-loses-in-ci
cch-w19-bl-harness-width-prose-four-sites
cch-w19-bl-baseline-one-integer-assertion
cch-w19-bl-w13-rail-pill-pooled-zero-check
cch-w19-bl-gr115-intermittent-ua-defaults
cch-w19-bl-css-check-has-no-main-guard
cch-w19-bl-stamp-merge-gated-flag-undocumented
cch-w19-bl-e14-shorthand-blind
cch-w19-bl-topbar-620-vertical-cost-unasserted
task-13f830a9c36314e0
cch-w21-bl-token-reveal-modal-oracle
cch-backlog-bpbase-envelope-incomplete
cch-w22-bl-chip-guard-blind-below-721
cch-w22-bl-url-remedy-candidates-never-priced
cch-w22-bl-attention-sibling-never-measured
task-696a2fcf95e9c4da
cch-w22-s1-residue-modal-oracle-uninvoked
cch-w23-bl-site-domains-cruel-family
cch-w23-bl-three-screens-zero-geometry-coverage
cch-w23-bl-site-meta-320-line-guard
cch-w23-bl-cruel-leg-blind-to-status-pill-detail
cch-w23-bl-cruel-identity-own-scenario
cch-w23-bl-real-hetzner-remediation-scenario
cch-w24-bl-phone-band-unreachable-by-the-width-sweep
cch-w24-bl-q3-fold-budget-is-a-shell-property-at-320
cch-w24-bl-console-harness-comment-lies-about-cell-flag
cch-bl-css-check-gate-body-not-importable
cch-w24-followup-no-leg-drives-a-hash-nav
cch-w24-bl-hash-only-nav-is-same-document
cch-w24-bl-guard-full-run-nav-flake
cch-w24-bl-nothing-pins-height-against-a-cruel-string
cch-w24-bl-detail-title-row-not-a-required-wrap-host
cch-w25-bl-new-theater-family-unswept
cch-w25-bl-detail-grid-instance-track-unmeasured
cch-w25-bl-d298-footer-value-pair-unobservable
cch-w26-bl-desktop-band-above-1280-unswept
cch-w26-bl-choice-picker-css-unproduced

Explicit HOLDS inside the pool, named so they read as decisions not misses:

* `cch-w22-s7-cruelty-ledger-effective-caps-and-classes` — instrument-class by
  body, but it is wave 27's own re-adjudication target (wish item 7). Moving it
  mid-adjudication relocates the thing being judged.
* `drafts.cch-w22-s2-site-row-name-and-host-bounded` — the ONLY non-published
  row in the pool (`status: draft`). Person-facing anyway, so it is a KEEP on
  content; flagged because moving a draft is a different write path.

## 5. Post-condition — SUCCESSOR-ROSTER COUNT, never the orphan delta

`bp task move` accepts a destination that was never published, so a falling
orphan count is NOT evidence the rows landed. Assert on the destination.

BEFORE the moves, pin the two integers:

    bp task get cch-instruments-epic -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print('SUCC_BEFORE',d['child_count'],len(d['children']))"
    # expected at derivation time: SUCC_BEFORE 113 113

AFTER the moves, with MOVE_IDS the 57 lines above in a file `move.txt`:

    python3 - <<'PY'
    import json,subprocess
    ids=[l.strip() for l in open('move.txt') if l.strip()]
    b=json.loads(subprocess.check_output(['bp','task','get','cch-instruments-epic','-o','json']))
    have={c['doc_id'] for c in b['children']}
    missing=[i for i in ids if i not in have]
    print('SUCC_AFTER',b['child_count'],len(b['children']))
    print('EXPECTED  ',113+len(ids))
    print('MISSING',len(missing),missing)
    PY

PASS requires ALL THREE: `SUCC_AFTER == 113 + 57 == 170`, `len(children) ==
child_count` (no truncation), and `MISSING 0 []`. A row that prints a `rev` and
does not appear here did not land — re-issue it singly and re-read, exactly as
wave 12 had to for six of its 62.

## 6. GitHub-mirror cost of N moves

`gr-bl-github-mirror-reparent-residue` names two residues. Priced against the
CURRENT rosters, one is inapplicable and the other self-heals:

* Cap threshold is 100 DISTINCT children —
  `api/lib/barkpark/plugins/github/relations.ex:53 @default_max_children 100`,
  applied at `:188 child_count_exceeded?/3 -> {:flatten, parent_doc_id}`.
* SOURCE parent has 345 children (>100), so its children are CAP-FLATTENED, not
  natively sub-issue-linked. Residue (1) "no remove verb, so the row hangs under
  BOTH parents natively" therefore does NOT apply to any of these 57 — there is
  no native link at the source to fail to remove.
* DESTINATION now has 113 children (>100) — unlike wave 12, when it had 62.
  `handle_flatten/5` (`mirror_job.ex:897`) stamps a new marker whenever
  `link.parent_marker != parent_id`, so each moved row should be re-stamped
  `parent_marker: cch-instruments-epic` and its issue body converge.
  DERIVED FROM CODE, NOT DRIVEN — treat as a prediction to verify on ONE row
  before claiming it for 57:

      gh issue view <n> --repo FRIKKern/barkpark --json labels,body
      # label goal:cch-instruments-epic converges in ~40s (wave 12 measured this)
      # body `Parent:` line is the claim under test

* WORST CASE if the prediction is wrong: 57 issue bodies name a stale parent
  while the `goal:<parent>` label — the half a person reads on the board — is
  correct. Bounded, cosmetic, already owned by
  `gr-bl-github-mirror-reparent-residue` (which itself lives under
  `cch-instruments-epic` since wave 12).

## 7. Arithmetic for the debrief (D306: two integers, stated separately)

    RE-PARENT COUNT: 57
    CLOSE COUNT:     <whatever this wave actually closes — a different number>

Parent open after the moves, if nothing else changes: 120 − 57 = **63**.
Orphans is `residue − gates − forwarded`; at 117 before, the move alone takes it
to about **60**, not to the ~50 the direction estimated. State the measured
number from a fresh seal run, quoting UTC stamp, tree sha, and resolved repo
root.
