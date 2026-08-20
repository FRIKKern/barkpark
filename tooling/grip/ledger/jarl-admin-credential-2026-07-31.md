# jarl-admin-credential — minting an ADMIN token for jarl.barkpark.cloud and proving `schema apply`

Run live 2026-07-31 from this Mac against instance `9fb839d6-9a4a-4c2f-b837-672e2bb97e9c`
(name `jarl`, team `506f035e-08f4-4b49-9038-86735eb4c0ef` / Guerrilla, host 91.98.139.58).
Every line is a re-derivation recipe. RESULT: **admin is obtainable and `schema apply`
works.** The "bp reaches jarl at auth_tier none with no schema verb" reading was an
artifact of running unauthenticated — not a platform limit.

## The four commands, in order

    # 1. find the instance id (already known, but this is the source)
    bp barkparks -o json | python3 -c "import json,sys;print([b for b in json.load(sys.stdin)['barkparks'] if b['name']=='jarl'])"

    # 2. MINT/RETRIEVE the per-instance admin token (owner-only, control-plane read)
    bp instance credentials 9fb839d6-9a4a-4c2f-b837-672e2bb97e9c -o json
    # -> {"admin_token":"bp_admin_…","host":"91.98.139.58","id":"9fb839d6-…","url":"https://jarl.barkpark.cloud"}

    # 3. PERSIST it as a saved server named `jarl` (writes ~/.config/barkpark/config.json)
    bp setup --target connect --server https://jarl.barkpark.cloud --name jarl \
      --token "$ADMIN_TOKEN" --yes -o json
    # -> {"ok":true,"tier":"admin",…}   (--dry-run first: destructive=false, one step)

    # 4. from then on, every verb takes `-s jarl`
    bp -s jarl schema ls -o json

`bp instance credentials` RETRIEVES the token the platform minted on the box at
provision time and decrypts it for the owner — it does not rotate. Re-running it
returns the same value, so step 2 is the durable recovery path if config.json is lost.

## Two traps that cost time

* **`bp use <url>` does NOT work for a new server.** It only switches among ALREADY
  known names: `{"error":{"code":"not_found","known":["Guerrilla"],"message":"no known
  server matches https://jarl.barkpark.cloud"}}`. `bp setup --target connect` is the
  only non-SSH verb that ADDS one. (`bp register`/`bp attach` want `root@host` over SSH
  and record no token.) There is no `bp server` command despite the built-ins list.
* **zsh does not word-split unquoted parameters.** `J="-s url --token tok"; bp $J schema ls`
  fails with `unknown command "-s https://… --token …"` and exit 2 — which looks exactly
  like "the schema verb does not exist". Write the flags out, or use `-s jarl`.

## Proof of tier and of write access

    bp -s jarl capabilities | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['server']['base_url'],d['auth_tier'])"
    # -> https://jarl.barkpark.cloud admin

    bp -s jarl schema ls -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['datasetSchemaHash'],len(d['schemas']))"
    # -> ed7f5428f5b120b3 47

Read access is not enough for the wave — the wave needs `schema apply`. Proven by
applying a throwaway type and deleting it (reversible, touches no existing type):

    echo '{"name":"zzVerifyProbe","title":"ZzVerifyProbe","type":"document","fields":[{"name":"title","title":"Title","type":"string"}]}' > /tmp/probe.json
    bp -s jarl schema apply --file /tmp/probe.json --yes -o json
    # -> {…,"id":"zzVerifyProbe","schemaHash":"f819b6cdcae9c5b3","visibility":"public"}
    bp -s jarl schema delete zzVerifyProbe --yes -o json
    # -> {"deleted":"zzVerifyProbe"}

After the delete the dataset hash returned to **ed7f5428f5b120b3 / 47 schemas** — byte
identical to before the probe. Nothing was left behind.

## Scope: the jarl-website content lives in default/default/production

    bp -s jarl workspace ls -o json        # -> one workspace, slug "default"
    bp -s jarl workspace project-ls -o json # -> one project, slug "default"
    bp -s jarl dataset stats -o json       # -> recent: project-doey, project-galleryspace, project-nextgen…

Export census (42 docs): project 14, post 9, page 4, author 3, category 3, tag 3,
paper 2, siteSettings 1, navigation 1, colors 1, note 1.

## The rollback the survey said did not exist

Taken 2026-07-31 into **/Users/frikkjarl/barkpark-backups/jarl-schema-backup/** (kept
OUTSIDE any repo checkout deliberately — see below):

    bp -s jarl schema get page    -o json > schema-page.json     # page    hash 1a6b7ea628090a7e
    bp -s jarl schema get project -o json > schema-project.json  # project hash d7eb26442ef4360f
    bp -s jarl schema ls          -o json > schema-ls-all.json   # all 47, dataset hash ed7f5428f5b120b3
    bp -s jarl export                     > export-production.ndjson  # 42 docs, 49251 bytes

`page.sections[].kind` today = **split | timeline | featureGrid | callout | quote | steps**
(select options, one composite `section` with `surface`, `overline`, `title`, `body`,
`attribution`, `ctaLabel`, `ctaHref`, `items[]{overline,title,body}`). `project` carries
the same `sections` array plus `tags`, `url`, `order`, `featured`. Any new figure kind is
an ADD to that options list plus new sibling fields on the same composite — one
`schema apply` per type, both types, since page and project each own their own copy.

The brief asked for this dump under `barkpark/tooling/jarl-schema-backup/`. That is a
repo write outside this agent's carve-out (ledger rows only), so it was written to the
durable non-repo path above instead. To land it in the repo, Decide runs:

    mkdir -p barkpark/tooling/jarl-schema-backup
    cp /Users/frikkjarl/barkpark-backups/jarl-schema-backup/* barkpark/tooling/jarl-schema-backup/

**Do not commit `export-production.ndjson` or any file carrying `bp_admin_…` without
checking first** — the export is content only (no token), but re-derived dumps should be
grepped for `bp_admin_` before staging.

## Local state left behind

* `~/.config/barkpark/config.json` gained a `known_servers` entry `jarl` (tier admin,
  w=default p=default d=production) carrying the admin token.
* The ACTIVE server was restored to `Guerrilla` afterwards, so sibling sessions sharing
  this machine are unaffected. Always pass `-s jarl` explicitly.
* Pre-change backup: `~/.config/barkpark/config.json.bak-preverify-20260731`.

## Still untested

* Whether the jarl box's Studio UI renders a newly-applied composite `select` option
  without a redeploy (only the API was exercised).
* Whether `bp instance credentials` works for a team OTHER than the active one without
  `--team` (the help says a non-active team 404s; jarl is in the active team, so this
  path was never hit).
