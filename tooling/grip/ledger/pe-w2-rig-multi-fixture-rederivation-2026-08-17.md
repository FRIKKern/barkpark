# Re-derivation: the paper-excellence rig, cold, on four fixtures (2026-08-17)

Verifier lane `rig-multi-fixture`, Paper Excellence wave 2. Everything below is
re-derivable on any checkout of `origin/main` with no server, no database, no
network. `OUT` is any writable temp dir — never the repo, because `gate.sh`
writes only where you point it (`baseline.sh` is the one that writes into the
repo, and it was NOT run here).

## 0. gotcha that costs the first run

`gate.sh` `cd`s into `api/` before rendering, so a REPO-RELATIVE fixture path
dies in `render.exs`:

    ** (File.Error) could not read file "tooling/paper-excellence/rig/fixtures/design-probe.json"

Pass the fixture as an ABSOLUTE path. (The `OUT_DIR` positional is resolved by
the shell, so it may be relative.)

## 1. the four-fixture loop (880 content assertions, all green)

    OUT=$(mktemp -d)
    R=/Volumes/SATECHI/github/barkpark/tooling/paper-excellence/rig   # your checkout
    for f in design-probe eight-minute-erasure hobby-hardening-capstone heggemsnes-act; do
      bash "$R/gate.sh" "$R/fixtures/$f.json" "$OUT/loop"; echo "$f=$?"
    done

Expected: `design-probe=0 eight-minute-erasure=0 hobby-hardening-capstone=0
heggemsnes-act=0`, with per-fixture assertion counts 96 / 256 / 360 / 168.

Known cosmetic lie: the `rig/gate: PASS — … N shots` tail counts EVERY file in
the shared `shots/` dir, so a loop reports 8, 16, 24, 32 rather than 8 each.
Use a fresh `OUT_DIR` per fixture if the count matters.

## 2. the L1 close-proof for the narrow-evidence duplicates

Tasks `task-154bd21555d57403` and `task-c2bc7eefa4f40d17` (both children of
`task-328fe6a7248277c0`) ask for exactly three things. Read them off the
design-probe report the gate just wrote:

    python3 -c "import json;d=json.load(open('$OUT/loop/shots/design-probe.report.json'));[print(s['cell'],s['bandRows']) for s in d['shots']]"

At `light__1280`: `bp-table` box 290.6px, `offCentre` 0, `inkWidth` 290.6,
`inkOffCentre` 0 (the task's defect number was ink 290.6 at **-374.7**), and
`bp-stats` beside it still 1040/0 ink 1040/0 — band-filling behaviour unchanged.

## 3. the assertion is live, not decorative (mutation, tmp only)

Revert the #11658 declaration in the RENDERED copy — never in the repo:

    cp "$OUT/loop/design-probe.html" "$OUT/mutant.html"
    #  .bp-table { … width: fit-content; …}  ->  width: var(--bp-evidence-width, 100%)
    node "$R/shoot.mjs" "$OUT/mutant.html" "$OUT/mutshots" mutant

Expected red:

    rig/shoot: FAIL — mutant__light__1920: bp-table has a 1240px box centred at 0px
    but only 290.6px of INK, sitting -474.7px off the column's centre axis

The declaration itself lives in THREE places on `origin/main`
(`git grep -n "width: fit-content" origin/main`):
`api/assets/paper-surface/paper-surface.css:531`,
`api/assets/paper-editor/src/styles.css:554`,
`api/lib/barkpark_web/layouts/root.html.heex:4635`. The two editor copies lack
the reader's `display: block; overflow-x: auto` — that is the open
table-scroll-chrome gap, visible in the same grep.

## 4. baseline currency, measured not assumed

Re-shoot the gate's own rendered HTML under the baseline panel's env and diff
the NUMBERS against what is committed:

    SHOT_FORMAT=jpeg SHOT_QUALITY=72 SHOT_WIDTHS=1280,1920 \
      node "$R/shoot.mjs" "$OUT/loop/<slug>.html" "$OUT/bl-<slug>" "<slug>"
    diff "$OUT/bl-<slug>/<slug>.report.json" "$R/baselines/<slug>.report.json"

`design-probe` and `eight-minute-erasure` come back byte-identical.
`hobby-hardening-capstone` differs in ONE field — `light__1280` JPEG size
10120648 vs the committed 10276622 (1.5%); every measurement matches and
`light__1920` matches to the byte. JPEG bytes are encoder/host noise, which is
why the report's measurements are the oracle (README says as much).

## 5. the "@1x JPEG cap" premise is stale

The 1x demotion in `shoot.mjs:720` only exists under `SHOT_FORMAT=jpeg`, and it
never fires: `ls "$R/baselines" | grep -c '@1x'` → `0`, and the hobby capstone
(the largest fixture, 97 blocks) captures at **2x** in both formats — 10.8 MB
as q72 JPEG at 1920, ~18 MB as PNG. Nothing in the committed panel is @1x.
