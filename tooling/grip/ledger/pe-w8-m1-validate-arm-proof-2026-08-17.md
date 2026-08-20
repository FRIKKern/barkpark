<!-- doc-tier: cold | canonical-for: pe-w8-m1-validate-arm-proof | budget: 800tok -->

# M1 validate-arm proof (Paper Excellence wave 8)

Re-derivation recipes for the M1 pin: the authenticated validate arm's response
shape for (a) an unregistered tag and (b) a bare-string inline leaf. Publishes
nothing — validate is a dry-run, always HTTP 200.

## Setup

    TOK=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))["token"])')
    URL=https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers/validate

## (a) Unknown tag → HTTP 200 valid:false, code "unknown_tag" (NOT a 422 dry-run)

Tags must be weighted objects `{tag, strength, rationale}`; a bare-string tag
trips `label_spine` first. With a proper weighted object carrying an
unregistered tag name:

    curl -s -w '\nHTTP %{http_code}\n' -X POST "$URL" \
      -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
      -d '{"slug":"m1-probe-scratch-unknown-tag","title":"M1 Probe Scratch","description":"A scratch paper used only to probe the validate arm; nothing is persisted here at all.","tags":[{"tag":"zzz-definitely-not-a-registered-tag-9999","strength":50,"rationale":"deliberately unregistered tag to probe the tag-registry gate"}],"blocks":[{"id":"b0","type":"heading","level":1,"role":"title","text":"M1 Probe Scratch"},{"id":"b1","type":"paragraph","content":[{"type":"text","text":"Real body prose so the paper is not hollow and clears the content floor."}]}]}'

Result: `{"valid":false,"violations":[{"code":"unknown_tag", ... }]}` + `HTTP 200`.

## (b) Bare-string leaf in list items + table cells → HTTP 200 valid:true (EVADES)

    curl -s -w '\nHTTP %{http_code}\n' -X POST "$URL" \
      -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
      -d '{"slug":"m1-probe-scratch-bare-leaf","title":"M1 Probe Bare Leaf","description":"A scratch paper used only to probe whether the validate arm flags bare-string inline leaves in list items and table cells.","tags":[{"tag":"research-note","strength":60,"rationale":"registered tag so only the bare-string structural class can trip a violation"}],"blocks":[{"id":"b0","type":"heading","level":1,"role":"title","text":"M1 Probe Bare Leaf"},{"id":"b1","type":"paragraph","content":[{"type":"text","text":"Some real prose so hollow does not fire."}]},{"id":"b2","type":"list","style":"bullet","items":["a bare string leaf","another bare string"]},{"id":"b3","type":"table","rows":[{"cells":["bare cell one","bare cell two"]}]}]}'

Result: `{"valid":true,"violations":[]}` + `HTTP 200`. The bare-string leaf class
passes every pre-publish gate — the defect is render-time only.

## Anchor

Handler: api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex:119
`def validate/2` — docstring line 115: "Always 200 with {valid, violations}".
Gates run: AuthoringWall.validate_all/5 (label spine, tag registry, dedup, epic
quality) + Papers.Template.validate + Papers.Hollow.hollow?. None inspect
inline-leaf shape inside list items / table cells.
