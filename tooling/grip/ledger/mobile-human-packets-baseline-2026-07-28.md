# mobile-human-packets-baseline — CONFIRMED 2026-07-28

Tree: origin/main @ ab396959c. Live: api.barkpark.cloud (control plane),
guerrilla.barkpark.cloud (instance).

## 1. The owner smoke baseline IS "13 ok, 0 failed (mode: exchange)"

    BP_SMOKE_REQUIRE_EXCHANGE=1 tooling/mobile-smoke/smoke.sh 2>&1 | tail -3
    # => == 13 ok, 0 failed (mode: exchange) ==

First OBSERVED run of the exchange path (the number was previously diff-derived
from #6230). Teardown revoked the minted token and re-probed it: 401.

## 2. Gate-1 step 1 (`bp cloud teams ls`) is a dead command

    bp cloud teams --help
    # => {"error":{"code":"usage","message":"unknown cloud command \"teams\" ..."}}

Replacement (works):

    bp teams -o json | jq -r '.teams[]|select(.slug=="guerrilla")|.id'
    # => 506f035e-08f4-4b49-9038-86735eb4c0ef

`bp cloud members` is READ-ONLY (roster + invitations). bp has NO invite verb —
the invite is HTTP-only:

    CT=$(jq -r .cloud_token ~/.config/barkpark/config.json)
    CU=$(jq -r .cloud_url   ~/.config/barkpark/config.json)
    curl -sS -X POST "$CU/v1/teams/$TEAM/invitations" \
      -H "Authorization: Bearer $CT" -H 'Content-Type: application/json' \
      -d '{"email":"<second@account>","role":"member"}'      # -> {invitation, accept_url}
    curl -sS -H "Authorization: Bearer $CT" "$CU/v1/teams/$TEAM/invitations"  # post-condition read
    curl -sS -H "Authorization: Bearer $CT" "$CU/v1/teams/$TEAM/members"      # role MUST read "member"

Route proven live without sending an invite: empty body -> HTTP 422
`{"error":"email_required"}`.

## 3. config.json clobber: real, but the fix is env isolation, not backup/restore

bp resolves its config dir via XDG_CONFIG_HOME (internal/cli/config.go
configDir/ConfigPath — the SAME path both reads and writes), so a bare
`bp login` as the member overwrites the owner session. Isolate instead:

    XDG_CONFIG_HOME=$HOME/.bp-member bp login          # member session, own file
    BP_CONFIG=$HOME/.bp-member/barkpark/config.json \
      BP_SMOKE_REQUIRE_EXCHANGE=1 tooling/mobile-smoke/smoke.sh

Proof the override isolates:

    XDG_CONFIG_HOME=/tmp/xdgtest bp cloud members -o json
    # => {"error":{"code":"auth","message":"not logged in — run `bp login` ..."}}  (real config untouched)

## 4. Gate-2 (push) is BLOCKED BY A MACHINE BUG, not only by credentials

The packet says the six values go in `/opt/barkpark-cloud/.env`. That path does
not exist. The real file is `/opt/barkpark/cloud/.env` (16 keys, none push).

Worse: `cloud/docker-compose.yml` passes ONLY the keys listed under
`environment:` (its own header states the rule) and has NO `env_file:`.
No APNS_*/FCM_* line exists there — on the deployed copy or on origin/main —
even though `cloud/.env.example:122-139` documents all six. So the six values
would be set in .env, exported by `deploy/cp-deploy.sh:50`, and still never
reach the container.

    ssh -i ~/.ssh/barkpark_indx root@api.barkpark.cloud \
      'grep -n "APNS\|FCM" /opt/barkpark/cloud/docker-compose.yml || echo NONE'
    git show origin/main:cloud/docker-compose.yml | grep -c 'APNS\|FCM'   # => 0

Post-condition read for criterion 1 (there is NO HTTP surface for it —
`credential_status/0` has zero callers outside tests):

    ssh -i ~/.ssh/barkpark_indx root@api.barkpark.cloud \
      'docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc \
         "IO.inspect(BarkparkCloud.Push.credential_status())"'
    # => %{"apns" => false, "fcm" => false}     (baseline, 2026-07-28)

Server half otherwise live: POST /v1/push/device-tokens -> 401 anon, 422
`{"error":"invalid"}` authed-empty; POST /v1/barkparks/:id/push-relay and
POST /v1/relay/chat-blocked/:id are routed (cloud/lib/barkpark_cloud/web/router.ex
:2558, :2607, :6661).

## 5. Gate-3 toolchain baseline on THIS Mac (refutes "Android-dischargeable")

    sw_vers            # ProductVersion 15.5 (needs 26.2+ for Xcode 26.4)
    xcode-select -p    # /Library/Developer/CommandLineTools  (no Xcode.app)
    command -v pod     # absent
    java -version      # "Unable to locate a Java Runtime"

No JDK, no Android SDK, no Xcode, no CocoaPods. Nothing in gate 3 is
machine-dischargeable this wave.
