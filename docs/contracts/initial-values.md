<!-- doc-tier: agent | canonical-for: initial-values-today-token | budget: 500tok -->
# Initial values and `"$today"`

A schema's `initial_values` fill a new document on create; values the caller sends win, and maps merge deeply. A desk list's `initialValues` preset its "+". `GET /v1/schemas` and `/v1/structure` serve both as written; the Studio resolves tokens when it starts a document.

`"$today"` is a token only as that exact string; `"$todayx"`, `" $today"` or a longer string stay text, as does any other `$name`. On create the field's type decides: `date` gets today's date (`2026-11-21`) in the workspace time zone, `datetime` the current instant in UTC (`2026-11-20T23:30:00.123Z`, Sanity's `new Date()`), any other declared type keeps the text `$today`, and a key the schema does not declare gets the date. `"$today.year"` is the year as a string.

In a `deskStructure` list's `filter`, a tree's `rootFilter` or a groupBy's `overFilter`, `{"content.sluttdato": {"gte": "$today"}}` compares with today's date; on a `datetime` field, with the instant today began. `/v1/structure` serves the resolved date. A document with no value matches neither `gte` nor `lt`.

The zone is the workspace's `time_zone` (`bp workspace set-time-zone`); none set, or a name the zone database lacks, is UTC. Code: `api/lib/barkpark/content/today.ex`.
