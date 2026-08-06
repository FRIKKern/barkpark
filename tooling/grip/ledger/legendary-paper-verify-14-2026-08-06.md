<!-- doc-tier: cold | canonical-for: legendary-paper-verify-14-evidence | budget: 1800tok -->
# Verify 14 — email semantics and accessibility

Verdict: `refuted`. The deployed email HTML retains heading order and exact visible text for three Papers, but loses 2,268 authored characters from Cloud Console wave 29 and fails the table, callout, landmark, language, and inline-mark semantic contract across all four pins.

| Paper | Tables presented | Header cells / associated | Callouts / semantic role | Source/output text |
| --- | ---: | ---: | ---: | --- |
| Cloud Console wave 29 | 11/11 | 35 / 0 | 4 / 0 | −2,268 chars; 11 blank list items |
| PDS wave 45 | 12/12 | 9 / 0 | 9 / 0 | exact |
| Cloud Console wave 28 | 18/18 | 57 / 0 | 13 / 0 | exact |
| PDS wave 44 | 5/5 | 12 / 0 | 4 / 0 | exact |
| Total | 46/46 | 113 / 0 | 30 / 0 | one lossy Paper |

- Fresh flat `/papers/:slug/email` and source reads returned 200 for every pinned revision. Email SHA-256 values were `dc57c4…e331`, `3e29bd…a900`, `cfe862…a621`, and `c46f46…7645`; canonical source block hashes match the prior JSON corpus.
- Every data table emits `role="presentation"`. Although all 113 authored header cells render as `<th>`, none has `scope`, `id`, or matching `headers`; the accessibility table model and associations are absent.
- All 30 callouts are plain divs without role or accessible name. Twenty-five render blue and five amber. Authored `warn` and `note` silently fall back to info, and tone is color-only.
- None of the documents has `html[lang]`, `<main>`, or `<article>`. Each retains a nonempty `<title>`, exact heading sequence, one H1, no later H1, and no level skip.
- Cloud 29 has 67 source/output list entries but eleven paragraph-map items render empty. Their missing 2,268 characters exactly explain the body-text delta. `normalize_list_item/1` handles a paragraph map, not a list containing one; the unknown-inline path degrades it to empty text.
- Source contains 147 strong and 241 code marks. CCH28/29 string-form marks fall through unrecognized; PDS45 map-form strong marks become visually bold spans, not semantic `<strong>`. No authored code mark becomes `<code>`.

Negative coverage finding: current route/render tests pin presentation tables and flat list items but do not cover nested paragraph items, string-form marks, language, landmarks, callout semantics, or table associations. The emitted markup matches the pinned source paths, but the deployment exposes no independent commit attestation. Client/screen-reader trials remain necessary after structural repair; they cannot restore semantics absent from the DOM.

Evidence covered the four exact revisions, deployed flat and scoped routes, DOM/source text hashing, and the renderer/controller paths at clean commit `243a8da520`. No repository, Paper, task, or server state was mutated.
