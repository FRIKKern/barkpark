# astro-phone-waterfall — CONFIRMED 2026-07-28

Claim: the DEPLOYED Astro flagship downloads bp-graph.js + graph.json at 390px,
where the graph pane is `display:none`. The Next edition, same viewport, does not.

Tree: origin/main @ ab396959c. Live host: guerrilla.barkpark.cloud.

## Re-derive (static, no browser)

    curl -s -H 'User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' \
      https://guerrilla.barkpark.cloud/sites/astro-search/ | grep -o 'bp-graph-slot[^>]*'
    # => bp-graph-slot" class="hidden min-w-0 flex-1 md:block"   (CSS-only hide)

    ls -l templates/astro-search-starter/public/bp-graph.js   # 140221 bytes

## Re-derive (browser, CDP)

chrome-devtools MCP:
  emulate viewport 390x844x3,mobile,touch + iPhone UA
  navigate https://guerrilla.barkpark.cloud/sites/astro-search/  (ignoreCache)
  wait ~7s, then evaluate:

    () => ({ w: innerWidth,
             mdMatch: matchMedia('(min-width: 768px)').matches,
             slotDisplay: getComputedStyle(document.getElementById('bp-graph-slot')).display,
             perf: performance.getEntriesByType('resource')
                    .filter(e => /bp-graph\.js|graph\.json/.test(e.name))
                    .map(e => ({ n: e.name, enc: e.encodedBodySize })) })

  ASTRO @390 =>
    w:390 mdMatch:false slotDisplay:"none" slotChildren:1
    bp-graph.js  enc 140221  initiatorType "script"
    graph.json   enc 436769  initiatorType "fetch"
    => 576,990 B of graph payload on a phone that can never see the graph.

  CONTROL, NEXT edition @390 (same emulation, /sites/search-ember/) =>
    w:390 mdMatch:false graphScriptTags:0 graphHits:[] totalResources:15
    => zero.

  CONTROL NOT VACUOUS — same edition @1440x900 =>
    mdMatch:true, GET .../sites/search-ember/bp-graph.js [304]
    => the Next edition DOES load the asset; the breakpoint is what suppresses it.

## Why the editions differ (source, origin/main)

  templates/astro-search-starter/src/pages/index.astro:49
    <div id="bp-graph-slot" class="hidden min-w-0 flex-1 md:block"></div>
  templates/astro-search-starter/src/components/FinderIsland.tsx:273-283,348
    useGraphSlot() resolves by document.getElementById ALONE — no matchMedia —
    and :348 createPortal(<GraphPane/>, slot) whenever the element exists.
  .../GraphPane.tsx:51-60 loadRendererScript() appends <script src=bp-graph.js> on mount.

  templates/search-starter/components/desktop-only.tsx:38-44 documents the fix
  IN CODE: "CSS display:none does NOT stop that script from downloading and
  executing, but never mounting it does."

## The gate assertion (mutation-provable)

  Beat PHONE, in tooling/search-smoke/journey-smoke.mjs (1001 lines, raw CDP,
  Network.enable ALREADY sent at :284, --self-test already runs good/ + rot/
  fixtures — so the mutation proof is native, not new):

    At Emulation.setDeviceMetricsOverride 390x844 mobile, after load+settle,
    ZERO Network.requestWillBeSent URLs match /bp-graph\.js|graph\.json/.

  Control that proves it can fail: the same beat at 1440x900 must see >=1.
