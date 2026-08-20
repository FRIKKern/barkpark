<!-- doc-tier: cold | canonical-for: pe-w6-corpus-census-recheck re-derivation | budget: 900tok -->

# Corpus census recheck — the REAL printer on the BEAM (pe wave 6, 2026-08-17)

Charter D45. The live slot serves sha `0ff6fae` which does NOT contain #11814
(`git merge-base --is-ancestor 23b08c1211 0ff6fae4a6` → rc=1, proven) — so a
live recheck quotes the WRONG (pre-#11814) printer and undercounts. This row
instead runs the REAL origin/main printer over the fetched corpus. **Live
provenance is deferred to `pe-bl-live-census-post-deploy`** — after the next
successful guerrilla deploy lands a sha that contains #11814, re-run this against
the live server and stamp the provenance.

Run worktree HEAD: `94b12757a0` (contains #11814: `23b08c1211` is-ancestor → rc=0).
This run PREDATES `pe-w6-notes-kernel-tier`'s merge: the origin/main printer has
16 block clauses (eyebrow heading paragraph pullquote ingress byline callout list
code diagram stats steps table section divider expandable) and NO `notes`/`note`
clause — so `notes` still refuses. The notes rows below are a reconciliation
simulation, not the shipped kernel.

## 1. Denominator (pinned at fetch time, D37 — it moves daily)

`result.count` = **781** published papers (type `paper`, 2026-08-17). Never
compare across fetches. Fetch split of the 781 on `/source?format=json`:

| fetch outcome | n |
|---|---|
| 200, source.kind = `blocks` (printer runs over these) | 705 |
| 200, source.kind = `html` (bpml route → 422 `bpml_unavailable`, not printed) | 31 |
| 422 on json route (no printable blocks source — semantic_empty/ambiguous) | 45 |
| **raw 500 on json fetch route** | **0 this run** |
| total | 781 |

**Denominator caveat.** The prior wave-6 freeze run
(`pe-w6-notes-grammar-freeze-dossier-2026-08-17.md`) saw 30 JSON-route fetch
500s (`pds-wave-*` et al.) that never entered its denominator. THIS fetch got
0 — those 30 papers fetched clean and are counted here, which is the main driver
of the upward divergence in §3. That route defect is real and load-dependent;
it is backlogged as **`pe-bl-json-source-route-500s`** and is NOT claimed fixed.

## 2. The real-printer run (BEAM), and its bucket table

The instrument is `Barkpark.PortableDoc.Bpml.Printer.print_paper/1` — the exact
module the controller calls at `send_bpml/2`
(`bulldocs_source_controller.ex:101`). It was compiled and run on the BEAM,
byte-identical to the shipped source:

    shasum -a256 api/lib/barkpark/portable_doc/bpml/printer.ex
    # efe0687afedc290b5357ad8573e79769ae560afdc89d89656930d9a8be3d1d86  (== the file run)

The worktree has no `api/_build`/`api/deps` (build-borrow is broken; Elixir
1.19.5), so instead of `cd api && mix run` the run compiles the two real source
files (`printer.ex` verbatim + `unprintable_error.ex` with only its trailing
`defimpl Plug.Exception` stripped — irrelevant to printing; the census-bucketed
`build_message` wording is untouched) and drives them on the BEAM. This runs the
REAL Elixir printer, not a language twin (the freeze numbers came from a python
twin; D45 asks the builder to re-derive on the BEAM). Rescue semantics mirror the
controller exactly: success → 200, `UnprintableError` → typed 422, any other
raise → raw 500.

Outcomes over the **705** blocks-kind papers:

| class | n | meaning |
|---|---|---|
| **200 round-trip printable** | **432** | printer emitted BPML |
| **422 typed refuse** (`UnprintableError`) | **267** | block 214 · inline 36 · mark 16 · head_cell 1 |
| **500 raw crash** | **6** | see §4 — all `Protocol.UndefinedError`, the byline-map class |

No "0-in-500" headline: the residual raw-500 is **6**, not zero.

First-blocker frequency among the 267 typed 422s (the message names only the
FIRST offending shape per paper; D37 regexes `\(kind: (\w+)\)` and `type "(\w+)"`
parsed it, asserting a match): `block:notes` 68, `block:heading` 25 (string
`level`), `block:terminal` 18, typeless `block:` 18, `inline:paragraph` 16,
`block:toc` 13, `block:quote` 13, `block:cards` 13, `inline:valueref` 12,
`block:chart` 7, `block:image` 6, `block:columns` 6, `block:action` 6,
`block:note` 5, `inline:strong` 3, `block:pipeline` 3 …

**#11814 win, measured.** The wave-4 census
(`bpml-full-corpus-census-2026-08-17.md`) counted **141** raw 500s (unknown
inline node / non-list `inline/1` / bare head cell all escaping as
`FunctionClauseError`). Post-#11814 those are now TYPED 422s — the raw-500
residual collapsed 141 → **6**, and the 6 are a single unrelated class (§4).

## 3. Notes rows — measured on the BEAM, reconciled to the freeze

Measured by running the same real printer AUGMENTED with D40's frozen
`notes`/`note` grammar (`<note id label lead>esc(text)</note>`; string items
escape verbatim = lossless/heggemsnes-act; inline-node LIST items refuse; a
`note` block with a `content` key and no text/label/lead refuses honestly) and
counting the papers that flip. `notes-cumulative` is a block-truth walk.

| row | measured (this run, real printer, 705 papers) | freeze twin (687 papers) |
|---|---|---|
| kernel printable | 432 | 422 |
| **notes-marginal** (kernel:no → +notes:ok, D40 grammar) | **57** | +49 (str-escape) / +48 (str-refuse) / +51 (+singular note) |
| **notes-cumulative** (≥1 `notes` or `note` block) | **113** (106 grid · 10 singular note, union) | ~106 (100 grid · 9 note) |

**Reconciliation — every divergence is upward and explained:**
1. **Corpus grew + full fetch.** 705 blocks-kind papers here vs the freeze's 687
   — the freeze's 30 unfetchable JSON-500 papers (`pds-wave-*` et al.) are now
   in the denominator. **9 of the 57 marginal are `pds-wave-*`** and 5 more are
   `source-of-truth-grip-wave-*` — papers the freeze literally could not see.
2. **The python twin under-modeled the real printer** at the kernel base (422 vs
   the real 432, +10): the real post-#11814 printer prints strictly more.
   The BEAM number is the authority (D45).

The freeze's "+35" (pre-D24 backlog) and the live-measured "5" (a pre-#11814
slot) are both superseded — **57 marginal / 113 cumulative are the numbers of
record**, subject to a live re-derive once the deployed sha contains #11814.

## 4. Residual raw-500 class — byline map-items

All 6 raw 500s are `Protocol.UndefinedError`: the `byline` clause runs
`esc(&1)` → `to_string/1` on a MAP item `%{"value" => …}` (String.Chars
undefined for Map) — a covered clause crashing on generator-drift item shape,
NOT an uncovered block type. Canonical byline items are bare strings. Slugs:

    api-read-path-security-sweep-wave3-2026-08-17
    ctx-compression-handle-doctrine
    hobby-hardening-meter-free-lunch
    paper-excellence-wave-3-2026-08-17
    paper-excellence-wave-4-2026-08-17
    paper-excellence-wave-5-2026-08-17

Pre/post note: this run PREDATES any byline fail-honest fix and PREDATES
`pe-w6-notes-kernel-tier` — the notes tier does not touch the `byline` clause
(different block, D40 rides the coercion on the same printer PR), so this class
survives the notes merge until the byline coercion lands. Detail:
`pe-w6-byline-map-item-500-class-2026-08-17.md`.

## 5. Rerun commands

    S=/tmp/pecensus && mkdir -p $S/json
    TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
    # 1. pin the denominator + slug list
    curl -s -H "Authorization: Bearer $TOK" \
      "https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=3000&fields=_id" \
      | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r['count']);open('$S/slugs.txt','w').write('\n'.join(sorted(x['_id'] for x in r['documents']))+'\n')"
    # 2. fetch every source json (anonymous published-only)
    #    xargs -P16 curl "https://guerrilla.barkpark.cloud/papers/$slug/source?format=json" -o $S/json/$slug.json
    # 3. copy the REAL printer + strip only the Plug.Exception defimpl from the error module
    cp api/lib/barkpark/portable_doc/bpml/printer.ex $S/printer.ex
    awk '/^defimpl Plug.Exception/{exit}{print}' \
      api/lib/barkpark/portable_doc/bpml/unprintable_error.ex > $S/unprintable_error.ex
    # 4. run on the BEAM: Code.compile_file both, print_paper/1 per paper, bucket
    #    200 (ok) / 422 (UnprintableError, D37-regex the kind+type) / 500 (other raise)
    #    notes rows: re-run with the D40 notes/note clauses injected after the stats
    #    clause; marginal = flips kernel:no -> notes:ok, cumulative = block-truth walk.
    cd api && elixir $S/census_run.exs

Scripts of record live beside this run (scratchpad): `census_run.exs`,
`printer_notes.ex`, `census_notes.exs`.
