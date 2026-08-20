# PDS w49 — the wave Paper's publish refusal: re-derivation recipes

Verifier assignment `wave-paper-write-path`, 2026-08-05. Every row below is a command
that re-derives the fact from scratch. Host: darwin, cpus=10.

## R1 — the refusal DOES name its block paths (the CLI drops them)

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    curl -s -X POST "https://guerrilla.barkpark.cloud/v1/data/mutate/production" \
      -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
      -d '{"mutations":[{"publish":{"id":"<paper-id>","type":"paper"}}]}' | python3 -m json.tool

Server returns `error.details.blocks` with one exact path per offending cell
(`blocks[30].rows[0].cells[0] has no renderable inline content`, …).
`bp doc publish paper <id> -o json` prints the SAME request's error with
`code/message/hint/request_id` and no `details`.

## R2 — why: the installed bp is a frozen replica that predates the fix

    bp --version                                  # commit f59aaf717, build 2026-07-31T06:54:48Z
    git show f59aaf717:internal/cli/errors.go | grep -ci details    # 0
    git show origin/main:internal/cli/errors.go | grep -ci details  # 20
    git log origin/main --diff-filter=A --format='%H %cI %s' -- internal/cli/errors_details_test.go
    # ae0f917bb 2026-08-01T07:49:25+02:00 fix(cli): stop discarding the server's error `details` payload (#8809)
    git rev-list --count f59aaf717..origin/main -- internal/cli    # 23

## R3 — the publish gate is scoped by KEY NAME, not by what readers render

    git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '100,120p'

`prepare_paper_render_shapes` matches only `%Document{content: %{"blocks" => blocks}}`.
A paper whose blocks live at `content.body.blocks` (what `bp doc patch --set body:=…`
writes) falls through to `defp prepare_paper_render_shapes(draft, _type), do: {:ok, draft}`
— UNGATED. Proof both states existed on one document:

    bp doc revision 2cfd3800-666d-4628-a75f-d4efba00c769 -o json \
      | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)['revision']['content'].keys()))"
    # ['body','body_html','body_html_sv','description','main_tag','style','tags']  -> no top-level blocks, publish SUCCEEDED
    bp doc revision c654f33c-62e2-4d30-aed5-ff2c2340b86e -o json \
      | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)['revision']['content'].keys()))"
    # ['blocks','body',…]  -> top-level blocks present, publish REFUSED on identical table blocks

## R4 — the refused cells render fine in the live reader

    curl -s https://guerrilla.barkpark.cloud/papers/pds-wave-49-2026-08-05 -o /tmp/r.html
    python3 - <<'EOF'
    import re; h=open('/tmp/r.html').read()
    c=re.findall(r'<td class="bp-table__td">(.*?)</td>', h, re.S)
    print(len(c), len([x for x in c if x.strip()]))
    EOF
    # 78 78  — every string cell the gate condemned as unrenderable is rendered

## R5 — the normalizer has no bare-string clause

    git show origin/main:api/lib/barkpark/content/papers/block_ops.ex | sed -n '2079,2087p'

`normalize_wrapped_table_cell` canonicalizes `%{"content" => [...]}` and
`%{"text" => "..."}` and falls through on a bare binary. Same hole for list items
(`normalize_wrapped_list_item`). So the plainest authoring shape is neither
repaired nor named to the author.

## R6 — the repair actually applied (offline validate, then publish)

Port of `BlockOps.validate_render_shapes/1` to python, run over the block list
BEFORE patching; then patch both `body` and top-level `blocks`, then publish:

    bp doc patch paper pds-wave-49-2026-08-05 --set "body:=$(cat body.json)" --set "blocks:=$(cat blocks.json)"
    bp doc publish paper pds-wave-49-2026-08-05 -o json
    bp doc get paper pds-wave-49-2026-08-05 -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d['document']['body']['blocks']))"
    # 82

## R7 — this checkout is itself frozen

    git rev-list --count HEAD..origin/main   # 451
    git log -1 --format=%cI HEAD            # 2026-07-29T12:16:00+02:00

Any worktree file:line quoted this wave is a claim about a 451-commit-stale replica,
not about main. Use `git show origin/main:<path>`.

## Prior art

`task-9b3778f52ca05984` (lifecycle_status **open**, priority 1, parent
`cch-instruments-epic`, updated 2026-07-31) filed exactly this. Its fix candidate
"make the error enumerate the offending block ids, as its hint already claims it does"
is REFUTED by R1+R2: the server already enumerates them; the operator's binary
discarded them.
