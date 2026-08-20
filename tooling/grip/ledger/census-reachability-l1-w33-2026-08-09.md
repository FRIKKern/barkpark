# Census reachability at L1 — re-derivation recipes (wave 33 verifier)

Every row below was RUN on 2026-08-09 against the deployed control plane. Copy-paste to re-derive.

## Which commit does the deployed control plane run?

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'cd /opt/barkpark && git log -1 --format="%H %cI" && git rev-parse HEAD:cloud'
    # → 5a11c43dbb901fbc1c374b39547a2d0dadf20bb9 2026-08-09T21:52:50+02:00
    #   f7b6a002969436496ebdd057a2ad567df5107bcb

    git rev-parse origin/main:cloud
    # → f7b6a002969436496ebdd057a2ad567df5107bcb   (IDENTICAL cloud/ tree)

    git log --oneline 5a11c43db..origin/main -- cloud/     # → empty

The container carries NO revision label; `Application.spec(:barkpark_cloud, :vsn)` is `~c"0.1.0"`
(constant, useless as an identifier). Commit identity is only derivable from the server checkout:

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker inspect -f "{{.Config.Image}} {{.State.StartedAt}} {{index .Config.Labels \"org.opencontainers.image.revision\"}}" cloud-control_plane_green-1'
    # → cloud-control_plane:latest 2026-08-09T19:58:42.005216938Z   (revision label EMPTY)

## The live census read (L1, real HTTP, non-operator credential)

    CT=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -w 'http=%{http_code} t=%{time_total}s\n' -H "Authorization: Bearer $CT" \
      'https://api.barkpark.cloud/v1/deploy-ledger/census?from=2026-07-10T00:00:00Z&to=2026-08-09T23:59:59Z'

`?days=30` is NOT a route parameter — it 422s `invalid_window` / "from is required".
The operator twin `/v1/operator/deploy-ledger/census` answers 403 to the same token; no auth → 401.

## The window-width latency curve (the exit-code trap)

    for D in 20 22 25 27 30; do
      FROM=$(python3 -c "import datetime;print((datetime.datetime.utcnow()-datetime.timedelta(days=$D)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
      TO=$(python3 -c "import datetime;print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")
      curl -s -o /tmp/s$D.json -w "days=$D http=%{http_code} t=%{time_total}s\n" --max-time 180 \
        -H "Authorization: Bearer $CT" "https://api.barkpark.cloud/v1/deploy-ledger/census?from=$FROM&to=$TO"
      python3 -c "import json;d=json.load(open('/tmp/s$D.json'));print([ (c['cohort'],c['never_covered'],c['never_covered_by_environment']) for c in d['coverage_cohorts']['cohorts']])"
    done

Measured: 20d→11.9s (nc=2 preview) · 22d→18.5s (nc=2) · 25d→35.5s · 27d→57.9s (nc=5 = 3 production + 2 preview) · 30d→36.9s.

## The CLI, built from origin/main (the installed one does not have the command)

    bp --version                       # → commit 0789ab90a
    bp cloud deployments -o table      # → exit 2, `unknown cloud command "deployments"`

    git archive origin/main | tar -x -C <scratch>/mainsrc
    cd <scratch>/mainsrc && CC=/usr/bin/clang go build -o <scratch>/bp-main ./cmd/barkpark
    <scratch>/bp-main cloud deployments --days 20 -o table ; echo "EXIT=$?"   # → 0, "2 NEVER COVERED"
    <scratch>/bp-main cloud deployments --days 30 -o table ; echo "EXIT=$?"   # → 1, context deadline exceeded
    BARKPARK_CLOUD_TOKEN=bogus <scratch>/bp-main cloud deployments --days 7   # → exit 3, honest 401 refusal text

`CC=/usr/bin/clang` is required — the `cc` shell alias shadows the compiler and cgo fails with `unknown option '-E'`.

The client cap is `cloudclient.DefaultTimeout = 30 * time.Second`
(`git show origin/main:internal/cloudclient/client.go | sed -n '41,44p'`); `FleetDeployCensus`
(`:2396`) installs no override, unlike `DomainStatusTimeout`/`VerifyTimeout` (90s).
