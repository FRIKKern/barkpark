# PortableDoc block shapes (verified 2026-07-24 against live papers)

Every block: unique string `id`. Rich text spans: `{"type":"text","value":"…"}` (+ optional `"marks":[{"type":"bold"}]`).

- eyebrow `{"type":"eyebrow","text":"EPIC · DEBRIEF"}`
- heading `{"type":"heading","level":1,"text":"…"}` (levels 1-3)
- byline `{"type":"byline","items":["…","…"]}`
- ingress `{"type":"ingress","text":"…"}` — the standfirst under the title
- paragraph `{"type":"paragraph","content":[<spans>]}`
- callout `{"type":"callout","content":[<spans>]}`
- pullquote `{"type":"pullquote","text":"…"}`
- divider `{"type":"divider"}`
- list `{"type":"list","items":[[<spans>],[<spans>]]}` — items = array of span-arrays.
  A span array holds INLINE leaves only. Do NOT wrap an item in a block node:
  `items:[[{"type":"paragraph","content":[…]}]]` and the same with `"list-item"`
  put the text one level too deep. Measured 2026-09-02: 75 items across 4
  published papers rendered as EMPTY bullets that way. The reader now unwraps
  one level (render/inline.ex), so old papers heal — but author the flat form.
- table `{"type":"table","head":["…"],"rows":[["…","…"]]}` — plain strings in cells
- stat-grid `{"type":"stat-grid","items":[{"label":"…","value":"…"}]}` (compact); stats = same shape, larger
- gauge-list `{"type":"gauge-list","title":"…","max":75,"mode":"share","rows":[{"label":"…","value":60,"note":"…"}]}`
- cards `{"type":"cards","items":[{"title":"…","text":"…","tone":"ok"}]}` — tone optional
- steps `{"type":"steps","steps":[{"title":"…","blocks":[<blocks>]}]}`
- pipeline `{"type":"pipeline","nodes":[{"title":"…","detail":"…","kind":"source|emit|gate","source":true?}]}`
- tabs `{"type":"tabs","tabs":[{"label":"…","blocks":[<blocks>]}]}`
- expandable `{"type":"expandable","summary":"…","children":[<blocks>]}`
- diagram `{"type":"diagram","source":"flowchart TD\n  A --> B","caption":"…"}` — mermaid
- toc `{"type":"toc","items":[{"anchor":"…","level":1,"text":"…"}]}`
- code `{"type":"code",…}` / terminal — quote REAL output only

Publish: POST `<server>/w/default/p/default/v1/data/mutate/production` with
`{"mutations":[{"createOrReplace":{"_type":"paper","_id":"<slug>","title":"…","style":"article","description":"…","main_tag":"<registered>","tags":[{"tag":"…","strength":95,"rationale":"…"}],"blocks":[…]}},{"publish":{"id":"<slug>","type":"paper"}}]}`
— style=article is MANDATORY; tags must exist in `bp tag browse` (else 422 unknown_tag); strengths DISTINCT, max = main_tag. Verify: `bp doc get paper <slug>` shows `_draft:false`; GET `/papers/<slug>` returns 200.
