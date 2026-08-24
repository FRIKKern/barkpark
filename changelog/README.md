<!-- doc-tier: human | canonical-for: chronicle-paper-generator | budget: 700tok -->
# Barkpark Chronicle

The Chronicle is Barkpark's living changelog rendered as native Papers. One first-parent Git scan projects the selected UTC date into the index plus every calendar day, ISO week, month, and year since the first recorded change. Quiet days are explicit Papers, never missing pages.

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

Add the token-backed editorial review locally with the authenticated Claude CLI:

```sh
python3 scripts/chronicle-paper.py --ref HEAD --history-months 0 \
  --editorial-provider claude --output-dir /tmp/barkpark-chronicle-editorial
```

For a deliberate full-archive rewrite, add `--full-history --editorial-all`. Active periods are reviewed in bounded batches; quiet periods keep deterministic copy.

The editorial pass is additive. Git remains the system of record for dates, counts, navigation, media evidence, links, and the complete ledger. The review turns an active period into a concrete headline, plain summary, up to three source-cited stories, and an honest assessment. Every model story must cite supplied commit references; prose that
introduces unsupported numeric, customer, financial, adoption, deadline, or
guarantee claims is rejected. Invalid or unavailable model output falls back to
a deterministic review without blocking the changelog.

Publish the complete archive through the existing Bulldocs ingest route:

```sh
BARKPARK_INGEST_TOKEN=… python3 scripts/chronicle-paper.py --ref HEAD --full-history --publish
```

`BARKPARK_API_URL` optionally selects another Barkpark API; it defaults to `https://guerrilla.barkpark.cloud`.

The daily GitHub workflow verifies and publishes the complete archive when `BARKPARK_INGEST_TOKEN` exists. It updates the current family and index, creates missing history, and preserves existing historical reviews. With
`ANTHROPIC_API_KEY`, the family receives one source-grounded editorial pass;
without it, publishing continues with the deterministic review. Historical
editions remain stable at their last published review instead of being
rewritten every morning. The scheduled run reviews the completed previous UTC
day, which also closes or advances its containing week, month, and year; a
manual dispatch may select another date. Generation filters the ledger through
that date so a backdated index cannot leak later work. Before each POST, the publisher compares the
deterministic `source_doc`, so an unchanged edition costs one read and no write.

Every annual Paper links its months; every month links its touching weeks and every day; every week links its days. The index contains a complete calendar, so every generated Paper is reachable from the front door. Changed screenshot and cast assets become native `figure` or `asciicast` evidence with commit provenance; editions without real media stay text-only. `paper-links` recommendations resolve current published Paper details in the reader and retain useful fallback links in email and TUI.

Because Chronicle editions form repeated editorial series, every period payload persists `dedup_bypass: true`. Its non-overlapping calendar key and Git digest are the stronger identity boundary, while the flag leaves an explicit audit trail for the near-duplicate exemption.

Every generated block is owned by an `auto:` ID. The model supplies validated
copy fields, never document structure, URLs, counts, identity, or publishing
behavior. A protected human-edit overlay remains a future delivery slice.
