# pe-w2 · guerrilla live-writes verification — re-derivation recipes (2026-08-17)

Verifier lane `guerrilla-live-writes`, Paper Excellence wave 2. Every row is a
literal command that re-derives the fact from the RUNNING server (L1) or from
`origin/main` (L2). Scratch papers `pe-w2-verify-scratch-1/-2` were created,
read back, and DELETED inside this run (both confirmed 404) — do not expect
them to exist.

    BASE=$(bp capabilities -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['base_url'])")
    # → https://guerrilla.barkpark.cloud

## A · the #11616 inline-leaf normalizer IS live on guerrilla

Write a `{"type":"text","text":…}` leaf, read the STORED doc back:

    cat > /tmp/m.json <<'EOF'
    {"mutations":[{"createOrReplace":{"_id":"pe-w2-verify-scratch-1","_type":"paper",
      "title":"PE W2 verify scratch 1","style":"article",
      "description":"<non-trivial, >1 sentence — the publish wall's label spine>",
      "tags":[{"tag":"authoring-excellence","strength":80,"rationale":"…"},
              {"tag":"wave-paper","strength":40,"rationale":"…"}],
      "blocks":[{"id":"a","type":"heading","level":1,"text":"…"},
                {"id":"b","type":"paragraph","content":[{"type":"text","text":"SENTINEL"}]}]}},
     {"publish":{"id":"pe-w2-verify-scratch-1","type":"paper"}}]}
    EOF
    bp doc mutate --file /tmp/m.json --yes -o json
    bp doc get paper pe-w2-verify-scratch-1 -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["blocks"])'
    # stored leaf comes back {"type":"text","value":"SENTINEL"} → normalizer runs in prod

Nested containers normalize too (`children` and `blocks` keys both).

Write-path gotchas that cost three round trips (authoring-door lane):

| symptom | cause | fix |
|---|---|---|
| `{"code":"malformed"}` + a Content-Type hint | `publish` op missing `type` | `{"publish":{"id":…,"type":"paper"}}` (mutations.ex:203 matches BOTH keys) |
| `{"code":"label_spine"}` on `strength` | tag key is `strength` (1-100, distinct), not `weight` | `[{tag,strength,rationale}]` |
| `{"code":"unknown_tag"}` | tags must be registered `type:tag` docs | use `details.suggestions` |
| `{"code":"duplicate_of","similarity":1.0}` | title-token dedup wall | give a distinct title |

A failed op rolls the WHOLE batch back — `bp doc get` returns `not_found`.

## B · unknown container blocks publish 200 and the reader silently drops their children

    # blocks: {"type":"mysteryzone","children":[<paragraph with SENTINELCHILDPROSEBETA>]}
    #         {"type":"unknownwrap","blocks":[<paragraph with SENTINELCHILDPROSEEPSILON>]}
    curl -s $BASE/papers/pe-w2-verify-scratch-2 > /tmp/s2.html
    grep -c SENTINELCHILDPROSEBETA /tmp/s2.html      # → 0
    grep -c 'Unsupported block: mysteryzone' /tmp/s2.html  # → 1

Publish floor accepts them; reader emits `<div class="bp-unknown-block">Unsupported
block: mysteryzone</div>` in place of the whole subtree. Same for a string-typed
`level:"2"` heading nested in a `section` (publishes, renders `<h2>`).

`section` renders as an UNCLASSED div — the device-7 class hook is genuinely absent:

    <div style="display:flex;flex-direction:column"><hr class="bp-hr" …><p>…</p><hr class="bp-hr" …></div>

## C · ~100 published papers return 422 to the public reader TODAY

    bp doc query paper --limit 1000 --fields _id,body_html_sv,blocks -o json > /tmp/blk.json
    bp doc query paper --limit 1000 --fields _id,body_html_sv,body_html -o json > /tmp/bh.json
    while read -r p; do echo "$(curl -s -o /dev/null -w '%{http_code}' $BASE/papers/$p) $p"; done < ids.txt

Two disjoint populations (776 published papers total):

