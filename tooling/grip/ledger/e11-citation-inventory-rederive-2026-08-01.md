# E11 citation inventory — re-derivation recipe (cch-w16-s7)

Derived on `origin/main` @ `b266a1a5e` (2026-08-01). Never inherit these numbers; re-run.

## 0. Pristine bytes (never the worktree)

    D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $D
    cd $D && node cloud/priv/static/__css_check.mjs > /tmp/csscheck.out 2>/tmp/csscheck.err; echo rc=$?
    grep -c E11 /tmp/csscheck.out /tmp/csscheck.err     # capture to FILES — a pipe truncates (D201)

Measured: `rc=0`, 120 stdout lines, 0 stderr lines, `E11` count 0/0.
The SHIPPED un-widened E11 is CLEAN on today's main.

## 1. Counts through each regex, over the DERIVED scan set

`citationScanFiles()` = `readdirSync(dir)` filtered `/\.m?js$/` + `__preview__/*` same filter.
14 files today.

| regex | count |
|---|---|
| SHIPPED `/\bapp\.js[:~ ]+~?\d{2,}(?:-\d{2,})?/g` | 0 |
| D201 RULED `/\b(?:app\.js[:~ ]+~?\|(?:app\.css\|[\w.-]+\.(?:js\|mjs\|sh))(?::~?\|\s~))\d{2,}(?:-\d{2,})?/g` | **19** |
| row's LOOSE separator `[:~ ]+` for every branch | 20 (adds FP `app.css: 620`) |

Script: `scratchpad/scanset.mjs <dir>` (see this run's transcript; 20 lines of node).

## 2. Growth is live

    for sha in $(git log --format=%H -n 12 origin/main -- cloud/priv/static/__preview__); do ...

18 for eleven consecutive commits, **19** at `626466a0c` (#8851). The net-new citation is
`__preview__/breakpoint-sweep.test.mjs:493  "app.css:2131"`. Any inherited count is stale
within one merge.

## 3. False-positive fuzz — RULED vs LOOSE over ALL text files

RULED = 27 hits, every one a genuine citation, ZERO false positives.
LOOSE = 38 hits; the 11 extra are `app.css: 620` (breakpoint-sweep.mjs:256) plus **TEN**
`app.css <bytes> B` size records in `cssom-heads.baseline` (49,115,128,149,172,189,196,
212,228,252). D201 says NINE — it is ten today.

## 4. Scan-set blind spots (three, not two)

`app.css` (2 self-cites + 1 bare range), `shoot.sh` (3 mock.js cites), **and
`cssom-heads.baseline`** (3 cites: `app.css:2913-2957`, `:1051`, `:1046`) — the last is
not named by `cch-w17-bl-e11-scan-set-app-css-and-shoot-sh`.
