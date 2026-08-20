# Paper 422 `semantic_empty` — re-derivation recipes (wave 24 verify, 2026-08-08)

Every row is a command that re-derives the fact from scratch. Scratch dir below is
`S=/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/47ba8708-cd1d-47ac-93d4-7cb707cf3e3c/scratchpad`
(recreate with the export row first).

| # | Fact | Rerun |
|---|---|---|
| 1 | 3 of the 4 briefed papers 422; `http-edge-truth-wave-2026-08-08` is **200**, not broken | `for s in deploy-reliability-wave-24-2026-08-08 deploy-reliability-seal-ruling-2026-08-08 deploy-reliability-lever-decision-packet-2026-08-08 http-edge-truth-wave-2026-08-08; do printf '%s ' "$s"; curl -s -o /dev/null -w '%{http_code}\n' "https://guerrilla.barkpark.cloud/papers/$s"; done` |
| 2 | The **web** reader 422s identically — refutes charter line 6809 ("owner can only reach them on the web") | `curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/papers/deploy-reliability-seal-ruling-2026-08-08` |
| 3 | CLI error body is `422 {"error":{"code":"semantic_empty"}}` | `bp paper view deploy-reliability-seal-ruling-2026-08-08` |
| 4 | Corpus census: 727 published papers, 68 lack top-level blocks, but only **41 actually 422** (27 `html_only` serve 200 off the `body_html` fallback) | `bp export --type paper > $S/papers.ndjson` then the classifier + per-slug curl loop in row 5 |
| 5 | Per-class HTTP truth: 27×200 html_only, 24×422 pm_doc, 11×422 content_only, 6×422 empty | `while read cls id; do code=$(curl -s -o /dev/null -w '%{http_code}' "https://guerrilla.barkpark.cloud/papers/$id"); echo "$code $cls"; done < $S/broken.txt \| sort \| uniq -c` |
| 6 | Three writer dialects, not one: `body={type:doc,content}` (24), `body={content}` (11), top-level `content` with `body=null` (6) | python census over `$S/papers.ndjson` (see wave-24 Paper) |
| 7 | A PM→PortableDoc converter **does exist** in-repo (refutes "no converter"): `tiptapInlineToPd` / `tiptapToBlock` / `tiptapToFullBlock` | `grep -n "^export function" api/assets/paper-editor/src/convert.js` |
| 8 | Converted blocks pass every reader predicate and render: 41/41 accept, 8,219 blocks, 4,471,809 HTML bytes | `cd api && DIR=$S/out2 MIX_ENV=dev mix run --no-start $S/checkall.exs` |
| 9 | Text fidelity 41/41 lossless (whitespace-normalised) with the v2 converter; naive v1 loses 4 papers to multi-paragraph callout/quote bodies | `node $S/conv/pm2blocks2.mjs <paper.json> <out.json>` + the python fidelity diff |
| 10 | Repair needs **no server change**: with no stored `body_html`, `cache_provenance/4` returns `:coherent` and the reader serves blocks | `git show origin/main:api/lib/barkpark/content/papers.ex \| sed -n '183,187p'` |
| 11 | Callout body is a SINGLE inline slot — multi-paragraph callouts must spill into sibling paragraphs | `grep -n "FLATTENS its single-paragraph body slot" api/lib/barkpark/portable_doc/render/compose.ex` |
| 12 | One paper (`cloud-console-hardening-wave-43-2026-08-07`) carries corrupt nested text-in-text nodes (3×) | python walk over `$S/out/cloud-console-hardening-wave-43-2026-08-07.json` |
| 13 | Prior art exists and its premise is wrong: task `dr-w23-bl-paper-view-422-on-tiptap-body` claims the web reader renders these | `bp task get dr-w23-bl-paper-view-422-on-tiptap-body -o json` |
