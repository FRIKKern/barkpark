<!-- doc-tier: human | canonical-for: chronicle-paper-generator | budget: 700tok -->
# Barkpark Chronicle

The Chronicle is Barkpark's living changelog rendered as native Papers. One first-parent Git scan projects the selected UTC date into the index plus every active daily, ISO-weekly, monthly, and annual edition:

- `/papers/barkpark-chronicle`
- `/papers/barkpark-changelog-YYYY-MM-DD`
- `/papers/barkpark-changelog-YYYY-wWW`
- `/papers/barkpark-changelog-YYYY-MM`
- `/papers/barkpark-changelog-YYYY`

Generate the complete archive locally:

```sh
python3 scripts/chronicle-paper.py --ref HEAD --full-history --output-dir /tmp/barkpark-chronicle
```

For a smaller monthly-only refresh, choose an archive horizon:

```sh
python3 scripts/chronicle-paper.py --ref HEAD --history-months 36 --output-dir /tmp/barkpark-chronicle
```

Generate another UTC date or inspect one lens on stdout:

```sh
python3 scripts/chronicle-paper.py --date 2026-08-23 --ref HEAD --only week
```

Publish the complete archive through the existing Bulldocs ingest route:

```sh
BARKPARK_INGEST_TOKEN=… python3 scripts/chronicle-paper.py --ref HEAD --full-history --publish
```

`BARKPARK_API_URL` optionally selects another Barkpark API; it defaults to `https://guerrilla.barkpark.cloud`.

The daily GitHub workflow verifies and publishes the full archive when `BARKPARK_INGEST_TOKEN` exists. Missing credentials produce a warning and skip the write. Before each POST, the publisher compares the deterministic `source_doc`, so unchanged historical editions cost one read and no write.

Every annual Paper links its months; every month links its touching weeks and active days; every week links its active days. Monthly chapters also add weekly cadence, six leading areas, eight product-facing signals, ten fresh events, and a 40-entry source ledger. The index links every month newest-first.

Because Chronicle editions form repeated editorial series, every period payload persists `dedup_bypass: true`. Its non-overlapping calendar key and Git digest are the stronger identity boundary, while the flag leaves an explicit audit trail for the near-duplicate exemption.

Every generated block is owned by an `auto:` ID. This MVP intentionally does not create `editorial:` blocks or merge human edits; that protected editorial overlay is the next delivery slice.
