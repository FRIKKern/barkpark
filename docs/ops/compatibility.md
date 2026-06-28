<!-- doc-tier: human | canonical-for: compatibility-contract | budget: 1200tok -->
# Compatibility & support contract

What stays stable, what may change, and how change is signalled. The promise in one line:
**your data and your schemas will not break under you.**

## Versioning (semver)

- **JS packages** — `@barkpark/*` follow semver, published to npm by dist-tag:
  `preview` and `next` are the pre-release channels, `latest` is what a bare `npm install`
  resolves. The publish tag is governed by changeset pre-mode, not the workflow input — see
  [../decisions/0002-npm-dist-tag.md](../decisions/0002-npm-dist-tag.md) and
  [../decisions/0003-sync-tags.md](../decisions/0003-sync-tags.md).
- **HTTP API** — path-versioned under `/v1`. Per
  [../decisions/0001-sdk-envelope.md](../decisions/0001-sdk-envelope.md) any change to the
  response envelope (the `result` wrapper + `schemaHash`/`etag`/`ms`/`syncTags` metadata)
  requires an API version bump **and** a new decision record. Regression fixtures fail any
  PR that breaks the envelope.

## Your data and schemas won't break under you

These are the standing guarantees, anchored to behaviour the code actually enforces:

- **`flat_mode` is permanent.** The eight legacy seed schemas (`post`, `page`, `author`,
  `category`, `project`, `siteSettings`, `navigation`, `colors`) validate byte-for-byte
  forever, on the original v1 validator branch. There is **no** migration timetable forcing
  them onto v2. Owner: [../contracts/schema-v2.md](../contracts/schema-v2.md).
- **v2 field types are additive.** Composites, arrays, codelists, and localized text are
  opt-in on plugin schemas; adding them never alters how a flat schema validates.
- **No schema deletion in v1.** A schema file vanishing from disk keeps its
  `schema_definitions` row, so existing documents stay valid; removal is a manual ops act.
  Owner: [../cards/plugins.md](../cards/plugins.md).
- **Public reader URLs are stable.** The `paper` type and `/papers/:slug` (and `/sheets/:slug`)
  survived the plugin lift with no data migration and no URL break — and stay stable.

## Support window

What is true today: Barkpark is **pre-1.0**. The shipping line is `1.0.0-preview.*` on the
`preview` channel; `latest` begins tracking GA when `1.0.0` ships.

A concrete month-count support window (how long a given minor is patched) is **not yet
encoded anywhere in code** — only the `preview`/`next`/`latest` dist-tags and the
`1.0.0-preview.*` versions exist. Stating a number here would invent a promise the code does
not back. The window length is an open **owner / business decision**; this section will state
it once it is set. Until then, the data and schema guarantees above are the binding part.
