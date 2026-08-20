# golive-chain-vs-gate-ordering — does the birth VERIFY gate fire before the site plane exists?

All lines below are re-derivation recipes against `origin/main` @ `e3403110465e094d8ff06f4cc68c2c3ee342dfdd`.
No worktree reads. Nothing here is a conclusion you cannot re-run in <1s.

## RESULT: ordering is SAFE. configureHost (incl. the 7b/8 window) completes BEFORE runVerifyGate.

    git show origin/main:internal/provisioner/provision.go | grep -n 'acquireHost\|runVerifyGate'
    # -> 423:  live, err := acquireHost(ctx, seams, wp, spec)
    # -> 497:  if verr := runVerifyGate(ctx, verifyConfig{

`acquireHost` → `wp.Provision` / `wp.ProvisionOneShot` → `wp.configureHost`, and the whole
chain (secrets → dns → caddy → secrets-install → migrate → admin-token → **7b agent** →
**8 health** → register) is inside it:

    git show origin/main:internal/cli/cloud/warmpool.go | grep -n 'configureHost\|7b\. agent\|8\. health'
    # -> 1114:  live, err := wp.configureHost(ctx, host, spec)      (Provision)
    # -> 1211:  live, err := wp.configureHost(ctx, host, spec)      (ProvisionOneShot)
    # -> 1247:  func (wp *WarmPool) configureHost(...)
    # -> 1387:  // 7b. agent (charter Decision 33) ...
    # -> 1410:  // 8. health — FAIL CLOSED, on a BOUNDED poll (F2).

Order on the wire: `acquireHost`(423, contains 7b+8) → content bootstrap(451) →
`runVerifyGate`(497) → ready(523). A chain-installed site plane landing between 7b and 8
therefore EXISTS by the time any birth-gate probe fires. The verify-probe surveyor's
"probe fires against a plane that does not exist yet" premise is **refuted for the chain
option**. (It would still be true for a probe added to a bake-only option on a box whose
image predates the bake — a different risk.)

## The real constraint the probe hits instead: no transport can see the plane.

Both verify executors are HTTP-only against `https://<label>.<zone>`; neither SSHes.

    git show origin/main:internal/provisioner/verify.go | sed -n '89,115p'   # runVerifyGate: net/http only
    git show origin/main:cloud/lib/barkpark_cloud/verify.ex | sed -n '1,45p' # same suite, HTTP, on demand

And there is no host-capability field anywhere to carry plane presence:

    git grep -n 'hosts_sites\|site_plane\|builder_present\|host_capabilities' origin/main
    # -> (no output; rc=1)

So a `verify.siteplane` probe needs a NEW surface (a capabilities/health field the box
serves, or an agent-beat field) — it cannot be a pure fixture addition.

## The fixture seam is TWO asserters, and both must grow together.

    git show origin/main:cloud/priv/static/__fixtures__/verify_probes.json
    # -> 3 probes: verify.api / verify.login / verify.studio (name,label,pass_rule)
    git show origin/main:internal/provisioner/verify_fixture_test.go | sed -n '84,125p'
    # -> TestProvisionerProbeVocabularyMatchesFixture: runs the COMPILED probes
    #    (verifyAPI, verifyLogin, verifyStudio) and deep-compares names to the fixture

The Elixir executor asserts the same fixture (`probes/0` deep-equals it — verify.ex
moduledoc, "one vocabulary, two executors — the D32 discipline"). Adding a 4th probe
without both asserters = red build.

## GoLiveSpec carries NO builder-token and NO hosts-sites field.

    git show origin/main:internal/cli/cloud/warmpool.go | sed -n '80,95p'
    # type GoLiveSpec struct {
    #   Name string; Zone string; App int; Spec ServerSpec; BaseURL string
    #   AgentToken string   // charter D33 — /etc/barkpark/agent.token
    #   ControlURL string   // /etc/barkpark/agent.env
    # }

Only 7 fields. The chain option therefore needs a NEW GoLiveSpec field (and a CP claim
payload field to fill it) if the builder is to get a credential at provision time.

## Nothing under internal/ ever invokes site-runtime-install.sh.

    git grep -n 'site-runtime-install' origin/main -- internal/   # rc=1, no output
    git grep -n 'site-runtime-install' origin/main
    # -> only .github/workflows/cp-ops.yml (lines 21,35,219,232,235,236,237)
    #    and deploy/site-runtime-install.sh itself

The bake has no site plane either:

    git show origin/main:deploy/bake-server-image.sh | grep -cE 'docker|nixpacks|buildx'   # -> 0

## Reusable facts about the script any lane will touch

    git show origin/main:deploy/site-runtime-install.sh | grep -n 'arm64\|cat >\|BUILDER_TOKEN'
    # 41:  curl -sL https://go.dev/dl/go1.24.5.linux-arm64.tar.gz | tar -xz -C /usr/local   <-- ABORTS on x86_64
    # 57:  aarch64) PLATFORM=linux/arm64 ;;                                                  <-- arch detection IS correct here
    # 68:  BUILDER_TOKEN=/etc/barkpark/agent.token   (worker.token wins if present)
    # 74:  cat > /etc/systemd/system/barkpark-builder.service <<'UNIT'
    # 93:  cat > /etc/systemd/system/barkpark-runtime.service <<'UNIT'

Line 41 is the only arch bug: PLATFORM is detected properly at 55-59, the Go tarball is
not. `deploy/systemd/` holds `barkpark-site@.service` and `barkpark-slot@.service` but NO
`barkpark-builder.service` / `barkpark-runtime.service` — those two are heredoc-only.

    git ls-tree -r --name-only origin/main -- deploy/systemd
