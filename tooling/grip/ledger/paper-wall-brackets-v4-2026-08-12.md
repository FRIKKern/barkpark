# Re-derivation recipes — v4 wall brackets (paper-excellence wave, 2026-08-12)

Target: guerrilla.barkpark.cloud (L1, deployed). All probes published throwaway papers
under the `v4-*` slug prefix — see CLEANUP at the bottom.

## R1 — the "~63KB render budget" is not a byte ceiling

    # 62,405 and 63,740 bytes both answer 200; so does 252,360 bytes
    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST \
      https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      --data @v4-wall-big.json      # 63,740 bytes -> HTTP 200

Payloads are untagged (no `epic-cycle-wave-paper`), style `article`, each carrying a
`description` >= 20 chars and 2 weighted tags with rationales >= 20 chars — without
those the label spine refuses first and the size question is never reached.

## R2 — the real boundary is a WORD cap, 5,000 first-pass words

    bp bulldocs publish v4-words-4999 --file v4-words-4999.json --yes   # rev: 1
    bp bulldocs publish v4-words-5001 --file v4-words-5001.json --yes   # 422 primary_reading_load_exceeded

Both payloads are ~33.5KB — half the folklore's byte figure. The cap:

    git show origin/main:api/lib/barkpark/content/papers/epic_quality.ex | sed -n '20,22p'
    #   @max_primary_words 5_000
    #   @max_top_level_blocks 80
    #   @max_top_level_headings 16

It is TAG-SCOPED (`canonical?/1`, epic_quality.ex:105-115): only papers carrying
`epic-cycle-wave-paper` are gated at all.

## R3 — the 17-heading refusal is a 422 carrying details.failures on the wire

    curl -s -w '\nHTTP_STATUS=%{http_code}\n' -X POST \
      https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      --data @v4-epic-17.json
    # HTTP_STATUS=422, details.failures = ["top_level_heading_overload"]

    bp bulldocs publish v4-epic-17-headings --file v4-epic-17.json --yes   # exit 1, prints the failures

CLI rendering is generic, not per-command: internal/cli/errors.go:367 `detailLines`
sorts and prints every `details` key.

## R4 — spacing_norm counts TOP-LEVEL blocks only

    bp bulldocs publish v4-spacing-zero  --file v4-spacing-zero.json  --yes  # rev: 1, no warning
    bp bulldocs publish v4-spacing-three --file v4-spacing-three.json --yes  # warning[spacing_norm]: ... 3 empty paragraph block(s)
    bp bulldocs publish v4-nested-untagged --file v4-nested-untagged.json --yes  # spacer nested in an expandable -> NO warning
    bp bulldocs publish v4-nested-tagged   --file v4-nested-tagged.json   --yes  # same shape, tagged -> 422 empty_paragraph_spacer

Counter: api/lib/barkpark/content/authoring_wall.ex:299-303 (`Enum.count` over
`content["blocks"]`, no descent). Hard gate: epic_quality.ex:97 (`walk_maps`, descends).

## CLEANUP — throwaway papers left on guerrilla

    v4-wall-small  v4-wall-big  v4-bytes-250k  v4-words-4999
    v4-spacing-zero  v4-spacing-three  v4-nested-untagged

(`v4-epic-17-headings`, `v4-words-5001`, `v4-epic-one-spacer`, `v4-nested-tagged` were
refused and never persisted.) They are published `type:paper` rows in `production` and
will show in any corpus census until deleted.
