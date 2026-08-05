<!-- doc-tier: cold | canonical-for: legendary-paper-survey-48-evidence | budget: 1200tok -->
# Survey 48 — PDS wave 44 / public semantics

Verdict: `partial`. Public structural parity is excellent, but data-table accessibility, callout semantics, structural links/tasks, document metadata, and revision provenance are materially incomplete.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; all 99 unique block IDs map to expected public element shapes.
- All 32 headings render as H1 ×1, H2 ×24, H3 ×7 with no level skips. One `<main>` contains one `<article id="paper-body">`, and `<html lang="en">`; the article landmark is unnamed.
- Five data tables render 54 body rows. Three contain 12 visible `<th>` cells, but all five declare `role="presentation"`, no header has `scope`, and two headerless tables render label-like first rows as `<td>`.
- All ten lists / 85 items preserve semantic `<ul>/<li>` structure. Four absent-tone callouts normalize to visual info divs with no role, ARIA label, or textual tone cue.
- Source contains no marks, structural links, wikilinks, or task nodes. Task IDs, PRs, filenames, and URLs remain inert prose; the article contains zero anchors.
- Fifteen empty paragraphs suppress content while retaining stable blank block wrappers; 33 substantive paragraphs render normally.
- Public identity metadata is wrong: `<title>` is `Paper · Barkpark`, while Open Graph, Twitter, and JSON-LD use `Barkpark`. The correct title appears only in the H1/source because stored `preview.title` is null.
- Public HTML does not expose pinned content revision `8bbd5d…`; `<article data-rev="0">` is a stream revision, not content provenance.

Mix tests could not run because dependencies are absent. Verify should remove presentation roles from genuine data tables, decide header policy for the two headerless tables, add callout semantics, convert deliberate task/PR references into structural links, fall back metadata to the Paper title, name the article landmark, and expose immutable content revision separately from stream state. No state mutation occurred.
