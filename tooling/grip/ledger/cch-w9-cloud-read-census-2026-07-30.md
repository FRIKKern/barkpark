# CCH wave 9 — cloud/console read census: re-derivation recipes

All commands from repo root unless noted. Authoritative content read via
`git show origin/main:` — the primary checkout was 86 commits behind at
`a31faa52dc7586168cecc7dc2d2324b3732943f6` (origin/main `08d4c869a4`).
A clean clone at origin/main was used for every mutation:

    cd <scratch> && git clone --local --no-hardlinks --branch main /Volumes/SATECHI/github/barkpark m9
    cd m9 && git fetch /Volumes/SATECHI/github/barkpark 'refs/remotes/origin/main:refs/heads/omain' && git checkout omain

## 1. The two cloud-suite cross-tree reads (RUN, not read)

    cd cloud && CC=clang MIX_ENV=test mix test \
      test/barkpark_cloud/providers_capabilities_contract_test.exs \
      test/barkpark_cloud/async_global_seam_guard_test.exs
    # -> 15 tests, 0 failures

Resolve the Go fixture escape without mix:

    elixir -e 'd="cloud/test/barkpark_cloud"; go=Path.expand("../../../internal/cli/cloud/providers_capabilities.json",d); IO.puts(go); IO.puts(inspect(File.exists?(go)))'

## 2. api/test/** is a RUNTIME root of the cloud gate (invisible to a ../ scan)

    elixir -e 'Code.require_file("scripts/async_env_seam_scan.exs"); IO.inspect(Barkpark.AsyncEnvSeamScan.scan().scanned)'
    # -> %{".../api/test" => 983, ".../cloud/test" => 150}

Mutation (in the clone): drop an `async: true` + `Application.put_env` module at
`api/test/zz_probe_test.exs`, re-run the scan — the offender is named, so the
CLOUD gate reds on an api-only change.

## 3. The console harness INDIRECTLY reads .github/workflows/cloud.yml

In the clone, delete cloud.yml's workflow-level `paths:` key (lines 9-24), then:

    node cloud/priv/static/__preview__/seal-predicate.mjs --ledger cloud/priv/static/__preview__/fixtures/seal-predicate/sealable.json --repo "$PWD" --guard-cmd true
    # -> 4x "does not filter on `cloud/**`", VERDICT b=FAIL
    node --test cloud/priv/static/__preview__/seal-predicate.test.mjs
    # -> 31 tests, 7 fail  (console-harness.yml step "Seal predicate tests")

## 4. design/emit-fence.test.mjs is EXECUTED by the console harness

    mv design/emit-fence.test.mjs design/emit-fence.test.mjs.bak
    node --test cloud/priv/static/__preview__/seal-predicate.test.mjs   # -> 1 fail (#22)

## 5. cloud/test/**/*.exs existence is read by the console harness

    mv cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test.exs /tmp/
    node --test cloud/priv/static/__preview__/seal-predicate.test.mjs   # -> 6 fail

## 6. elixir.yml's ratchet misses cloud/test/** (symmetric hole)

    printf 'cloud/test/barkpark_cloud/accounts_test.exs\n' | bash scripts/elixir-path-escape-check.sh --match test     # -> false
    printf 'cloud/test/barkpark_cloud/accounts_test.exs\n' | bash scripts/elixir-path-escape-check.sh --match compile  # -> false
    bash scripts/elixir-path-escape-check.sh --list-escapes | grep cloud   # -> nothing

## 7. Negative census (no hidden shell-outs)

    grep -rn 'System.cmd\|:os.cmd\|Port.open' cloud/lib cloud/test --include='*.ex' --include='*.exs'   # -> empty
    sed -n '/defp aliases/,/^  end/p' cloud/mix.exs                                                     # -> ecto only