1. **41 blockless wave Papers → 41/41 = 422.** No `blocks`, no `body_html`,
   only a legacy `body` doc. ALL from 2026-08-06 → 2026-08-10, ALL from two
   epics (`deploy-reliability-wave-5..34`, `cloud-console-hardening|cch-wave-34..56`).
   Path: `Papers.reader_source/3` → `{:error, :semantic_empty}` → `InvalidSource`
   (`bulldocs_live.ex:60`, `plug_status: 422`).
2. **59 of 119 integer-stamped papers = 422.** `content["body_html_sv"] == 3`
   (an INTEGER — the pre-#? stamp, `@body_html_render_version 1` at `baee1b7cbc`).
   `Papers.cache_provenance/4` (papers.ex:215) guards `sv when is_binary(sv)`,
   so an integer stamp falls to the legacy `_ -> :divergent` fail-closed arm →
   `{:error, :ambiguous_source}` → 422. A hex-stamped byte-mismatch instead
   takes `{:stale, rendered}` and is SERVED — measured: 0/39 422 in the
   old-hex bucket, 0/39 in the current-stamp bucket.

Bucket census (`--fields _id,body_html_sv`, count the values):

    109 current hex (a0d3e8bd…) · 432 older hex · 119 integer 3 · 116 absent

**Blast-radius law for this wave:** the 60 int-3 papers that still serve 200 do
so only because `rendered == html` short-circuits `:coherent` BEFORE the stamp
is read — proven by re-querying after visiting all 119: zero restamped.
Any renderer change that touches their block types flips them to 422. So every
layout-device commit widens the 422 population unless the integer-stamp guard
is fixed first (one guard) and/or `mix barkpark.rehydrate_body_html` is run.

### C.1 · the two provenance guards DISAGREE on the integer-stamp population

    git show origin/main:api/lib/barkpark/content/papers.ex | sed -n '215,223p'
    #   sv when is_binary(sv) and sv != "" -> …            # integer 3 MISSES this
    #   _ -> :divergent                                    # → 422
    git show origin/main:api/lib/mix/tasks/barkpark.rehydrate_body_html.ex | sed -n '330,346p'
    #   is_nil(sv) and cached != body_html -> {:divergent, …}   # integer 3 is NOT nil
    #   true -> rewrite                                          # → WOULD repair the row

Reader = `is_binary`, rehydrator = `is_nil`. So `mix barkpark.rehydrate_body_html`
already repairs all 59 dark papers with NO code change — the cheapest slice on
the board. Regression dated: both `f2404bcc70` (stamp integer 3 → sha256 hex)
and `49b629fef0` (the `is_binary` guard) landed 2026-07-20, and no backfill ran,
so 59 papers have been 422 for ~4 weeks. Prior art: tasks
`pt-w1-reader-provenance-classification`, `pt-w1-write-side-stamp-honesty`
(paper `production-truth-wave-2026-07-20`) — that wave's own acceptance evidence
quotes "current version = 3", i.e. it was written BEFORE the stamp changed type.

## D · perfect-plan-research-wave-2026-07-12's 2026-08-15 write

Not a content write and not metadata: a READER-TRIGGERED derived-cache refresh.

    bp doc history paper perfect-plan-research-wave-2026-07-12 -o json   # newest revision = 2026-08-03T12:40:47
    bp doc revision 2ab190c4-9873-444a-a757-cf22430e6821 -o json         # that revision's content
    bp doc get paper perfect-plan-research-wave-2026-07-12 -o json       # _updatedAt 2026-08-15T05:27:56

`blocks` byte-identical (63 blocks, sha256[:16] `8236b77d4e493aec` both sides);
`body_html` re-rendered (+622 bytes: `bp-section-divider` classes appear,
`figure` gains `--bp-evidence-width`/`--bp-evidence-pull`); `body_html_sv`
55c67e77… → a0d3e8bd…; **no revision row written**. That is exactly
`Papers.refresh_html_cache/3` on the `{:stale, rendered}` arm.
