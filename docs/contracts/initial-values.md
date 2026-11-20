<!-- doc-tier: agent | canonical-for: initial-values-today-token | budget: 500tok -->
# Initial values and `"$today"`

A schema's `initial_values` fill a new document on create; values the caller sends win, and maps merge deeply. A desk list's `initialValues` preset its "+". `GET /v1/schemas` and `/v1/structure` serve both as written; the Studio resolves tokens when it starts a document.

`"$today"` is today's date (`2026-11-21`) and `"$today.year"` its year (`"2026"`), on any field, at any depth. Only that exact string is a token; `"$todayx"`, `" $today"`, a longer string or another `$name` stay text.

Today is the date in the workspace's `time_zone` (`bp workspace set-time-zone`). A workspace with no zone, or a name the zone database lacks, reads UTC, as before zones existed. With a zone set, the date between local midnight and UTC midnight is the zone's.

In a query filter (`{"content.sluttdato": {"gte": "$today"}}`, `?filter[content.sluttdato][gte]=$today`) the token resolves on every read, in the caller's workspace zone. A `deskStructure` list's filter is stored and served as written, so «Kommende» moves at midnight with no reload. A document with no value matches neither `gte` nor `lt`.

Code: `api/lib/barkpark/content/today.ex` (zone database: the `tz` package). barkpark-studio's `fixtures/today-cases.json` pins the same answers for its Studio.
