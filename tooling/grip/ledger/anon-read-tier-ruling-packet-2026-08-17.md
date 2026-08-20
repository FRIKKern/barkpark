# Anonymous read-tier ruling packet — re-derivation recipes (2026-08-17)

Verifier lane `anon-ruling-packet-and-tooling` of the API read-path security sweep
(wave paper `api-read-path-security-sweep-wave-2026-08-17`). Every row below is a
LIVE data state, not a code fact: re-run the command, do not quote this file as
current truth.

## 1. Per-host anonymous read census (no Authorization header)

    python3 - <<'EOF'
    import json,subprocess
    for h in ["http://89.167.28.206","https://guerrilla.barkpark.cloud","https://muscle-1.barkpark.cloud"]:
        d=json.loads(subprocess.run(["curl","-s","--max-time","25",h+"/api/schemas"],capture_output=True,text=True).stdout)
        ok=[]
        for t in [s["name"] for s in d]:
            c=subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","15",
                              f"{h}/v1/data/query/production/{t}?limit=1"],capture_output=True,text=True).stdout
            if c=="200": ok.append(t)
        print(h,"schemas",len(d),"anon-200",ok)
    EOF

Observed 2026-08-17:

| host | schemas in /api/schemas | anonymously readable types |
|---|---|---|
| http://89.167.28.206 (primary) | 47 | author, category, command, page, paper, place, post, project, tag, task |
| https://guerrilla.barkpark.cloud | 39 | command, metric, paper, tag, task |
| https://muscle-1.barkpark.cloud | 39 | command, metric, paper, tag, task |

Every non-public type answers `404 not_found` ("document not found") — fail-closed and
indistinguishable from a type that does not exist. `403` is NOT used on this path.

## 2. Anonymous corpus size (offset walk, fields=_id)

    python3 - <<'EOF'
    import json,subprocess
    for h,t in [("https://guerrilla.barkpark.cloud","task"),("https://guerrilla.barkpark.cloud","paper"),
                ("https://muscle-1.barkpark.cloud","task"),("https://muscle-1.barkpark.cloud","paper"),
                ("http://89.167.28.206","task"),("http://89.167.28.206","paper")]:
        tot=0;off=0
        while True:
            out=subprocess.run(["curl","-s","--max-time","60",
              f"{h}/v1/data/query/production/{t}?limit=1000&offset={off}&fields=_id"],capture_output=True,text=True).stdout
            n=len(json.loads(out)["result"]["documents"]); tot+=n; off+=1000
            if n<1000: break
        print(h,t,tot)
    EOF

Observed: guerrilla task 6181 / paper 774; muscle-1 task 3139 / paper 551;
primary task **0** / paper **15**. The primary's 15 papers are 2026-06 design docs
(`welcome`, `2026-06-07-barkpark-cli-handbook`, …), not the working ledger.

## 3. /api/schemas leaks private schema names + full field definitions

    curl -s https://guerrilla.barkpark.cloud/api/schemas | python3 -c '
    import json,sys
    for s in json.load(sys.stdin):
      if s["name"] in ("session","listener","ticket","mediaAsset"):
        print(s["name"], [f.get("name") for f in (s.get("fields") or [])])'

`session` is 404 on the anonymous data path yet its 13 field names ship anonymously
(`session_uuid, cwd, machine, git_head, git_branch, transcript, …`). Code root:
`/api/schemas` → `LegacyController.schemas` → `Content.list_schemas/2`, which has NO
visibility filter (`api/lib/barkpark/content/schema.ex:83`), unlike the token-gated
`/v1/schemas/:dataset` (`list_schemas_for_sdk`). Router
(`api/lib/barkpark_web/router.ex:2624-2631`) documents the route as intentionally
un-token-gated.

## 4. Register severity bound

    git show origin/main:api/lib/barkpark/accounts.ex | sed -n '28,36p'
    curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'content-type: application/json' \
      -d '{}' https://guerrilla.barkpark.cloud/v1/auth/register    # 400 = controller reached, no account created

`register_user/1` is an unconditional `User.registration_changeset |> Repo.insert` —
no invite code, no feature flag, no allowlist. Route rides `:user_auth`
(router.ex:1491-1495) whose only defence is `Plugs.RateLimit`. Bound: it inserts a
`User` row and sends a confirmation mail; it grants NO workspace membership and NO
token, so it is an unauthenticated row-insert + mail-send, not a read-tier escalation.

## 5. Tooling that breaks if `task` / `command` flip private

    grep -c 'Authorization\|Bearer' tooling/grip/seal.mjs scaffy/seed/main.go \
       tooling/pds/corpus.mjs .github/workflows/reland-check.yml

| consumer | type it reads anonymously | behaviour on a private flip |
|---|---|---|
| `tooling/grip/seal.mjs:164` | `task` | HARD FAIL — `runJson` throws `Infra` on any `json.error` (seal.mjs:146,157) |
| `scaffy/seed/main.go:433` | `command` | HARD FAIL — non-200 returns an error, caller wraps it "fail LOUD" (main.go:311-315) |
| `.github/workflows/reland-check.yml:66` | `task` | **SILENT** — `curl -sS` (no `-f`) succeeds on a 404 JSON body, `reland_check.py … \|\| true`, findings default to `0`. The advisory just stops firing. |
| `tooling/pds/corpus.mjs:101` | `task` | unaffected — sends `Authorization: Bearer ${token}` |

Docs/smoke surfaces that assume anonymity: `CLAUDE.md` smoke test and
`deploy/uptime-kuma/README.md:57-70` both curl `/v1/data/query/production/post`
tokenless (primary only — `post` is 404 on guerrilla/muscle-1).
