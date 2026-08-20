# cch-w40 v10 — FailureCopy's auth arm and the points_here kind discard (re-derivation recipes)

Subject: `cloud/lib/barkpark_cloud/failure_copy.ex` on `origin/main` @ `95642c550`.
NOTE: the primary checkout at `a31faa52d` is ~500 lines BEHIND on this file — a local
grep answers a different question. Every recipe below reads `origin/main`.

## R1 — the auth arm still exists, verbatim, inside arity-1 humanize/1

    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '586,589p'
    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | grep -n 'def humanize'
    # expect :587 unauthorized/invalid token -> :588 "…We're on it — try again shortly."
    # expect humanize/1 only (379/381/384). No provider argument exists in the seam.

## R2 — the capacity arm eight lines above already wrote the argument

    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '568,585p'
    # "THE COPY NAMES NEITHER A PROVIDER NOR A RESOURCE, BECAUSE THIS PREDICATE
    #  CAN DISTINGUISH NEITHER. It is a bare substring test over a string, and
    #  humanize/1 is arity 1 — there is no provider argument anywhere in the seam"

## R3 — the disproof corpus (run it; do not predict it)

Requires a worktree at origin/main because the primary checkout is stale:

    WT=$(mktemp -d)/wt
    git worktree add --detach "$WT" origin/main
    cp -R cloud/deps cloud/_build "$WT"/cloud/
    cat > /tmp/probe10.exs <<'EOF'
    alias BarkparkCloud.FailureCopy
    for c <- [
      "FATAL: 401 Unauthorized from https://guerrilla.barkpark.cloud/w/acme/p/blog — the site read token is invalid",
      "BUILD failed (exit 1): copying dist/errors/unauthorized/index.html failed: no space left on device",
      "npm ERR! 401 Unauthorized - GET https://registry.npmjs.org/@acme/private",
      "az: AuthorizationFailed - invalid token for subscription"
    ], do: IO.puts(c <> "\n  -> " <> to_string(FailureCopy.humanize(c)) <> "\n")
    EOF
    (cd "$WT"/cloud && CC=clang mix run --no-start /tmp/probe10.exs)

Expected on origin/main: the first THREE all render the credentials sentence
(a user-owned read token, a DISK-FULL build whose only crime is the path slug
`errors/unauthorized/`, and an npm-registry 401); the fourth — the Azure clause
at :532-537, which IS narrowed — renders correct role-assignment copy. The
fourth is the in-file discrimination control: any fix must keep it.

## R4 — every pin of the string

    git show origin/main:cloud/... # or, in the worktree:
    grep -rn "We're on it\|rejected our credentials" cloud/test cloud/lib cloud/priv

Live pins on origin/main: failure_copy_test.exs:102 (auth arm), :298 (canned
list), :424 (@auth attr); sites_deploy_stage_caption_test.exs:218 (the SITE
READ TOKEN 401 asserted equal to the sentence); router_sites_test.exs:855;
scenarios.mjs:729 (preview fixture prose). delivery_reason.ex:215 is a DIFFERENT
sentence ("The destination rejected our credentials.") and is out of scope.

## R5 — green baselines to beat

    (cd "$WT"/cloud && CC=clang mix test test/barkpark_cloud/failure_copy_test.exs)
    # 109 tests, 0 failures
    (cd "$WT"/cloud && CC=clang mix test test/barkpark_cloud/domain_status_test.exs \
                                        test/barkpark_cloud/sites_deploy_stage_caption_test.exs)
    # 55 tests, 0 failures

## R6 — domain_stage_remediation discards a REAL kind

    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '732,735p'
    git show origin/main:cloud/lib/barkpark_cloud/domain_status.ex | sed -n '199,212p'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '3576,3579p'

`kind` is threaded end-to-end and is exactly "platform" | "custom"; every SITE
domain is "custom" (domain_status.ex:211). The points_here copy asserts "It's
pointed automatically when the instance is provisioned", which router.ex:3577-78
refutes in the tree's own words: "external hosts: box wiring only — the customer
owns DNS." Zero tests pin the literal (only `is_binary`), and the tls arm at
:917-924 of domain_status_test.exs is the in-file template for a kind-split test.

## R7 — band arbitration

    gh pr view 10019 --json files --jq '.files[].path'
    gh pr diff 10019 | grep -E '^(diff|@@)'

#10019 (dr-w8-s6, MERGEABLE) touches failure_copy.ex at :150-190 and :359-400 and
failure_copy_test.exs at :913+. The auth arm (:587) and its pins (:102/:298/:424)
are DISJOINT from every hunk — line-shift only, no textual conflict.
