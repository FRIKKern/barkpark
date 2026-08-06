<!-- doc-tier: cold | canonical-for: legendary-paper-verify-24-evidence | budget: 1800tok -->
# Verify 24 — Paper-to-task relationship structure

Verdict: the blanket `mostly prose` claim is `refuted`; the in-body version is `proven`. Of relationships named inside the four Paper bodies, 55.3% lack matching structured task fields. After adding corpus-side structured relationships not named by task ID in the bodies, structured relationships narrowly become the majority at 51.5%.

Across 815 blocks, the four pinned Papers contain zero task wikilinks, zero task/link nodes, and zero `papers` or `wave_paper` keys. Token resolution produced 85 distinct Paper/task pairs covering 71 live tasks. Only 38/85 body pairs have a task `wave_paper` pointing back to the Paper containing the mention; `papers` contributes zero. Therefore 47/85 body relationships are prose-only.

A full 4,848-task census found 50 exact `wave_paper` relationships to the four Papers: 22 / 10 / 7 / 11. Twelve Cloud wave-29 relationships are structured on the task side but not named by task ID in that Paper body. The union denominator is therefore 50 structured versus 47 prose-only relationships, refuting an unqualified project-wide majority claim.

Every live reverse-discovery surface is nevertheless empty for all four Papers: `doc backlinks` returns count 0, `graph tasks` returns count 0, and `graph show` returns one Paper node with zero edges. This is consistent with source: the graph reverse view materializes `design_doc`/`papers`, not legacy `wave_paper`. Thus even the 50 structured relationships are invisible to the current backlinks, graph, and reader task-chip paths.

Canonical task-chip behavior itself is healthy. Seven focused `pdrender` task-chip tests pass, as does the 80-column taskboard golden, rendering live state like `[⠋ in_progress · P1 · 2/3]` plus title. The four Papers never activate this because their references are plain text rather than canonical wikilinks shaped as `{target,docId,children}`.

Token accounting resolved 83 exact task-ID pairs directly. The shorthand `cch-w22-s7` has one unique live-prefix resolution and appears in two Cloud Papers, adding two pairs. Two other shorthand forms are corrected nearby to already-counted full IDs. Remaining broad-regex matches were explicitly classified as wave/slice shorthand, Paper or ledger IDs, filenames, branches, PDS decision numbers, or generic phrases rather than silently counted.

Task metadata is a current-corpus census while the Papers are revision-pinned, and natural-language title mentions cannot be made mechanically equivalent to IDs. More importantly, `wave_paper` remains useful but undeclared and invisible to discovery. No repository or Barkpark state was mutated; concurrent leader-created Verify 22/23 ledgers were the only untracked files observed at pinned commit `6a32db719b6427b490884053763aba63b36f1d7a`.
