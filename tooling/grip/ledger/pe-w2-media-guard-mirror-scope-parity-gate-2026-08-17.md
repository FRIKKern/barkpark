# pe-w2 small residuals — media-delete where-used guard, editor-bundle mirror scope, canvas⇄reader parity gate

Verifier residuals for the Paper Excellence wave-2 decide phase (2026-08-17).
Every row below is re-derivable from `origin/main` (no worktree state).

## (a) `bp media delete` has NO where-used guard — and the existing where-used surface could not supply one

    # the two delete controllers: neither consults any usage/reference graph
    git show origin/main:api/lib/barkpark_web/controllers/v1/media_controller.ex | sed -n 401,420p
    git show origin/main:api/lib/barkpark_web/controllers/media_controller.ex   | sed -n 362,372p
    # the core: row delete + blob + renditions + CDN purge + plugin cascade, no usage read
    git show origin/main:api/lib/barkpark/media.ex | sed -n 413,455p
    # a where-used API EXISTS …
    bp capabilities -o json | grep -o '"media","relations"[^]]*'
    # … but its inbound leg only follows mediaAsset.content.relatedAssets edges
    git show origin/main:api/lib/barkpark/media/storage/relations.ex | sed -n 66,110p
    # papers store picked media as a RAW URL string, not a document reference
    grep -rn "/media/files/" api/assets/paper-editor/src/__featured_placeholder.test.mjs

Verdict: hazard REAL and unguarded; a guard cannot reuse `Relations.graph/3`
(asset↔asset only). It needs a block-JSON scan for `/media/files/<path>`.

## (b) editor-bundle mirror scope = blessed PATTERN, accreted ROSTER, no roster gate

    # the ONE source is inlined by Studio / reader / sheet export — only the
    # standalone embedder bundle is a hand copy
    git show origin/main:api/lib/barkpark/portable_doc/render/stylesheet.ex | sed -n 1,30p
    grep -n "paper_stylesheet" api/lib/barkpark_web/layouts.ex
    # per-block justifications, each naming "standalone embedder / blessed callout-mirror pattern"
    git show origin/main:api/assets/paper-editor/src/styles.css | sed -n 560,600p
    git show origin/main:api/assets/paper-editor/src/styles.css | sed -n 826,860p
    # the declared embed scope is prose-only (paragraph / heading / list)
    git show origin/main:api/assets/paper-editor/EMBED-CONTRACT.md
    # the only gate over the file sees bp-canvas-* ONLY
    git show origin/main:scripts/paper-editor-mirror-check.sh | sed -n 70,95p
    bash scripts/paper-editor-mirror-check.sh
    # reader-class scope, three sinks compared
    for f in api/assets/paper-surface/paper-surface.css api/assets/paper-editor/src/styles.css; do \
      git show origin/main:$f | python3 -c "import re,sys;s=re.sub(r'/\*.*?\*/',' ',sys.stdin.read(),flags=re.S);\
      cs=sorted({c for c in re.findall(r'\.(bp-[a-z0-9-]+)',s) if not c.startswith('bp-canvas')});print(len(cs))"; done
    # → 126 (source) vs 32 (bundle)

## (c) canvas⇄reader parity gate is MARKUP-producer identity, zero CSS

    git show origin/main:api/test/barkpark/portable_doc/render/canvas_reader_parity_gate_test.exs | sed -n 1,80p
    # stat/stats/stat-grid/heatmap/chart ARE in its painted-fleet corpus (markup half closed)
    git show origin/main:api/test/barkpark/portable_doc/render/canvas_reader_parity_gate_test.exs | grep -n '"stat\|"heatmap"\|"chart"'
    # the CSS parity gate's device coverage (bp-cols / bp-hr / bp-section__grid / bp-button = 0)
    for c in bp-table bp-callout bp-section-divider bp-cols bp-hr bp-section__grid bp-button bp-stats bp-chart; do \
      printf '%s %s\n' "$c" "$(git show origin/main:api/test/barkpark/portable_doc/render/view_edit_parity_test.exs | grep -c -- $c)"; done
