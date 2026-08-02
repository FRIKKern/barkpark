# PDS wave 39 — charter-ledger sweep: DECIDABLE, with a measured blind shape

Re-derivation recipes. Corpus sha: `origin/main` = `974d412ca` (`#9050` = `532b2c7c2` confirmed
ancestor). Every number below is reproduced by the command printed with it.

## 0. Pin the charter at origin/main (never the worktree copy)

    git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter.md   # 10478 lines

## 1. The same-line extractor (derived vocabulary, slug stripped before matching)

Vocabulary DERIVED from the charter, not transcribed: the wish's five (`CLOSED`, `paid`,
`dissolved`, `MOOT`, `stale-open`) plus the three the charter actually asserts with —
`done` (86 hits), `cancelled` (9), `lifecycle_status` (2). Case variants included.
The slug is stripped from the line BEFORE matching, so `pds-w29-s3-fake-fails-closed`
cannot match itself.

    python3 /tmp/extract2.py     # script body reproduced in §6

    CANDIDATE LINES 46
    FAIL-CLOSED EXCLUDED 4
    DISTINCT SLUGS CLAIMED 41
    MULTI-LINE UNPARSABLE RESIDUE 59

The 4 fail-CLOSED idiom exclusions, printed rather than dropped: charter lines
3273, 3296, 3641, 7807.

## 2. Resolve every claimed slug against live lifecycle_status

    while read s; do
      r=$(bp task get "$s" -o json 2>/dev/null \
          | python3 -c "import sys,json;print(json.load(sys.stdin)['doc']['lifecycle_status'])" 2>/dev/null)
      echo "${s}|${r:-NOT_A_TASK}"
    done < /tmp/slugs.txt

41 slugs resolved: 34 are live task rows, **7 are NOT tasks at all** — the lens's own
false-positive class, printed: `pds-ledger-census`, `pds-live-hetzner-placement-group`,
`pds-scratch-target`, `pds-tasks-stop-under-repor-3` (a branch-name fragment),
`pds-w14-fire-record`, `pds-w15-fire-record` (all `scripts/*.sh|.md` filenames), and
`pds-wave-27-2026-07-31` (a Paper slug).

## 3. THE TRUE DISAGREEMENT COUNT — 3 live + 1 stale-quote

| charter line | slug | charter asserts | live lifecycle | verdict |
|---|---|---|---|---|
| 3228 | `pds-w29-pay-lb` | "#8644 … all 16 non-destroy lb-family sites paid" | **open** (12/14, claim expired 2026-07-31) | DISAGREES — PR 8644 is MERGED 2026-07-31T20:49:30Z |
| 5849 | `pds-bl-spill-dir-path-drift` | "is paid" (PDS-D343) | **open** (0/4) | DISAGREES |
| 5850 | `pds-w20-crown-fire` | "is MOOT (it arms a crown sealed 12/12)" | **considering** (0/6) | DISAGREES — MOOT ⇒ cancelled |
| 9820 | `pds-w34-census-cas-shadow` | quotes `"lifecycle_status":"open"` | **done** | STALE QUOTE — charter lines 2628/2681 already say `done`; the charter disagrees with itself, the ledger is right |

Everything else in the 46 either AGREES or is not a disposition assertion (statistics
rows `L5113`, `L6592`; dependency columns `L7827`; negative assertions `L3738`, `L7901`;
`L6408` where `done` attaches to `<done row>`, not to the slug).

## 4. THE BLIND SHAPE — the same-line lens sees under half the surface

    # slugs reachable ONLY via a residue line (disposition word ±2 lines from a slug,
    # never on the same line):
    RESIDUE LINES 59
    SLUGS REACHABLE ONLY VIA RESIDUE (not in the 41): 54

41 same-line vs 54 residue-only = the same-line lens covers **43%** of slug-adjacent
disposition prose. Of the 54, **23 are live non-terminal** (`open`/`considering`) —
each an unexamined disagreement candidate.

Second blind shape, the vocabulary itself:

    SAME-LINE claims the 8-word vocabulary MISSES (extra idioms only): 21 lines / 17 slugs

`REFUTED`, `parked`, `RE-SCOPED`, `superseded`, `deferred`, `retired`, `absorbed` are all
charter disposition idioms outside the derived 8. Worked example: charter:5851 says
`pds-bl-bp-search-false-negative`'s premise is REFUTED; live lifecycle is `considering`.

