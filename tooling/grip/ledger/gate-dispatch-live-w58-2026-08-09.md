# gate-dispatch-live — wave 58 re-derivation recipes (2026-08-09)

Measured against `origin/main` = `989b19577e8fa108146807cdd84a3d48d011d9bc`
(committer date 2026-08-09T04:19:04+02:00), from a **full-tree `git archive`**,
never the shared checkout.

## R1 — the dispatch matrix for the five candidate paths

```bash
cd /Volumes/SATECHI/github/barkpark && T=$(mktemp -d) \
  && git archive origin/main scripts | tar -x -C "$T" \
  && for p in cloud/lib/barkpark_cloud/registry.ex cloud/test/x_test.exs \
              cloud/priv/static/app.js internal/cli/cloud/instance.go \
              internal/provisioner/p.go; do
       for m in cloud console; do
         printf '%s %s=' "$p" "$m"
         echo "$p" | bash "$T/scripts/${m}-path-escape-check.sh" --match "$m"
       done
       printf '%s elixir-compile=' "$p"
       echo "$p" | bash "$T/scripts/elixir-path-escape-check.sh" --match compile
       printf '%s elixir-test=' "$p"
       echo "$p" | bash "$T/scripts/elixir-path-escape-check.sh" --match test
     done
```

Result at 989b19577: cloud=true for all five; console=true only for
`cloud/lib/**` and `cloud/priv/static/**`; elixir compile AND test = **false for
all five**.

## R2 — when `internal/**` entered CLOUD_PATHS

```bash
git log --oneline -5 origin/main -- scripts/cloud-path-escape-check.sh
git show 0e94b99fe -- scripts/cloud-path-escape-check.sh | grep -n '^+internal/\*\*'
git show -s --format='%h %ad' --date=iso-strict 0e94b99fe 989b19577
```

`0e94b99fe` (#11082) at 2026-08-09T04:18:51+02:00; head at 04:19:04 — **13 s**.

## R3 — the new-top-level-directory hole is STILL LIVE

```bash
echo newtopleveldir/x.txt | bash "$T/scripts/cloud-path-escape-check.sh"   --match cloud
echo newtopleveldir/x.txt | bash "$T/scripts/console-path-escape-check.sh" --match console
echo newtopleveldir/x.txt | bash "$T/scripts/elixir-path-escape-check.sh"  --match test
```

false / false / false. So `dr-w22-bl-internal-cli-trips-zero-required-gates` is
only HALF falsified by the tree — its second clause holds.

## R4 — Console gate CAN lose on a `cloud/lib/**` edit (mutation)

```bash
W=$(mktemp -d) && git archive origin/main | tar -x -C "$W" && cd "$W"
node --test --test-name-pattern 'cch-w30-s1 census ARM' cloud/priv/static/__app.test.mjs   # 2 pass
printf '\n  def cch_w58_probe(t), do: dispatch_event(t, :cch_w58_fake_event, %%{})\n' \
  >> cloud/lib/barkpark_cloud/registry.ex
node --test --test-name-pattern 'cch-w30-s1 census ARM \(b\)' cloud/priv/static/__app.test.mjs  # 1 fail
```

The arm walks every `.ex` under `cloud/lib` (`__app.test.mjs`:14618), so
`registry.ex` IS in a required context's corpus. Residue: the event-name regex
is `[a-z_]+`, so the injected `cch_w58_fake_event` reds as `'cch_w'` — digits
truncate the reported name.

## R5 — the required set, and what is NOT in it

```bash
git show origin/main:.github/required-checks.json | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print([c['context'] for c in d['protection']['required_status_checks']['checks']])"
git show origin/main:.github/workflows/go-tests.yml | sed -n '15,60p'
git show origin/main:.github/required-checks.json | grep -c 'go vet'   # 0
```
