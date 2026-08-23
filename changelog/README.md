<!-- doc-tier: human | canonical-for: chronicle-paper-generator | budget: 700tok -->
# Barkpark Chronicle

The Chronicle is Barkpark's living changelog rendered as native Papers. The MVP scans first-parent Git history once and projects the selected UTC date into five stable documents:

- `/papers/barkpark-chronicle`
- `/papers/barkpark-changelog-YYYY-MM-DD`
- `/papers/barkpark-changelog-YYYY-wWW`
- `/papers/barkpark-changelog-YYYY-MM`
- `/papers/barkpark-changelog-YYYY`

Generate today's payloads locally:

```sh
python3 scripts/chronicle-paper.py --ref HEAD --output-dir /tmp/barkpark-chronicle
```

Generate another UTC date or inspect one lens on stdout:

```sh
python3 scripts/chronicle-paper.py --date 2026-08-23 --ref HEAD --only week
```

Publish all five through the existing Bulldocs ingest route:

```sh
BARKPARK_INGEST_TOKEN=… python3 scripts/chronicle-paper.py --ref HEAD --publish
```

`BARKPARK_API_URL` optionally selects another Barkpark API; it defaults to `https://guerrilla.barkpark.cloud`.

The daily GitHub workflow verifies all payloads and publishes when the repository secret `BARKPARK_INGEST_TOKEN` exists. Missing credentials produce a warning and skip the external write. Before each POST, the publisher reads the current Paper and skips it when `source_doc` already carries the same deterministic source digest.

Every generated block is owned by an `auto:` ID. This MVP intentionally does not create `editorial:` blocks or merge human edits; that protected editorial overlay is the next delivery slice.
