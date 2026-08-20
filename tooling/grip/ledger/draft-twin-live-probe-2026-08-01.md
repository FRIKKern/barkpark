# draft-twin-live-probe — re-derivation recipes (PDS wave 33 VERIFY, 2026-08-01)

Lane `draft-twin-live-probe`: is WRONG-ROW a real fifth failure mode on LIVE guerrilla —
does `/v1/data/mutate` return `200` + a fresh `rev` for a patch on a PUBLISHED task while
every canonical reader still serves the OLD row, does the success envelope warn, and how
many task rows carry both `<slug>` and `drafts.<slug>` right now?

Everything below was RUN against `https://guerrilla.barkpark.cloud` on 2026-08-01, or reads
`origin/main`. Probe doc `pds-w33-probe-wrongrow-1785558064` was created, measured, and
DELETED (both rows → 404); its GitHub mirror issue FRIKKern/barkpark#8761 was closed.

Shell prelude used by every live row:

    TOK=$(jq -r .token ~/.config/barkpark/config.json); B=https://guerrilla.barkpark.cloud

| # | Claim | Command |
|---|---|---|
| 1 | `/v1/data/mutate/production` is reachable and accepts an empty batch: `mutate_reachable=200` | `curl -s -o /dev/null -w 'mutate_reachable=%{http_code}\n' -X POST "$B/v1/data/mutate/production" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"mutations":[]}'` |
| 2 | A `patch` naming the BARE published id returns HTTP 200 with `results[0].id = "drafts.<id>"`, `document._draft = true` and a FRESH `_rev` — the write landed on the draft twin, not the row the caller named | `curl -s -w '\nHTTP=%{http_code}\n' -X POST "$B/v1/data/mutate/production" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"mutations":[{"patch":{"id":"<PUBLISHED_TASK_ID>","type":"task","set":{"description":"PROBE"}}}]}'` |
| 3 | Reader A — `GET /v1/data/doc/production/task/<bare-id>` still serves the PRE-PATCH `_rev` and description | `curl -s "$B/v1/data/doc/production/task/<ID>" -H "Authorization: Bearer $TOK" \| jq -c '{_id:.result._id,_rev:.result._rev,description:.result.description}'` |
| 4 | Reader B — `GET /v1/tasks/<bare-id>` (the ledger route: claim/stamp/close/ready all key off it) also serves the PRE-PATCH `rev` and `content.description` | `curl -s "$B/v1/tasks/<ID>" -H "Authorization: Bearer $TOK" \| jq -c '{rev:.doc.rev,desc:.doc.content.description,status:.doc.status}'` |
| 5 | The mutate SUCCESS envelope emits NO warning about the twin fork — `warnings` is absent/null on the receipt | `… \| jq -c '.warnings'` (row 2's request) |
| 6 | Structurally: `api/lib` has exactly FOUR `Warnings.put` emit sites — authoring_wall (x2 + relay), `patch.content_nested`, bulldocs `body_html_learn`. NONE is twin-related | `git grep -n "Warnings.put" origin/main -- api/lib` |
| 7 | `get_patch_base/4` reads the DRAFT first and `Writer.upsert_document` always draft-prefixes the write target — the mechanism, stated in its own doc comment | `git show origin/main:api/lib/barkpark/content/mutations.ex \| sed -n '622,640p'` |
| 8 | Staleness window is NOT bounded by D334's "5–40 s": measured 42–52 s in a curl-only phase (patch 04:25:29, still stale 04:26:11, converged by 04:26:21) | patch, then `for i in $(seq 1 9); do date -u +%H:%M:%S; curl -s "$B/v1/data/doc/production/task/<ID>" -H "Authorization: Bearer $TOK" \| jq -rc '.result._rev[0:8]+":"+.result.description[0:24]'; sleep 10; done` |
| 9 | The convergence is the GitHub bridge's `Link.put/4` draft-collapse, not a general reconciler — the deleted probe doc carried `content.github.issue = 8761`, i.e. `MirrorJob` had mirrored it | delete the probe and read the returned envelope: `curl -s -X POST "$B/v1/data/mutate/production" … -d '{"mutations":[{"delete":{"id":"<ID>","type":"task"}}]}' \| grep -o '"github":{[^}]*}'` |
| 10 | ⇒ a mutate-patched task that the GitHub bridge does NOT mirror is forked FOREVER; `Link.put` collapses only when a published row pre-existed and the collapse publish is not REJECTED | `git show origin/main:api/lib/barkpark/plugins/github/link.ex \| sed -n '30,52p;104,120p'` |
| 11 | Census (paged — `limit` silently caps at 1000, per PDS-D335): 4,556 `type:task` rows raw; 357 `drafts.`; 4,199 published; **22 twins**, 335 draft-only, 4,177 published-only | `for off in 0 1000 2000 3000 4000; do curl -s "$B/v1/data/query/production/task?perspective=raw&limit=1000&offset=$off" -H "Authorization: Bearer $TOK" \| jq -r '.result.documents[]._id'; done > ids.txt; grep '^drafts\.' ids.txt \| sed 's/^drafts\.//' \| sort -u > d.txt; grep -v '^drafts\.' ids.txt \| sort -u > p.txt; comm -12 d.txt p.txt \| wc -l` |
| 12 | **12 of the 22 twins DIVERGE on `lifecycle_status`** — draft `open` vs published `done`/`cancelled`; the draft is NEWER on all 22. Includes this epic's own `pds-w29-s3-fake-fails-closed`, `pds-w27-census-self-honesty`, `pds-bl-tagregistry-guard-no-rung` | `comm -12 d.txt p.txt \| while read s; do for i in "drafts.$s" "$s"; do curl -s "$B/v1/data/doc/production/task/$i" -H "Authorization: Bearer $TOK" \| python3 -c 'import sys,json;r=json.load(sys.stdin,strict=False).get("result") or {};print(r.get("lifecycle_status"),r.get("_updatedAt"))'; done; echo "$s"; done` |
| 13 | jq CANNOT parse several live task envelopes (`Invalid string: control characters from U+0000 through U+001F`) — 6 of 22 twins were invisible to a jq-based census and a naive pipeline would silently undercount. Use `python3 json.loads(..., strict=False)` | row 12 with `jq` substituted for the python reader |
| 14 | The publish wall SENDS structured `details` on refusal (`label_spine` → `{field, rule, fix}`; `unknown_tag` → `{unknown, suggestions}`) — the server is not the blind party | `curl -s -X POST "$B/v1/data/mutate/production" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"mutations":[{"createOrReplace":{"_type":"task","_id":"x","title":"t","description":"…","kind":"task","lifecycle_status":"open"}},{"publish":{"id":"x","type":"task"}}]}'` |
| 15 | The ready queue reads the PUBLISHED row by design (twin collapse, published-wins) — so a mutate-patch is invisible to `bp task ready` until the collapse | `git show origin/main:api/lib/barkpark/tasks/queue.ex \| sed -n '10,20p;144,152p'` |
