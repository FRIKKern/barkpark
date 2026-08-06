# Re-derivation recipes — census 403 / dr-w1-s6 (2026-08-06)

Verifier: deploy-reliability wave 2, assignment `census-403-blocks-s6`.
Every row below re-derives a claim from scratch. Nothing here is a summary.

## R1 — bp's cloud session token AUTHENTICATES against the operator surface; it only fails the allowlist

    TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])")
    curl -s -o /dev/null -w 'real=%{http_code}\n' -H "Authorization: Bearer $TOK" 'https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-07'
    curl -s -o /dev/null -w 'bogus=%{http_code}\n' -H "Authorization: Bearer bogus_nonsense_token" 'https://api.barkpark.cloud/v1/operator/deploy-ledger/census'
    curl -s -o /dev/null -w 'none=%{http_code}\n' 'https://api.barkpark.cloud/v1/operator/deploy-ledger/census'

Expected: real=403, bogus=401, none=401. 403 ≠ 401 is the whole finding — authentication
succeeds, authorization (email ∈ allowlist) is what fails. No second auth arm is needed.

## R2 — the same token is a real, healthy principal, and prod says platform_operator:false

    curl -s -H "Authorization: Bearer $TOK" 'https://api.barkpark.cloud/v1/me'

Expected: HTTP 200, `"email":"frikk@guerrilla.no"`, `"platform_operator":false`.
`/v1/me`'s boolean is derived from the SAME list the gate reads
(router.ex:1358 vs auth.ex:338), so it is a free, unprivileged probe of whether an
env fix has landed — no restart-log reading required.

## R3 — the gate's only pass condition, on origin/main

    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '333,341p'
    git show origin/main:cloud/config/runtime.exs | sed -n '338,344p'
    git show origin/main:cloud/docker-compose.yml | sed -n '59,67p'

`conn.assigns.current_user.email in Notifications.platform_admin_emails()`, fed by a
BARE compose passthrough line (`- PLATFORM_ADMIN_EMAILS`). Bare passthrough means the
value must be in the HOST env / `/opt/barkpark/cloud/.env` at container-create time;
setting it in `.env` without recreating the container leaves the container blind.

## R4 — the ledger test suite at origin/main (local main is 460 commits behind; the file does not exist locally)

    git worktree add --detach /tmp/wt-origin-main origin/main
    cd /tmp/wt-origin-main/cloud
    CC=clang mix deps.get
    CC=clang MIX_ENV=test MIX_TEST_PARTITION=vwt mix ecto.create
    CC=clang MIX_ENV=test MIX_TEST_PARTITION=vwt mix ecto.migrate
    CC=clang MIX_TEST_PARTITION=vwt mix test test/barkpark_cloud/deploy_ledger_test.exs

Expected: `28 tests, 0 failures`. The decisive case is
"no session → 401; a non-operator session → 403" — it drives a real `login_token(user)`
through the router with `platform_admin_emails` set to `[]` and asserts 403, then the
next test sets `[user.email]` and asserts 200. The login token is ACCEPTED by the arm;
only list membership decides.

## R5 — the census payload's exact key set (nobody had read class_rows/2 or site_rows/2)

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | awk '/def census\(/,/^  end/'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '/defp class_rows/,/^  end/p'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '/defp site_rows/,/^  end/p'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '/def rate(/,/^  end/p'

The router does `json(conn, 200, DeployLedger.census(from, to))` — no serializer, so the
atom map IS the wire shape.

## R6 — the census reconstructed from a plain TEAM token, no operator gate at all

    D=/tmp/dep; mkdir -p $D
    curl -s -H "Authorization: Bearer $TOK" 'https://api.barkpark.cloud/v1/sites' > $D/sites.json
    python3 - "$TOK" "$D" <<'PY'
    import json,sys,subprocess,collections
    tok,D=sys.argv[1],sys.argv[2]
    sites=json.load(open(D+"/sites.json"))["sites"]
    tot=collections.Counter(); cls=collections.Counter()
    for s in sites:
        out=subprocess.run(["curl","-s","-H","Authorization: Bearer "+tok,
          f"https://api.barkpark.cloud/v1/sites/{s['id']}/deployments?limit=200"],capture_output=True).stdout
        d=json.loads(out)["deployments"]
        tot.update(x["status"] for x in d)
        cls.update(x.get("failure_class") for x in d if x["status"]=="failed")
        print(f"{s['slug']:28s} n={len(d):4d}")
    print("status:",dict(tot)); print("failure_class:",dict(cls))
    PY

`failure_class` is LIVE on the team-scoped payload today. Five sites return exactly
n=200 — that is the page cap, not a total; a full walk needs the `?before=` cursor.

## R7 — TRAP: do not measure control bytes with `echo "$var"` in zsh

    # WRONG — zsh's builtin echo expands  and MANUFACTURES the control byte:
    out=$(curl -s ... ); echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'
    # → JSONDecodeError: Invalid control character
    # RIGHT — never round-trip through echo:
    curl -s ... > /tmp/x.json; python3 -c 'import json;b=open("/tmp/x.json","rb").read();
    print(sum(1 for c in b if c<0x20)); json.loads(b)'

Measured correctly: ZERO raw control bytes across all 13 sites' payloads, and every
payload strict-parses. An "invalid JSON / raw ANSI on the wire" finding derived the
first way is an artifact of the measuring shell, not a server defect.
