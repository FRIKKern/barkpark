<!-- doc-tier: cold | canonical-for: legendary-paper-survey-35-evidence | budget: 1200tok -->
# Survey 35 — Cloud Console wave 28 / Studio reader

Verdict: `partial`. Authenticated Studio chrome is coherent at desktop width but clips essential controls at 390 pixels; the headless LiveView never connected, so real canvas content geometry remains unproven.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; all 237 blocks reached server-rendered `data-canvas-blocks`.
- At 1440×900, the 48-pixel topbar fits. The pane row is 825.4 pixels high with a 44-pixel Structure strip, 260-pixel Papers list, and 1,136-pixel editor. Editor content is 836 pixels, containing a centered 720-pixel Paper shell and 300-pixel metadata sidebar.
- Studio owns scrolling inside panes; the page stays exactly 1440×900. Default desktop chrome is crowded but coherent.
- At exact 390×844, the topbar’s content width is 585 pixels. The tab strip exceeds the viewport by six pixels and all right actions at x=420–585 are clipped by the overflow-hidden shell.
- Phone navigation panes hide as intended, but the editor and header each have 831-pixel scroll width inside 390 visible pixels. The long title plus share/standalone actions exceed the visible header.
- Editor body is 349 pixels, metadata collapses to 41 pixels, and the Paper shell is 349 pixels. Active focus remained on `BODY`; no useful editor/navigation focus was established.
- The client reported `connected:false`; `.ProseMirror` remained empty at 317×29.7 pixels despite the complete server payload. Therefore heading, spacer, table-control, block-focus, and content-scroll geometry are explicitly unproven rather than reported empty.
- Auth used an existing admin token through documented login and created only a local signed browser cookie.

Required Verify work: connected real-browser Studio capture at desktop/390px, reachable phone back/actions, focus and keyboard navigation, editor/table scrolling, and canvas initialization. Safari/Firefox, touch, beta-focus mode, and alternate themes remain unvisited. No state mutation occurred.
