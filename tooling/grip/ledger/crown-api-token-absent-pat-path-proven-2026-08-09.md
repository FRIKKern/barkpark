# CROWN_API_TOKEN is ABSENT, and the PAT branch it would select WORKS (2026-08-09, wave 30 verify)

Re-derivation recipes. Every line below was run against origin/main and the live control plane
at 2026-08-09T14:06–14:10Z. Nothing here is read from the primary checkout's working tree.

## 1. The secret does not exist — this is a HUMAN GATE, not a workflow edit

    gh secret list
    gh secret list --app actions

Both print exactly six rows and CROWN_API_TOKEN is not among them:
BREAKGLASS_TOKEN, CP_HOST, DEPLOY_SSH_KEY, GUERRILLA_HOST, HETZNER_DNS_TOKEN, NPM_TOKEN.

## 2. It is also unwired — zero references in any workflow

    git grep -n 'CROWN_API_TOKEN' origin/main

Four hits, all in scripts/crown-reconcile.sh (87, 235, 246, 312) and scripts/crown-reconcile.test.sh
(149, 353, both UNSETTING it). No .github/workflows file mentions it. So both fixes are needed:
mint the secret (human) AND add one env line to crown-reconcile.yml's `reconcile` step (build).

    git show origin/main:.github/workflows/crown-reconcile.yml | sed -n '106,112p'

shows the step env is GH_TOKEN + CP_HOST + DEPLOY_SSH_KEY only — select_reader (:235) therefore
skips the `pat` arm and falls to `ssh` on every CI run. Structural, not flaky.

## 3. A REAL read-ability PAT gets 200 today, and drives the :311 branch to RECONCILED

D412 warns the config's `cloud_token` is a SESSION token, so probing with it refutes nothing.
Mint a real `bpc_pat_`, prove, revoke (the wave-23 verifier set this precedent):

    T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -X POST -H "authorization: Bearer $T" -H 'content-type: application/json' \
      -d '{"name":"dr-wNN-verifier-probe","abilities":["read"]}' https://barkpark.cloud/v1/tokens
    # → {"token":"bpc_pat_…","pat":{…,"abilities":["read"]}}

    P=<the bpc_pat_ value>
    curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer $P" \
      'https://barkpark.cloud/v1/deliveries?limit=1'                    # → 200
    curl -s -o /dev/null -w '%{http_code}\n' 'https://barkpark.cloud/v1/deliveries'  # anon → 401

    git show origin/main:scripts/crown-reconcile.sh > /tmp/cr.sh
    CROWN_API_TOKEN="$P" GH_TOKEN=$(gh auth token) bash /tmp/cr.sh --window-hours 24; echo "RC=$?"
    # → header "reader=pat", RC=0, and:
    # RECONCILED: all 5 delivering run(s) in the window have their row, all 54 row(s) …
    # ZERO "answered HTTP" warnings. The PAT arm has now executed end to end.

    curl -s -X DELETE -H "authorization: Bearer $T" https://barkpark.cloud/v1/tokens/<pat-id>  # {"ok":true}
    curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer $P" \
      'https://barkpark.cloud/v1/deliveries?limit=1'                    # → 401, residue gone

Route guard, for the record:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '3917,3918p'
    #   get "/v1/deliveries" do
    #     conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

and its own routing table line 107 says "PAT-reachable on purpose (D385/D412)". The 401 the
reconciler sees in CI is NOT a route defect — it is the absence of a credential the route
already accepts.

## 4. All six file-ci-failure-issue.sh call sites pass GITHUB_TOKEN post-#11216

    git grep -n 'file-ci-failure-issue.sh' origin/main -- .github/workflows

Six `run:` sites across FIVE workflow files (deploy.yml twice, at :380 and :1068):
codebase-intel.yml:200, crown-reconcile.yml:166, deploy.yml:380, deploy.yml:1068,
paper-readers.yml:75, renew-mail-cert.yml:48. Each step's own env block sets
`GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`; crown-reconcile.yml additionally sets
`GH_TOKEN: ${{ github.token }}` (harmless — the script reads GITHUB_TOKEN and nothing else,
scripts/file-ci-failure-issue.sh:45). The wave-29 GH_TOKEN-only slip is FIXED everywhere.
