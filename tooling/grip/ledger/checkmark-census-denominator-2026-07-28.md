# Re-derivation recipe — checkmark-census denominator (PDS wave 23, v3)

Settles the shell-surface contradiction (0 vs 12) and produces the guard's true
false-positive load. Ran at `a8c767dbd26e4770bd942f61a3e9c94ab5da8b87`.

## 1. Shell surface — 12 glyphs, ALL in 3 non-shipping proof harnesses

```sh
grep -c '✓' deploy/*.sh scripts/pds-*.sh bin/barkpark | grep -v ':0$'
# deploy/site-spawner-live-proof.sh:4
# deploy/site-spawner-node-live-proof.sh:4
# deploy/site-spawner-autorebuild-proof.sh:4

grep -c '✓' $(ls deploy/*.sh scripts/pds-*.sh | grep -v 'site-spawner.*proof') \
  | awk -F: '{s+=$2} END{print "TOTAL_NONPROOF",s}'
# TOTAL_NONPROOF 0
```

18 of the 22 files — every real deploy verb (`instance-deploy.sh`, `cp-deploy.sh`,
`site-deploy.sh`, `site-deploy-node.sh`) and all 9 `scripts/pds-*.sh` — carry ZERO.
Widening past the glyph does not change it:

```sh
for f in deploy/*.sh scripts/pds-*.sh bin/barkpark; do
  c=$(grep -cE '(echo|printf)[^#]*\b(OK|DONE|SUCCESS|PASSED|deployed|✓)\b' "$f"); \
  [ "$c" != 0 ] && echo "$c $f"; done
# 2 deploy/site-spawner-node-live-proof.sh
# 2 deploy/site-spawner-live-proof.sh
# 2 deploy/site-spawner-autorebuild-proof.sh
# 1 deploy/instance-deploy_test.sh
```

## 2. Elixir surface — 47 glyphs, ZERO receipts

```sh
grep -rn '✓' --include='*.ex' api/lib | wc -l          # 47
grep -rn '✓' --include='*.ex' api/lib | grep -c 'IO.puts\|IO.write'   # 0
```

All 47 are LiveView/HEEx UI glyphs (board_live 14, chat_live 9, paper_editor 4, …).

## 3. Go surface — 94 glyphs = 13 noise + 81 real; 56 remote-in-func

```sh
grep -c '✓' $(ls internal/cli/*.go | grep -v _test.go) | grep -v ':0$' \
  | awk -F: '{s+=$2} END {print "TOTAL",s}'    # 94
```

Classifier: `python3 tooling/grip/ledger/…` — reproduce by mapping each `✓` line to
its enclosing `func` (lines starting `func` at col 0) and testing the body for a
CALL-shaped remote primitive (`doRequest(`, `RunFeed(`, `exec.LookPath/Command(`,
`vercelRun*(`, `cfg.CloudClient(`, `client.<Verb>(`, `hetznerClient(`, `c.HCloud(`,
`hzS3Client(`, `resolveCloudProvider(`, `p.Create/Delete/List(`, `impl.*(`,
`cp.List/Deprovision(`, `instDNSClient/instDeleteA(`, `cloud.WriteBundle(`,
`bundleStoreProvider(`, `migrateFetchAll(`). Exclude self-name matches
(`renderRollbackResult`, `renderProvisioned`) and local-only (`LoadConfig`,
`SaveConfig`, `runSiteBuild`, `runSiteSelfTest`).

| class | n | note |
|---|---|---|
| noise (comment / `return "✓"` / `✓/✗` help) | 13 | enumerated below |
| real, remote primitive in SAME func | 56 | the guard's true load |
| real, decoupled receipt emitter (caller is remote) | 17 | function-scoped guard MISSES these |
| real, genuinely local (self-pointing) | 8 | correctly out of scope |
| **real total** | **81** | |

The 13 noise sites: cloud_providers_cmd.go 187,190 · cloud_site_cmd.go 371,858 ·
cloud_site_preflight.go 634 · doctor_cmd.go 5,138,142,252 · doctor_onboarding.go
567,610 · hetzner_cmd.go 533 · hetzner_net_cmd.go 53.

The 17 decoupled emitters: cloud_autoupdate_cmd.go 145,147,149,151,153 ·
cloud_rollback_cmd.go 119,123 · cloud12_cmd.go 1006 · cloud_support_cmd.go
402,837,986,1405 · hetzner_cmd.go 546 · hetzner_instance_transfer_cmd.go 295 ·
hetzner_net_cmd.go 68 · login_device.go 281 · tasks_next_cmd.go 190.

The 8 genuinely local: cloud12_cmd.go 589,591 · cloud_cmd.go 265 ·
cloud_site_preflight.go 368,441,581,591 · servers_cmd.go 87.
