<!-- doc-tier: human | canonical-for: scaffy-seed-loop | budget: none -->
# scaffy/seed — corpus → published `command` documents

`go run ./scaffy/seed` derives one flat JSON payload per
`scaffy/commands/*.scaffy` file (validate → parse → derive, refusing the
whole run on ANY `scaffy.ValidateFile` finding) into `scaffy/seed/out/`
(gitignored — payloads are derived; the `.scaffy` files are the truth).

Fields per payload (charter D46/D47): `_id = <domain>--<concept>--<variant>`
(concept alone is NOT unique — the docs-card add/remove pair shares one),
`title`/`description`/`concept`/`variant`/`domain`/`direction` from the
header, `tags` = the TAGS list as weighted entries with distinct descending
strengths (90, 80, 70, …), and `source` = the raw file bytes verbatim.

## The seed loop

Run against the configured server (`~/.config/barkpark/`; needs a token that
may write + publish):

```sh
go run ./scaffy/seed
for f in scaffy/seed/out/*.json; do
  id=$(basename "$f" .json)
  bp doc create-or-replace command --file "$f" --yes
  bp doc publish command "$id" --yes
done
```

Publishing matters: anonymous reads serve the PUBLISHED perspective, so an
unpublished command is invisible to the one-connect pull
(`GET /v1/data/query/production/command`).

The loop is idempotent — `createOrReplace` is an upsert by `_id`, so a
re-run leaves exactly the same document set (revs bump, zero duplicates).

## `unknown_tag` on publish (the E3 wall)

`bp doc publish` 422s with `unknown_tag` when any weighted-tag name does not
resolve to a PUBLISHED `type:tag` document in the dataset. The remediation
is to register the missing tag first — the house pattern is a tag doc whose
`_id` IS the tag name — then retry the publish:

```sh
bp doc create-or-replace tag \
  --set _id=<name> --set title="<Title>" \
  --set description="<one honest sentence>" --yes
bp doc publish tag <name> --yes
```

## Re-seed after amend (the law) + `--check` audit

**Any PR that touches `scaffy/commands/*.scaffy` must re-seed the touched
commands** — the served `command` document's `source` is a byte copy, so an
un-re-seeded edit silently drifts the catalog from the repo. (This happened:
the W7 prose-amendment PR merged without re-seeding, and `add-block-type` +
`classify-block-type` served stale for a tick.) Re-run the seed loop above for
the edited ids, or the whole loop — it is idempotent.

`--check` is the audit that catches the miss:

```sh
go run ./scaffy/seed --check
```

It derives every payload **in memory** (no `out/` writes), fetches the served
catalog tokenless
(`GET <server>/v1/data/query/production/command?limit=100` — `server` from
`~/.config/barkpark/config.json` if present, else `guerrilla.barkpark.cloud`),
and compares `sha256(source)` per command id. It prints a table
(`id · local sha8 · served sha8 · MATCH/DRIFT/MISSING/EXTRA`) and **exits
nonzero on any non-MATCH**:

- **MATCH** — repo byte-identical to served.
- **DRIFT** — both present, bytes differ → the command was edited without a
  re-seed. Re-seed it.
- **MISSING** — in the repo, never seeded → run the seed loop for it.
- **EXTRA** — served with no local corpus file → a stale document to retire.

It fails **loud** on any network error (unreachable host, non-200, bad JSON): a
check that cannot reach the catalog exits nonzero, never a false green. Run it
in seconds from any session; CI runs it as an ACTING post-merge gate
(.github/workflows/scaffy-catalog-drift.yml, charter D100).

### Repairing drift from CI

The gate DETECTS drift on every trigger (push to main, the daily cron, and
dispatch) and reds hard on it. It only WRITES on a manually dispatched run that
opts in: **Actions → scaffy-catalog-drift → Run workflow → repair = true**,
with `BARKPARK_SEED_TOKEN` installed.

The write is deliberately withheld from unattended runs. The repair logic had
executed zero times across the workflow's first twelve runs — every red stopped
at the credential guard and every green skipped the step — so wiring the secret
to a cron would have promoted never-executed shell to an unattended writer
against production content, with its first execution and its first evidence in
the same 06:17 UTC event.

That logic now lives in `repair.sh` rather than inline in the workflow,
precisely so it can be tested: `repair-selftest.sh` drives it against a local
fixture server on every run of the gate and asserts four arms — the happy path
posts one atomic `createOrReplace` + `publish` batch per id, the E3
`unknown_tag` wall is cleared by registering tag docs and the retry succeeds, a
refused write reds instead of being swallowed, and an empty drifted-id list is
an error rather than a silent success. Zero egress, zero credentials, so it
runs anywhere:

```
bash scaffy/seed/repair-selftest.sh
```
