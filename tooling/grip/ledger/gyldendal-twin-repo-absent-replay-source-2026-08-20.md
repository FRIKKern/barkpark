# Gyldendal twin repo: ABSENT on this host — the replay has no transcribable source

Verifier lane `gyldendal-twin-repo`, wave `gyldendal-field-report-wave-2026-08-20`.
All commands below re-derive the claims from scratch.

## 1. The twin repo does not exist on this host

    ls -la ~/Documents/GitHub/gyldendal-agency-barkpark
    # ls: /Users/pelle/Documents/GitHub/gyldendal-agency-barkpark: No such file or directory

    cd ~ && find . -maxdepth 6 -type d \( -iname '*gyldendal*' -o -iname '*agency*' \) \
        -not -path '*/node_modules/*' -not -path '*/Library/*' 2>/dev/null
    # (no output)
    # positive control (proves the find is not vacuous):
    cd ~ && find . -maxdepth 6 -type d -iname '*barkpark-demo*' -not -path '*/Library/*' 2>/dev/null
    # ./Documents/github/barkpark-demo

    mdfind -name gyldendal | grep -v scratchpad | head
    # only tooling/grip/ledger/*.md inside this repo — no repo directory

    gh api repos/frikk-gyldendal/gyldendal-agency-barkpark   # 404
    gh api "search/repositories?q=gyldendal-agency-barkpark" --jq .total_count   # 0

TRAP: `timeout` and `gtimeout` do NOT exist on this host. `timeout N find ... 2>/dev/null`
silently produces NOTHING and exits 0 via the following `head`. Any earlier "no results"
from a `timeout`-prefixed search in this wave is VACUOUS. Re-run without it.

    which timeout gtimeout   # "timeout not found" / "gtimeout not found"

## 2. The parity verifier is a frontend harness, not a Barkpark oracle

`scripts/route-parity.mjs` lives in the twin repo and measures the twin app
(localhost:3102) against the production Vercel app — sitemap paths, <title>/<h1>/meta.
It never asserts anything about Barkpark's API. Re-derive from the paper:

    grep -o -E '"type": "code", "value": "[^"]*"' <gyl papers>/*.txt | sed 's/.*value": //' | sort -u

That command also yields the COMPLETE inventory of inline code spans across all seven
2026-08-20 Gyldendal papers — 30-odd tokens, no commands, no URLs, no request bodies.
The replay must be labelled a RE-DERIVATION.

## 3. The one literal repro anchor the papers DO carry (#34)

`2026-08-20-studio-gjennomgangen` quotes the observed Studio card verbatim:
"No <type> with the id <id> exists in this dataset" + "it may live in another
workspace or project".

    git grep -n "exists in this dataset" origin/main -- api/
    # api/lib/barkpark_web/components/studio_components/editor.ex:242
    git grep -n "another workspace or project" origin/main
    # api/lib/barkpark_web/components/studio_components/editor.ex:243

That card renders `reason == :not_found`, set at exactly one site:

    git grep -n "reason: :not_found" origin/main -- api/lib/barkpark_web/live
    # api/lib/barkpark_web/live/studio/studio_live/shared.ex:958

`empty_editor_state/2` derives its reason from PANE SHAPE only; its cond has no
`:forbidden` arm. NOTE the path: `live/studio/studio_live/shared.ex`, NOT
`live/studio/shared.ex` (that file does not exist on origin/main).

## 4. #2 settled: over-return and under-return are DIFFERENT SHAPES (live proof)

The charter's D3 (unsupported op -> unfiltered set) and Gyldendal's "0 rows" are BOTH
true, of different queries. Re-derive against a live instance:

    B="https://guerrilla.barkpark.cloud/v1/data/query/production/paper"
    curl -s "$B?limit=1&filter%5Btitle%5D%5Bzzz%5D=x"        # 422 invalid_filter
    curl -s "$B?limit=1&filter%5Bauthor.name%5D%5Beq%5D=x"   # 200, "count":0
    curl -s "$B?limit=1&filter%5Bnosuchfield%5D%5Beq%5D=x"   # 200, "count":0
    curl -s "$B?limit=1"                                     # 200, "count":1

Mechanism, both arms on origin/main:

    git show origin/main:api/lib/barkpark/content/query.ex | sed -n '258,270p'   # "eq" arm
    git show origin/main:api/lib/barkpark/content/query.ex | sed -n '548p'
    # defp apply_field_op(query, _field, _op, _value), do: query

Unsupported OP hits the :548 catch-all (clause dropped, unfiltered) but is unreachable
over HTTP on the query route — the D75 controller guard 422s first. Unknown FIELD takes
a SUPPORTED op arm: a dotted name goes to `jsonb_extract_path_text(content, 'author',
'name') = $1`, a flat name to `content->>'nosuchfield' = $1`. Both address a jsonb path
that does not exist -> zero rows, 200 OK, no guard involved. Gyldendal's reported
symptom is the UNDER-return; strictness on the op alone cannot catch it.
