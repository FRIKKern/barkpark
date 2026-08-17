# onb wave — go-gate-and-freshness re-derivation recipes (2026-08-17)

Baseline HEAD at survey: `a6535504204df39850cb1d08316b5ffb25eb983b` (local main, 79 behind origin/main).

## (a) Go gate — the baseline every builder inherits
NOTE: `cc` is aliased to a Claude wrapper on this host (see memory cc-alias-shadows-compiler).
cgo fails with `error: unknown option '-E'` unless CC is set. Set it first.

```
export CC=/usr/bin/clang
go build ./...            # → BUILD_RC=0
go vet ./internal/cli/... # → VET_RC=0
go test ./internal/cli/... 2>&1 | tail -8   # → all ok
```
Result: build 0, vet 0, test all `ok` (cli 66.6s, cloud 1.1s, azure 1.9s, setup 3.6s). Green baseline.

## (b) doctor.sh §1b release cadence (epic criterion 2 guard, live)
```
bash scripts/doctor.sh 2>&1 | sed -n '/[Rr]elease cadence/,/^$/p'
```
Result: `✓ release cadence current (cli-v1.17.0: 113 commit(s) / 3d behind main)`

## (c) freshness leg network shape
```
grep -n "onboardingLatestRelease\|onboardingCLIFreshness" internal/cli/doctor_onboarding.go
sed -n '68,134p' internal/cli/upgrade.go
```
onboardingCLIFreshness (doctor_onboarding.go:336) → onboardingLatestRelease (:69) →
latestReleaseVersion(releaseRepoBase()) → http.Client{Timeout:10s} GET api.github.com/...releases.
NO cache/memoization. Per-call network. Dev build short-circuits BEFORE any network (:338).
Offline-tolerant in the exit-0 sense (returns onbCLIUnreported, never errors) but blocks up to 10s.

## (d) whoami -o json consumers (new top-level `cli` key safety)
```
grep -rn "whoami" internal/ js/ scripts/ | grep -v _test.go
grep -rn "DisallowUnknownFields" internal/
```
Consumers: scripts/bp-vercel-quick-setup.sh:186 (jq -r '.server'),
scripts/pds-live-bp-write-receipt.sh (python d.get("auth_tier")). Both key-scoped → additive-safe.
No js/ consumers. No DisallowUnknownFields decodes whoami output (all such hits are manifest/census).
