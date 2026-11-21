<!-- doc-tier: agent | canonical-for: initial-values-today-token | budget: 500tok -->
# Initial values and `"$today"`

A schema's `initial_values` fill a new document on create; values the caller sends win, and maps merge deeply. A desk list's `initialValues` preset its "+". `GET /v1/schemas` and `/v1/structure` serve both as written. A Studio resolves them when it starts a document: barkpark-studio does from #1339 on; an older one stores the literal on its first edit.

`"$today"` is today's date (`2026-11-21`) and `"$today.year"` its year (`"2026"`), on any field, at any depth. Only that exact string is a token; `"$todayx"`, `" $today"`, a longer string or another `$name` stay text.

Today is the date in the workspace's `time_zone` (`bp workspace set-time-zone`). A workspace with no zone, or a name the zone database lacks, reads UTC, as before zones existed. With a zone set, the date between local midnight and UTC midnight is the zone's.

In a query filter the token resolves on every read, in the caller's workspace zone, as the exact value in any form: an operator (`{"content.sluttdato": {"gte": "$today"}}`, `?filter[content.sluttdato][gte]=$today`), the shorthand `{"content.dato": "$today"}`, or an item of `in`. A request reads the workspace once. A `deskStructure` list's filter is stored and served as written, so «Kommende» moves at midnight with no reload. A document with no value matches neither `gte` nor `lt`. On a datetime field the date text is compared, so `gte` matches from 00:00 UTC of the local date (01:00 or 02:00 in Oslo). The listen stream's `filter[f]=$today` and GROQ do not resolve it: there it is the literal text.

Code: `api/lib/barkpark/content/today.ex` (zone database: the `tz` package). barkpark-studio's `fixtures/today-cases.json` pins the same answers for its Studio.
