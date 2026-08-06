<!-- doc-tier: cold | canonical-for: legendary-paper-verify-05-evidence | budget: 1600tok -->
# Verify 05 — public-reader semantics and identity

Verdict: `refuted`. The public reader preserves heading levels and basic list containers, but all four pinned Papers lose essential table, callout, inline-mark, article-name, canonical-link, and nested-list semantics.

| Contract | Source census | Public result |
| --- | ---: | --- |
| Block identity | 815 blocks | 815 keyed wrappers preserved |
| Headings | 145 | all correct H1/H2/H3 levels |
| Lists | 39 containers / 231 items | containers/items present; 11 Wave 29 items empty |
| Tables | 46 / 113 header cells / 1,374 body cells | all `role=presentation`; zero caption, scope, IDs, or `headers` associations |
| Callouts | 30 / 2,280 lexical words | all roleless and unnamed |
| Inline marks | 388 across 78 blocks | zero semantic `strong`, `b`, or `code` elements |

Proven working:

- Every Paper has `html lang=en`, one `main`, and one `article`.
- Cloud Console Papers preserve consistent H1, document, OpenGraph, Twitter, and JSON-LD identities; OG and JSON-LD URLs match their exact public URLs.

Refuted:

- All 35 explicitly header-bearing tables still become presentational and lose accessible header associations.
- Four Wave 28 `warn` callouts and one Wave 29 `note` collapse to `info`.
- Authored marks lost: 139 string-form strong marks covering 875 words, 241 string-form code marks covering 510 words, and eight map-form strong marks covering 19 words.
- Wave 29 blocks `w29D015` and `w29D022` retain 11 empty list items while losing 389 lexical words / 2,268 characters.
- Every article landmark is unnamed and every Paper lacks a canonical link.
- PDS waves 45 and 44 show generic `Paper · Barkpark`/`Barkpark` metadata because a stamped preview map with null title suppresses the valid Paper-title fallback.

Source defects remain distinct from reader defects: PDS 45 has nine genuinely headerless tables and PDS 44 has two; fourteen callouts omit tone; both PDS Papers have `preview.title: null`. Reader defects are presentational-table emission, unnamed callouts, tone alias collapse, ignored string marks, styled-span rather than semantic strong, unnormalized nested paragraph-list items, null-title fallback failure, and missing canonical emission.

The proof audited all four pinned revisions and their 815 source blocks against captured deployed HTML. Causation was traced through `compose.ex`, `inline.ex`, `walk.ex`, `bulldocs_live.ex`, `bulldocs.html.heex`, and `share_meta.ex`. A later transient PDS 45 HTTP 500 is an availability concern for a separate operational lane; it does not invalidate the successful pinned semantic capture. No repository, task, or Paper mutation occurred.
