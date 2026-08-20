<!-- doc-tier: cold | canonical-for: pe-w6-kernel-clean-worked-example-sweep | budget: 900tok -->

# pe-w6 kernel-clean worked-example sweep (2026-08-17)

Which premium corpus papers round-trip clean through `bp paper pull` (18-tag BPML kernel, live guerrilla server) TODAY.

## Re-derivation

    cd $(mktemp -d)
    for s in hobby-hardening-capstone portabledoc-showcase scaffy-duels-prereg \
             one-shot-onboarding epic-paper-beauty-reference-wave-2026-07-31 \
             paper-authoring-excellence personal-dev-fleet-strategy \
             portabledoc-potential-study heggemsnes-act mechanical-spacing-doctrine \
             jarl-flagship-wave-2026-07-31 paper-excellence-wave-2026-08-17 \
             paper-excellence-wave-2026-08-12 scaffy-command-showcase \
             papers-pro-toolkit-capstone epic-memory-design-alignment-2026-07-24 \
             t3code-upgrade-transcript-premium claude-ready-servers-product-strategy; do
      echo "== $s"; bp paper pull "$s" 2>&1 | tail -1
    done
    # winner check: bp paper pull paper-excellence-wave-2026-08-17 && bp paper diff paper-excellence-wave-2026-08-17  (expect: clean)

## Result (server = guerrilla.barkpark.cloud, cli commit a653550420)

CLEAN (pull ok + diff clean): paper-excellence-wave-2026-08-17 (39KB, on-topic, richest kernel use incl. real <expandable> block), jarl-flagship-wave-2026-07-31 (36KB, jarl.no dogfood — off-topic, no tables/stats), scaffy-duels-prereg (13KB), paper-authoring-excellence (11KB, rev "1" — the guide itself).

422 bpml_unprintable — toc: hobby-hardening-capstone, portabledoc-potential-study · notes: heggemsnes-act, mechanical-spacing-doctrine · action: one-shot-onboarding · inline strike: portabledoc-showcase · mark(unspellable): personal-dev-fleet-strategy · head_cell: paper-excellence-wave-2026-08-12 · block (generic): epic-paper-beauty-reference-wave-2026-07-31, scaffy-command-showcase, scaffy-command-footprints, papers-pro-toolkit-capstone, papers-pro-toolkit-crown-and-toolkit, epic-memory-design-alignment-2026-07-24, t3code-upgrade-transcript-premium, parity-page-wave-2026-07-11, claude-ready-servers-product-strategy.

404: epic-paper-beauty-reference (real slug is epic-paper-beauty-reference-wave-2026-07-31).

RECOMMENDATION: a premium kernel-clean example ALREADY exists — paper-excellence-wave-2026-08-17. Guide-slice scope shifts from "author a demo" to "point at / lightly excerpt an existing paper". Caveat: it is a wave/strategy meta-paper, not a tutorial; if the guide wants a purpose-built width-law tutorial, author a fresh kernel-only example instead.

FINDING: <expandable> now round-trips (pew2 line 149 is a real expandable block, pulled clean) — contradicts the "5-type hole (notes/figure/asciicast/columns/expandable)" listed in older papers; kernel has grown since. figure/notes/toc/columns/asciicast/action/strike/head_cell still 422.
