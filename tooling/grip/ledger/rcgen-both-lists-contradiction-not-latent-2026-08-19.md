# Re-derivation recipe — both-lists contradiction: reproducible, and NOT latent on main

Subject: `scripts/required-checks-generate.sh` emits one context on BOTH
`.protection.required_status_checks.checks` and `.exclusions` at exit 0 when a
job that the COMMITTED spec already requires gains `continue-on-error: true`.
The merge (base union) carries the committed required row while the derivation
adds an S2 ADVISORY exclusion row. The script's own comment at the emit
(generate.sh ~line 1033) states the invariant it is violating: "keeping the row
would emit one context on both lists" — but that guard is one-directional
(`--expect-promoted` / STALE), covering only committed-EXCLUDED × derived-REQUIRED.

## 1. Freshly-fetched sha pair (rules out fixture-specific luck)

    SC=/tmp/rcgen && mkdir -p "$SC/fix2"
    for s in bf499f54b 122fd0df8; do
      gh api "repos/:owner/:repo/commits/$s/check-runs?per_page=100" > "$SC/fix2/checkruns-$s.json"
      gh api "repos/:owner/:repo/commits/$s/status"                  > "$SC/fix2/status-$s.json"
    done
    printf 'bf499f54b\n122fd0df8\n' > "$SC/fix2/main-shas.txt"

## 2. Real workflow tree, real merge base

    S=$(mktemp -d); git archive origin/main .github/workflows | tar -x -C "$S"
    cp -R "$S/.github" "$S/plant1/"          # after mkdir -p "$S/plant1"
    # plant: insert `    continue-on-error: true` under `    name: Cloud gate`
    #        in $S/plant1/.github/workflows/cloud.yml

## 3. The ten acknowledgements this window needs (bash, not zsh)

    ACK=(--expect-unrendered 'Elixir gate'
         --expect-unrendered 'PR references an active task'
         --expect-unrendered 'Dispatch (changed-path sets)'
         --expect-unrendered 'Elixir path-escape ratchet'
         --expect-unrendered 'Format (mix format --check-formatted, advisory) (27.0, 1.18.1)'
         --expect-unrendered 'gofmt drift ceiling (blocking)'
         --expect-unrendered 'Prod compile gate (Elixir 1.18.1 / OTP 27.0)'
         --expect-unrendered 'Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)'
         --expect-unrendered 'Test (Elixir 1.18.1 / OTP 27.0)'
         --expect-unrendered 'Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)')

## 4. The decisive assertion

    bash scripts/required-checks-generate.sh \
      --workflows "$S/plant1/.github/workflows" --fixture-dir "$SC/fix2" \
      --merge-base .github/required-checks.json --sha bf499f54b --sha 122fd0df8 \
      "${ACK[@]}" --explain --out "$SC/spec.json"; echo "EXIT=$?"
    jq -c '[.protection.required_status_checks.checks[].context] as $c
           | [.exclusions[].context] as $x
           | {both: ($c - ($c - $x))}' "$SC/spec.json"

EXIT=0 and `{"both":["Cloud gate"]}`. Same shape with the frozen pair
(e34031104 / f69cfb1f6) and with the plant moved to `Console gate` in
console-harness.yml → `{"both":["Console gate"]}`.

## 5. NOT latent — a new refusal would be dormant, not immediately red

    git show origin/main:.github/required-checks.json | jq -c \
      '[.protection.required_status_checks.checks[].context] as $c
       | [.exclusions[].context] as $x | {both: ($c - ($c - $x))}'
    # {"req":4,"exc":25,"both":[]}

The unplanted derivation over BOTH sha pairs also yields `both: []`.

## 6. Two side facts the same runs produced

- `Elixir gate` did NOT render on either fresh main head (bf499f54b, 122fd0df8)
  despite being a live required context and having a push trigger.
- The unplanted fresh-window emit promotes TWO new contexts the committed spec
  lacks: `build` (release-artifact.yml job 'build') and `Record what this run
  delivered` (deploy.yml job 'record-delivery'). Any regeneration today changes
  the spec for reasons unrelated to the refusal.
