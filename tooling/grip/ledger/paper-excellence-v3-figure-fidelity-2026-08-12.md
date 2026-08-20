# v3 — figure fidelity: lineage, chart annotations, mermaid (2026-08-12)

Re-derivation recipes for the paper-excellence wave's figure-fidelity verdicts.
Probe paper: `/papers/probe-figure-fidelity-2026-08-12` (rev 3, guerrilla).
Payload lives in the run scratchpad; it is reproducible from the recipe below.

## 0. Republish the probe (payload is 12 blocks: heading/paragraph/lineage/chart/figure>diagram/table/stats)

    bp bulldocs publish probe-figure-fidelity-2026-08-12 --file payload.json --yes

Table cells MUST be `{"text": "..."}` objects — a bare string cell is refused by
`Barkpark.Content.Papers.BlockOps.render_table_cell_errors/2`
(api/lib/barkpark/content/papers/block_ops.ex:1596-1611) even though
`Render.Inline.compose_inline_children/1` (inline.ex:25) renders a bare binary fine.

## 1. Static render markers (no browser)

    curl -s https://guerrilla.barkpark.cloud/papers/probe-figure-fidelity-2026-08-12 -o live.html
    grep -o '<rect class="bp-chart__region[^"]*"' live.html | sort | uniq -c
    grep -o '<line class="bp-chart__refline[^"]*"' live.html | sort | uniq -c
    grep -o '<circle class="bp-chart__pt"' live.html | wc -l
    grep -o '<text class="bp-chart__ann"[^>]*>[^<]*' live.html | sed 's/.*>//'
    grep -o '<li class="bp-lineage__node">' live.html | wc -l
    grep -o '<pre class="mermaid">[^<]\{0,40\}' live.html

Expected: 2 region rects (info+danger), 2 reflines (ok+warn), 2 points,
6 annotation texts, 4 lineage nodes, 1 mermaid pre.

## 2. Measured geometry (own headless Chrome — the shared MCP browser is contested
by concurrent sessions and silently re-selects another agent's tab)

    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
      --remote-debugging-port=9333 --user-data-dir=/tmp/probe-profile --no-first-run &
    python3 probe.py 9333    # 360/768/1440 x light/dark: measure + screenshot
    python3 probe2.py        # mermaid viewBox scale, table overflow
    python3 probe3.py        # annotation bbox vs viewBox (clipping), region tones

`probe.py` computes rendered text size as
`parseFloat(getComputedStyle(el).fontSize) * (svgBox.width / svg.viewBox.baseVal.width)`
— the SVG scale factor, which is what makes a declared 11px tick paint at 4.26px.

Headline numbers (2026-08-12, guerrilla, rev 3):

| width | article px | body px | chart scale | tick painted | ann painted | mermaid scale | mermaid label painted | lineage rows x cols |
|---|---|---|---|---|---|---|---|---|
| 360 | 360 | 16 | 0.388 | 4.26 | 3.88 | 0.233 | 3.73 | 4 rows x 1 |
| 768 | 720 | 16 | 0.950 | 10.45 | 9.50 | 0.641 | 10.26 | 2 rows (3+1) |
| 1440 | 720 | 16 | 0.950 | 10.45 | 9.50 | 0.641 | 10.26 | 2 rows (3+1) |

Light and dark are byte-identical on every geometry number.

## 3. Mutation proof — the spacing_norm advisory counts `text`-shaped paragraphs

    # baseline: 1 text-paragraph, 0 empty blocks  -> warns "1 empty paragraph block(s)"
    bp bulldocs publish probe-figure-fidelity-2026-08-12 --file payload.json --yes
    # add ONE more non-empty text-paragraph + one non-empty content-paragraph
    bp bulldocs publish probe-figure-fidelity-2026-08-12 --file payload-mut.json --yes
    # -> warns "2", not "3": the content-shaped one is not counted, the text-shaped ones are

Source: `emit_spacing_norm_advisory/3`, api/lib/barkpark/content/authoring_wall.ex:299-302 —
`b["type"] == "paragraph" and List.wrap(b["content"]) == []`. A `text`-shaped
paragraph carries no `content` key, so `List.wrap(nil) == []` matches.

Confirm the stored tree really has no empty blocks:

    curl -s 'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=1&filter=_id=="probe-figure-fidelity-2026-08-12"' \
      | python3 -c 'import json,sys; b=json.load(sys.stdin)["result"]["documents"][0]["blocks"]; print(len(b)); print([x["type"] for x in b])'

## 4. Source anchors used

- lineage emitter: api/lib/barkpark/portable_doc/render/data_viz.ex:277-330
- lineage layout: api/assets/paper-surface/paper-surface.css:1028-1035 (`auto-fit, minmax(150px,1fr)`, gap 14px, per-node `border-top`)
- chart emitter + viewBox 640x190: data_viz.ex:637-704 (`preserveAspectRatio="none"`)
- chart annotations: data_viz.ex:728-830 (`regions_svg`, `overlays_svg`)
- chart CSS: paper-surface.css:954-991 (tick 11px, `.bp-chart__ann` 10px, region opacity 0.08)
- mermaid figure: api/lib/barkpark/portable_doc/render/figures.ex:83-95
