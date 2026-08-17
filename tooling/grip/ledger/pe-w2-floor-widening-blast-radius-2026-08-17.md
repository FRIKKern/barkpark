# Re-derivation recipe — publish-floor outline holes: blast radius = ZERO (2026-08-17)

Verifier lane `floor-widening-blast`, Paper Excellence wave 2. Question: if the
`EpicQuality` publish floor's two outline arms (`outline_requires_one_h1`,
`outline_heading_level_jump`) were (A) widened from top-level `blocks` to the
whole-tree `walk_maps/1` and (B) taught to coerce string-typed heading levels,
how many papers would NEWLY 422 — and is the top-level-only scope pinned?

VERDICT: **0 newly-422** in the 33-paper published tagged cohort, **0 newly-422**
across all 776 published papers even if every one were tagged, and hole B is
purely *relieving* — it removes 6 existing false `outline_requires_one_h1`
verdicts. Not pinned: the committed suite cannot detect either change.

## Re-derive

    # 1. the cohort (the floor is tag-scoped to epic-cycle-wave-paper)
    T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    curl -s -H "Authorization: Bearer $T" \
      "https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=1000" -o all.json
    # 776 published papers, 132MB; 33 carry the tag; perspective=raw adds 2 tagged drafts

    # 2. the standalone probes (scratchpad copies; no repo edit — the variants are
    #    built by string-substituting add_outline_failures/2 and Code.compile_string)
    elixir probe.exs    # cohort verdicts, 4 variants: Base / WidenA / CoerceB / BothAB
    elixir probe2.exs   # MUTATION PROOF: 5 synthetic sentinels + the draft arm
    elixir probe3.exs   # forward blast radius: all 776 as if tagged, outline arms only
    elixir probe4.exs   # PIN CHECK: replay the committed suite's 10 content maps

    # 3. the suite as committed
    cd api && MIX_ENV=test mix test test/barkpark/content/papers/epic_quality_test.exs
    # => 10 tests, 0 failures

## The numbers

| measurement | value |
|---|---|
| published papers | 776 |
| published papers carrying `epic-cycle-wave-paper` | 33 |
| tagged drafts (perspective=raw) | 2, both already failing on other arms |
| cohort papers with container-nested headings | 17 / 33 (372 nested headings, all level 2/3, depth 1) |
| cohort papers with string-typed heading levels | 0 |
| NEWLY-422 under (A) widened scope | 0 / 33 cohort, 0 / 776 corpus |
| NEWLY-422 under (B) coerced levels | 0 / 33 cohort, 0 / 776 corpus |
| RELIEVED by (B) — false `outline_requires_one_h1` removed | 6 papers (all untagged today) |
| papers already failing the outline arms if tagged | 171 / 776 |
| corpus string-numeric top-level levels | `'1'`×9, `'2'`×109, `'3'`×102; plus 175 absent and ~24 non-numeric |

The green is NOT vacuous: 372 nested headings are actually present and walked, and
the mutation sentinels prove each variant fires on its own hole and only its own —
`M1` nested h4 under a section → `outline_heading_level_jump` in WidenA only;
`M3` top-level `"level": "4"` → `outline_heading_level_jump` in CoerceB only.

## The inversion Decide needs

`Render.Compose`/`Walk` `heading_level/1` (compose.ex:1792-1796, walk.ex:414)
coerce `"1"|"2"|"3"` and default everything else to 2. So a paper written with
`"level": "1"` **renders as an h1** while the floor reports
`opening_missing_h1` + `outline_requires_one_h1`. The string-level hole is
therefore a FALSE-POSITIVE generator, not an escape hatch: coercion makes the
floor agree with the renderer and is a bug fix, not a ratchet. Note the opening
arm (`add_opening_failures`, `Map.get(&1,"level") == 1`) is strict too — coercing
only the outline arm leaves `opening_missing_h1` still firing, so a fix must
touch both arms or it is half a fix.

## Pin check

Not pinned. `api/test/barkpark/content/papers/epic_quality_test.exs` never plants
a container-nested heading nor a string level; `probe4.exs` replays all 10 of its
content maps and Base vs widened+coerced agree on 10/10 — the suite is blind to
both changes. Contrast `top_level_heading_overload`, which IS deliberately
top-level: named that way and pinned by
`bulldocs_ingest_wall_test.exs` ("17 top-level headings"). The whole-tree
intent is also stated for the spacer walk (`nested_keys/0` @doc; the
spacing-advisory test's moduledoc says "the tagged HARD gate walks the whole
tree"), which the outline arms do not honor — a defect, not a decision.
