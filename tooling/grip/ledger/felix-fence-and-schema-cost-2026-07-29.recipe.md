# Re-derivation recipes — Felix fence + prebuilt schema cost (site-spawner wave 9, 2026-07-29)

Every row below is a single literal command that re-derives the fact from scratch.
Run from `/Volumes/SATECHI/github/barkpark`.

## Fence: does any in-flight work touch the four sites/ files?

```
gh pr list --state open --limit 100 --json number -q '.[].number' | while read n; do f=$(gh pr view $n --json files -q '.files[].path' | grep -E 'sites/|site_deploy|provisioner|deploy_request|deploy_runner' | tr '\n' ' '); [ -n "$f" ] && echo "PR#$n: $f"; done; echo SWEEP-DONE
```
Expected 2026-07-29: only `SWEEP-DONE` — zero of the open PRs touch them.

## Fence: was a Felix Wave 24 filed, and what is its scope?

```
bp search query "felix wave 24" -o json | head -c 400
bp paper view felix-pristine-wave-24-2026-07-29 > /tmp/w24.txt; grep -niE "provisioner|sites/|deploy_runner|deploy_request" /tmp/w24.txt; echo "GREP-EXIT=$?"
```
Expected: paper `felix-pristine-wave-24-2026-07-29` exists (STATUS OPEN, strategized
2026-07-29); the grep returns nothing (`GREP-EXIT=1`) across its 659 rendered lines.

## Fence: Felix epic children — no 2026-07-29 rows, no `w24` slugs

```
bp task get task-96a908af98698118 -o json | python3 -c "import json,sys;d=json.load(sys.stdin);ch=d['children'];print(len(ch));print([c['doc_id'] for c in ch if c.get('inserted_at','').startswith('2026-07-29')]);print([c['doc_id'] for c in ch if 'w24' in c['doc_id']])"
```
Expected: `122`, `[]`, `[]` — Wave 24 dispatches already-filed `felix-w23-bl-*`
backlog rows (`-fenced-sixteen`, `-s5-blobstore-migration`), it files no new children.
`bp` 500s intermittently; retry.

## The REAL Felix interaction: Sobelow traversal waivers in sites/

```
grep -n "sites" api/.sobelow-skips
grep -n "sobelow_skip" api/lib/barkpark/sites/*.ex
```
Expected: 5 baselined `Traversal.FileModule` rows on
`lib/barkpark/sites/provisioner.ex` (:151 :152 :158 :178 :214), and 10 inline
`sobelow_skip` annotations already migrated into `deploy_runner.ex` (by #6616).
`provisioner.ex` has ZERO inline annotations.

## Baseline gates

```
CC=clang go build ./... && echo GO-BUILD-OK
CC=clang go vet ./internal/cli/... ; echo VET-EXIT=$?
cd cloud && mix format --check-formatted; echo CLOUD-FMT-EXIT=$?
cd cloud && MIX_ENV=test mix compile --warnings-as-errors; echo CLOUD-COMPILE-EXIT=$?
cd cloud && MIX_ENV=test mix test test/barkpark_cloud/registry test/barkpark_cloud/sites test/barkpark_cloud/sites_deploy_test.exs
cd api && MIX_ENV=test mix test test/barkpark/sites test/barkpark_web/controllers/site_deploy_controller_test.exs
```
NOTE: `CC=clang` is required — the `cc` alias is a Claude wrapper, cgo fails with
`error: unknown option '-E'` without it.

NOTE: `cd api && mix format --check-formatted` FAILS LOCALLY on
`test/barkpark_web/controllers/tasks_controller_test.exs`. This is a formatter
VERSION artifact, not a main breakage: local Elixir is 1.19.5, `.tool-versions`
and both CI format jobs pin **1.18.1**. The api format job is also
`continue-on-error: true` (advisory) at `.github/workflows/elixir.yml:218`.
The cloud format job (`cloud.yml:63`) is BLOCKING and passes even on 1.19.5.

## Schema cost: the reference migration to mirror

```
git show origin/main:cloud/priv/repo/migrations/20260714150000_add_trigger_to_deployments_and_content_secret.exs
```
Note the schema lives in **cloud/**, not api/ — `api/priv/repo/migrations/20260714150000_*`
is `create_registered_chat_hosts`, an unrelated file with the same timestamp.

## Schema cost: every cast list a new column must be added to

```
git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex | grep -n "def .*changeset\|cast(attrs"
git show origin/main:cloud/lib/barkpark_cloud/registry/site.ex | grep -n "def .*changeset\|cast(attrs"
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5899,5906p'
```
`deployment.ex`: `changeset/2` AND `preview_changeset/2` (independent cast lists,
both carry `build_id`/`content_rev`) plus `transition_changeset/2`.
`site.ex`: `changeset/2` (create, 29 fields), `settings_changeset/2` (PATCH — casts
ONLY `[:theme, :doc_type]`), `runtime_changeset/2`, `cf_binding_changeset/2`.
THIRD choke point most estimates miss: the PATCH route hard-codes
`Map.take(["theme", "doc_type"])` in router.ex before the changeset ever runs.

## Schema cost: the two serializer choke points

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n "defp site_json\|defp deployment_json\|defp site_deployment_json\|defp deployment_with_site_json"
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c "site_json\|deployment_json"
```
`deployment_json/1` (router.ex:9776) is the SOLE base serializer —
`site_deployment_json/3` (:9827) and `deployment_with_site_json/1` (:9851) both
wrap it, so one line there reaches every deployment surface.
`site_json/1,2` (:9700/:9706) is the single site serializer.

## Schema cost: does a new field need a Go struct field?

```
grep -n "type SiteDeployment struct" -A 20 internal/cloudclient/client.go
grep -n "type Site struct" -A 20 internal/cloudclient/client.go
```
YES. Go's `json.Unmarshal` silently drops unknown keys — the codebase documents
this in the `Trigger` field comment at client.go:1403-1407 ("omitempty because the
control plane only started emitting it in wave 5 and Go's json.Unmarshal would
otherwise silently drop the unknown key"). There are TWO deployment structs:
`SiteDeployment` (spawned-site surface, :1415) and legacy `Deployment` (:1031).
