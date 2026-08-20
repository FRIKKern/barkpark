# w29 — is the D307 filing door live on guerrilla, and which shape may Decide use?

Re-derivation recipes. All run against the live filing server
(`https://guerrilla.barkpark.cloud`), token from `~/.config/barkpark/config.json`.

```sh
TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
```

## 1. The guard IS deployed — off-vocabulary surface is refused 422 at birth

```sh
bp task create --title 'probe (delete me)' \
  --set parent_id=cloud-console-hardening-epic \
  --set 'surface=cloud control plane — probe' -o json
# => bp: task create: task content failed validation — surface: cannot be filed
#    under "cloud-console-hardening-epic" as "cloud control plane — probe" …
```

Raw form (shows the HTTP status):

```sh
curl -s -w '\nHTTP=%{http_code}\n' -X POST \
  https://guerrilla.barkpark.cloud/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"mutations":[{"create":{"_id":"probe-a","_type":"task","kind":"task","lifecycle_status":"open","parent_id":"cloud-console-hardening-epic","surface":"off vocab prose","title":"probe"}}]}'
# => HTTP=422, code validation_failed, details.surface = the birth_surface_term_error text
```

## 2. Shapes that LAND

```sh
bp task create --title 'probe B' --set parent_id=cloud-console-hardening-epic -o json          # surface OMITTED -> draft created
bp task create --title 'probe C' --set parent_id=cloud-console-hardening-epic --set surface=console -o json   # -> draft created
```

## 3. The bypass: create bare, PATCH the surface, PUBLISH — off-vocab lands published

```sh
curl -s -X POST https://guerrilla.barkpark.cloud/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"mutations":[{"patch":{"id":"<task-id>","type":"task","set":{"surface":"cloud control plane — probe","description":"…","tags":[{"tag":"protective-tests","strength":90,"rationale":"…"},{"tag":"docs","strength":40,"rationale":"…"}]}}}]}'
curl -s -X POST … -d '{"mutations":[{"publish":{"id":"<task-id>","type":"task"}}]}'   # => 200
curl -s "https://guerrilla.barkpark.cloud/v1/data/doc/production/task/<task-id>" -H "Authorization: Bearer $TOKEN"
# => "surface":"cloud control plane — probe" on the PUBLISHED row under the epic
```

Code reason: both call sites pass `prev_doc`, and the clause head-matches
`nil = _prev_doc` (`git show origin/main:api/lib/barkpark/content/writer.ex | sed -n '872p'`).

## 4. Raw create WITHOUT `brief` → HTTP 500 `internal_error` / "unknown error"

Same body as §1 minus `"brief"` returns 500 with message `unknown error`, not a
422 naming the missing field. Adding a `brief` block makes the identical body
return 200.

## 5. Nothing reads `content.surface`

```sh
git grep -n 'content\.surface\|content\["surface"\]' origin/main            # 1 hit: writer.ex:890, the guard's own log string
git show origin/main:api/lib/barkpark/tasks/schema.ex | grep -c '^.*field.*surface'   # 0 — no schema field
```

## Cleanup used by the probes

```sh
curl -s -X POST … -d '{"mutations":[{"delete":{"id":"<id>","type":"task"}}]}'
curl -s -X POST … -d '{"mutations":[{"discardDraft":{"id":"<id>","type":"task"}}]}'
gh issue close <n>   # a published task mints a GitHub issue; probes leave one behind
```
