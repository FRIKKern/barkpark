<!-- doc-tier: human | canonical-for: chronicle-paper-generator | budget: 700tok -->
# Barkpark Chronicle

The Chronicle is Barkpark's living changelog rendered as native Papers. One first-parent Git scan projects the selected UTC date into five current editions plus a bounded archive of detailed monthly chapters:

- `/papers/barkpark-chronicle`
- `/papers/barkpark-changelog-YYYY-MM-DD`
- `/papers/barkpark-changelog-YYYY-wWW`
- `/papers/barkpark-changelog-YYYY-MM`
- `/papers/barkpark-changelog-YYYY`

Generate today's editions plus up to 18 active monthly chapters locally:

```sh
python3 scripts/chronicle-paper.py --ref HEAD --output-dir /tmp/barkpark-chronicle
```

Choose a different archive horizon, or disable backfill with `0`:

```sh
python3 scripts/chronicle-paper.py --ref HEAD --history-months 36 --output-dir /tmp/barkpark-chronicle
```

Generate another UTC date or inspect one lens on stdout:

```sh
python3 scripts/chronicle-paper.py --date 2026-08-23 --ref HEAD --only week
```

Publish the current editions and monthly archive through the existing Bulldocs ingest route:

```sh
BARKPARK_INGEST_TOKEN=… python3 scripts/chronicle-paper.py --ref HEAD --history-months 18 --publish
```

`BARKPARK_API_URL` optionally selects another Barkpark API; it defaults to `https://guerrilla.barkpark.cloud`.

The daily GitHub workflow verifies all payloads and publishes when the repository secret `BARKPARK_INGEST_TOKEN` exists. Missing credentials produce a warning and skip the external write. Before each POST, the publisher reads the current Paper and skips it when `source_doc` already carries the same deterministic source digest, so an 18-month refresh normally writes only the current editions.

Monthly chapters add weekly cadence, six leading product areas, eight product-facing signals, ten fresh mainline events, and a 40-entry bounded source ledger. The Chronicle index links every generated month newest-first, with change counts, product-facing counts, and the leading area.

Because monthly chapters deliberately form a repeated editorial series, their payloads persist `dedup_bypass: true`. Their non-overlapping calendar key and deterministic Git source digest are the stronger identity boundary; the explicit flag prevents the general-purpose near-duplicate wall from confusing two adjacent months while leaving an audit trail on every chapter.

Every generated block is owned by an `auto:` ID. This MVP intentionally does not create `editorial:` blocks or merge human edits; that protected editorial overlay is the next delivery slice.
