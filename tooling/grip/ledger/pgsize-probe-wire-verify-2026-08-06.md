# pgsize-probe-wire — re-derivation recipes (verify round, 2026-08-06)

Wave: deploy-reliability-wave-2026-08-06 · assignment `[pgsize-probe-wire]`.
Every row below is a command that re-derives one fact from scratch. Nothing here
was committed by the verifier; Decide commits this file.

## 1. The probe is declared and never wired (repo, origin/main)

    git show origin/main:internal/agent/report.go | grep -n 'PGSize'
    git show origin/main:cmd/barkpark-agent/main.go | grep -n 'PGSize'   # exit 1 — zero hits

Report.go declares `PGSizeProbe` (:187), folds it at :261-263, defaults
`PGSizeBytes: -1` (:211). main.go wires Disk/CPU/Mem/Load/ReqStats and NOT PGSize.

## 2. The meter reads "unmetered" against a 3.48 GB live database

    bp cloud usage guerrilla | python3 -m json.tool | grep -A3 db_size
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'sudo -u postgres psql -tAc "SELECT pg_database_size(current_database())" barkpark_prod'

## 3. Probe cost (guerrilla, live)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'time sudo -u postgres psql -tAc "SELECT pg_database_size(current_database())" barkpark_prod'
    # per-relation breakdown, same order of cost:
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "cat >/tmp/relsz.sql <<'EOF'
    SELECT relname, pg_total_relation_size(c.oid) AS bytes
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','m')
    ORDER BY 2 DESC LIMIT 10;
    EOF
    time sudo -u postgres psql -tAF'|' -f /tmp/relsz.sql barkpark_prod"

## 4. No dormant threshold keys on db_size

    grep -n 'db_size_meter' -A6 cloud/lib/barkpark_cloud/usage.ex   # meter/3 arity — quota/warn_at/over_at all default nil
    grep -rn 'over_at\|warn_at' cloud/lib/barkpark_cloud/ | grep -v usage.ex   # zero hits
    sed -n '15204,15220p' cloud/priv/static/app.js                  # hasThreshold false → state null → no tint
    grep -rni 'db_size\|storage_limit\|db_limit' cloud/lib/barkpark_cloud/billing*   # zero hits

## 5. Credential path for an on-box probe (guerrilla only — proven there)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'set -a; . /opt/barkpark/.env; set +a; psql "$(printf %s "$DATABASE_URL" | sed s#^ecto://#postgres://#)" -tAc "SELECT pg_database_size(current_database())"'

`psql` as root fails (`role "root" does not exist`); the checkout `.env`
DATABASE_URL rewritten `ecto://` → `postgres://` succeeds. NOT verified on the
other five fleet boxes (ssh host-key mismatch, not investigated).

## 6. Cross-surface vocabulary fixture does not pin values

    cat cloud/priv/static/__fixtures__/usage_meters.json    # names + labels only
    grep -rn 'usage_meters.json' cloud/test internal/cli cloud/priv/static/__app.test.mjs
