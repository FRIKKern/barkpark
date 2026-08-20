<!-- grip-ledger: re-derivation recipe | pe-w7 rig-binding-proof | 2026-08-17 -->

# Paper-excellence wave 7 — mechanical-floor rig-binding proof

The rubric's mechanical floor is RUNNABLE on this host as three commands.
Proven 2026-08-17 on origin/main @ c37a292447. node v22.22.0, Playwright at
`js/node_modules/node_modules/playwright/index.mjs` (present), mix/elixir via
homebrew. No `timeout` binary on macOS — do not wrap these in `timeout`.

## 1. census.mjs URL mode against the LIVE guide slug

The deployed reader's section-head legs are matched by this exact `--structural`
selector (identical to shoot.mjs:146 STRUCTURAL_RULE_SELECTOR); root is
`main.bp-paper-article`.

    node tooling/paper-excellence/rig/census.mjs \
      'https://guerrilla.barkpark.cloud/papers/paper-authoring-excellence' \
      --root 'main.bp-paper-article' \
      --structural '.bp-paper-surface > #paper-body > h2, .bp-paper-surface > #paper-body > div:not([class]) > h2' \
      --json

Reported for the live guide (2026-08-17, rev cf91fcffedc492350):
total 35, heavy 8, structuralHeavy 8, strayHeavy 0, byWeight {1:27, 2:8}.
A clean paper — every heavy (2px) rule attributes to an h2 section head.
Default width when `--width` omitted is 1280; scheme light.

## 2. gate.sh against a committed fixture (hermetic)

    bash tooling/paper-excellence/rig/gate.sh
    # default fixture = fixtures/heggemsnes-act.json

PASS. mix render (--no-start, MIX_ENV=test, CC=clang) + shoot.mjs chain completes
locally. First run recompiles ~823 files; warm after. Output per cell:
column 660px, 5 sized section beats at 92px over a 2px rule, 14 rules (5 heavy
all structural), prose 67.7 CPL, doc overflow 0px. 8 shots (4 widths x 2 schemes).

## 3. live-payload -> fixture -> gate.sh (the CPL/breakout chain on a live slug)

CPL and breakout-width live in shoot.mjs behind gate.sh's hermetic fixture, NOT
in census.mjs. To bind them to a LIVE slug, materialise a scratch fixture from
the live payload (reusing fetch-fixtures.sh's transform, into a NON-committed
dir) and gate that. Exact working sequence:

    FIX=/path/to/scratch/live-fixtures ; mkdir -p "$FIX"
    bp doc get paper paper-authoring-excellence -o json | FIXTURE_DIR="$FIX" python3 -c '
    import sys, json, os
    d = json.load(sys.stdin)
    if not d.get("blocks"): sys.exit("no blocks")
    out = {"_id": d["_id"], "title": d["title"], "style": d.get("style"),
           "source_rev": d["_rev"], "blocks": d["blocks"]}
    open(os.path.join(os.environ["FIXTURE_DIR"], d["_id"]+".json"),"w").write(
        json.dumps(out, indent=2, ensure_ascii=False, sort_keys=True)+"\n")'
    SHOT_WIDTHS="1920,1280,768" bash tooling/paper-excellence/rig/gate.sh "$FIX/paper-authoring-excellence.json"

PASS with SHOT_WIDTHS="1920,1280,768": column 660px, CPL 71.7, doc overflow 0px,
band 1240/1040/688 (3 components), 35 rules (8 heavy all structural).

Cross-check: census URL mode (35/8/8/0) and gate render of the fixture (35 rules,
8 heavy all structural) agree EXACTLY — the two instruments bind to the same paper.

## The 360px trap the rubric must know about

The DEFAULT gate.sh runs 4 widths (1920,1280,768,360). On the live guide fixture
the 360 cell FAILS:

    FAIL — paper-authoring-excellence__light__360: the document scrolls sideways
    by 31px (scrollWidth 391 vs clientWidth 360); allowance is 4px

MAX_DOC_OVERFLOW_PX=4 (shoot.mjs:80). The guide itself has a >4px mobile
unbreakable-token overflow at 360 — the SERVER-published exemplar does not pass
the rig's own 360 assertion. So the rubric's mechanical floor must EITHER pin
`SHOT_WIDTHS="1920,1280,768"` (the width-law widths — column + breakout band, all
clean) OR treat a 360 overflow as advisory. Pinning bare `gate.sh` full-green as
the floor would fail the very exemplar the cold agent learns from.
