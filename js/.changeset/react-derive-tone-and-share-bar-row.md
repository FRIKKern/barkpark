---
'@barkpark/react': patch
---

PortableDoc: derive the callout tone label instead of spelling it twice, and emit the proportional-bar row from one function instead of three copies. No output change — the renderer is byte-identical for every input — but it takes ~86 B of gzip back off the client entry and ~82 B off the RSC server entry, which is what restores the `dist/index.mjs` and `dist/server.mjs` size budgets to green after two security fixes landed on top of ~30 B of remaining headroom.

`calloutToneClass` and `toneLabel` were two parallel five-arm switches over the same tones, and between them spelled every tone word three times — the class switch even repeated each word on its own arm (`case 'success': return 'success'`). They are now one `CALLOUT_TONES` list: the CSS modifier IS the tone slug, and the default summary label is its sentence-cased form. A fifth tone is now a one-line edit that cannot leave a label drifting from its class. `capitalize` moves to the shared `inline` spine, where the taskboard — which already derived its column labels the same way — now reads it instead of keeping a private copy.

`gauge-list`, `bar-chart` and `criteria-progress` each carried their own copy of the same row markup while their comments all said they ride "the same proportional-bar vocabulary". That sentence is now structural: one `barRow(prefix, label, prop, digit, extra)` emits the label, the filled track, the optional digit and the family's trailing slot, so the element ORDER can no longer drift between the three families. Only the BEM prefix varies.

Neither URL guard was touched: `safeUrl`'s control-character strip and `@barkpark/core`'s `isHttpUrl` scheme allowlist are unchanged, and both keep their tests. They look like overlapping URL work but cannot be merged — `safeUrl` must accept `mailto:`, `tel:` and relative hrefs that `isHttpUrl` must reject, so folding them together would widen one guard or break the other.
