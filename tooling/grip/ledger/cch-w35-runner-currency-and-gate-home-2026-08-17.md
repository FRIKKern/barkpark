<!-- doc-tier: cold | canonical-for: cch-w35-runner-currency-and-gate-home | budget: 900tok -->

# W35 runner-currency + pathfilter gate-home — re-derivation recipes

Verifier assignment `runner-currency-and-gate-home`, 2026-08-17. All commands re-derive from origin/main or live guerrilla. No mutations.

## (a) Is the installed runner byte-identical to origin/main? — YES, and freshly re-armed

    git show origin/main:scripts/connectors/cloud-sandbox-runner.mjs | md5
    # => 43bee600d508561bd7abd6d26ca0492f   (45942 bytes, 926 lines)

    ssh -o ConnectTimeout=12 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'md5sum /usr/local/bin/cloud-sandbox-runner.mjs; stat -c "%y %s" /usr/local/bin/cloud-sandbox-runner.mjs'
    # => 43bee600d508561bd7abd6d26ca0492f  ...  (45942 bytes)
    # => 2026-08-17 18:17:30 +0000  (re-armed TODAY, later than the 16:52 the digest cited)

MD5 identical, size identical. NO stale-runner strand exists right now. Slice urgency = HYGIENE (prevent a future strand), not REPAIR.

BUT the currency is by LUCK, not design: `scripts/connectors/**` is NOT in deploy.yml `on.push.paths` and NOT matched by the instance regex `^(api|internal|deploy|connectors|templates)/`. instance-deploy.sh:1047 copies `$APP/scripts/connectors/cloud-sandbox-runner.mjs` to /usr/local/bin ONLY when the instance job runs. So a runner-ONLY change triggers NO deploy and strands silently until some co-triggering instance-path merge re-copies it. Today's fresh mtime came from such a piggyback deploy. That latent hazard is exactly what the pathfilter slice closes.

    git show origin/main:.github/workflows/deploy.yml | grep -n 'scripts/connectors'   # => (nothing)

## (b) Is the pathfilter assert a blocking step of a REQUIRED job? — NO

Ground truth (L1, GitHub branch protection):

    gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks
    # contexts: ["Elixir gate","PR references an active task","Cloud gate","Console gate"]  strict:false

`check-deployyml-filters.sh` ("Assert every on.push.paths entry has a deploy target") runs in THREE places, NONE of them a required merge-gate:

1. deploy.yml `changes` job (line 88-89) — trigger is `push: branches:[main]` = POST-MERGE. NOT continue-on-error, but fires after merge, cannot block it.
2. doc-gates.yml `doc-gates` job, step "Deploy paths↔filters drift gate (blocking)" (line 401), runs `--selftest` then the real check. This job DOES trigger on `pull_request` (line 160) — so it is the PR-time home — but `doc-gates` is NOT in the required set → advisory red, does not branch-protection-block (memory: advisory reds never block).
3. deploy-harnesses.yml — `pull_request`-triggered but its OWN comment (line 15-20) states it is not required.

## Right home for the new required scripts/connectors/** presence check

The presence assertion is a natural EXTENSION of check-deployyml-filters.sh (already has a 5-case `--selftest` harness and PR reachability via doc-gates) — add a 6th selftest proving the gate reds when scripts/connectors/** is dropped from paths+regex.

To be truly MERGE-BLOCKING it must ride a REQUIRED context. deploy-harnesses.yml is the WRONG home (not required). The repo's own precedent for exactly this (deploy-harnesses.yml:11-20, stage_names): the shell gate is belt-and-braces reachability; the blocking guard is an ExUnit test riding the required "Elixir gate" (api/test/.../deploy_runner_stage_names_test.exs). Mirror that: an ExUnit test asserting the deploy.yml paths↔regex includes scripts/connectors/**, riding Elixir gate.
