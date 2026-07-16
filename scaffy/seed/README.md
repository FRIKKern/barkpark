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

## Verifying byte parity

After seeding, the served `source` must be byte-identical to the repo file:
compare `sha256(source)` from the tokenless query with `sha256` of the local
`.scaffy` for all seven — the seeder prints the local hashes on emission.