**VERDICT: the row is TAKEABLE, not proven-undecidable — but a builder must not claim
"the charter is swept."** The honest claim is: the same-line, 8-word slice of the charter
is FULLY adjudicated (46/46 lines by hand), with the residue and the vocabulary gap
PRINTED WITH THEIR COUNTS.

## 5. THE D538 RECONCILIATION — reconcilable, EXACTLY, and D539 is the one that does not reproduce

    elixir scripts/pds-elixir-receipt-census.exs        # CENSUS OK, 11.28 s wall (host load unknown)

Instrumented copy (`/tmp/c2.exs`: one `IO.puts(:stderr, …)` inside `report_routed_population/4`,
splitting the population by `@routed_live_method`):

    D538RECON verb_quads=212 verb_module_action=170 verb_modules=46 \
              live=40 live_mods=26 all_quads=252 all_pairs=196 routes_all=469

| PDS-D538 says | instrument at 974d412ca | |
|---|---|---|
| "212 write entries" | write-verb quads = **212** | EXACT |
| "**170** distinct write `{plug, plug_opts}` pairs" | write-verb `{module, action}` = **170** | EXACT |
| — | 252 = 212 write-verb + **40 LiveView mounts** | the delta is a population D538 never considered |
| — | 196 = 170 write-verb pairs + **26 LiveView mount modules** | EXACT |

**D538's headline is TRUE and fully reconcilable with 252/196.** 252 and 196 are D538's
170/212 with the LiveView mount population added — a widening, not a contradiction. The
charter is NOT accusing itself.

**But its neighbour PDS-D539 is.** D539 (same decision block, same day, `fc1ca7ad0`) states
`{module,action}` "goes 168 → 168" and `{method,path,module,action}` "goes 204 → 205".
Neither base integer reproduces: the shipped instrument reads **170** and **212** on the same
corpus, and `git log --since=2026-08-01 -- api/lib/barkpark_web/router.ex api/lib/barkpark/plugins/`
is EMPTY, so no route churn explains 168 vs 170 or 204 vs 212.

D539's **conclusion**, however, reproduces exactly. Plant one synthetic write route onto an
already-disposed pair:

    cp -R api /tmp/plant/ && append to /tmp/plant/api/lib/barkpark_web/router.ex:
      scope "/pdsw39", BarkparkWeb do
        pipe_through([:api])
        post("/synthetic-plant", WebhookController, :create)
      end
    cd /tmp/plant && elixir /tmp/c2.exs 2>&1 >/dev/null | grep D538RECON

    D538RECON verb_quads=213 verb_module_action=170 ... all_quads=253 all_pairs=196

Quad key 212→213; pair key 170→**170**, STRUCTURALLY INVISIBLE. And the shipped arm fires
and NAMES the plant, at a real exit code:

    cd /tmp/plant && elixir census.exs; echo $?
    FAIL  ROUTED-POPULATION-COMPLETE 1 ROUTED-WRITE member(s) carry NO disposition …
          · UNDISPOSED ARRIVAL post /pdsw39/synthetic-plant -> BarkparkWeb.WebhookController.create
    CENSUS FAILED — an integrity check went red.
    REAL EXIT=1

## 6. extract2.py (the extractor, verbatim)

    import re, json
    lines = open('/tmp/charter.md').read().split('\n')
    SLUG = re.compile(r'\b(?:pds-[a-z0-9]+(?:-[a-z0-9]+)+|task-[0-9a-f]{16})\b')
    VOCAB = {'CLOSED':r'\bCLOSED\b','closed':r'\bclosed\b','paid':r'\bpaid\b',
     'dissolved':r'\bdissolved\b','MOOT':r'\bMOOT\b','moot':r'\bmoot\b',
     'stale-open':r'\bstale-open\b','done':r'\bdone\b','DONE':r'\bDONE\b',
     'cancelled':r'\bcancelled\b','CANCELLED':r'\bCANCELLED\b','lifecycle_status':r'lifecycle_status'}
    FAILCLOSED = re.compile(r'fail(?:s|ing|ed)?[-– ]?closed|closed[- ]fail|fail closed', re.I)
    # per line: slugs = SLUG.findall(l); stripped = SLUG.sub(' ', l)
    # candidate iff slugs and VOCAB hit in `stripped` and not FAILCLOSED(stripped)
    # residue iff VOCAB hit, no slug on the line, but a slug within lines [i-3, i+1]
