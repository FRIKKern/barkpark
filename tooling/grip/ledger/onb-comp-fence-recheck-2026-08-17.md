<!-- doc-tier: cold | canonical-for: onb-comp-w1-fence-recheck-rederivation | budget: 900tok -->

# Onboarding-composition wave — decide-time fence recheck (2026-08-17)

Re-derive the open-PR contention map for the wave's candidate files.

```bash
gh pr list --state open --limit 100 --json number,title,mergeable,files > /tmp/prs.json
python3 -c "
import json
prs=json.load(open('/tmp/prs.json'))
targets=['internal/cli/doctor_onboarding.go','internal/cli/usage.go','internal/cli/cli.go','internal/cli/login_device.go','internal/cli/onramp_write.go','internal/cli/config.go','internal/cli/cloud12_cmd.go','internal/cli/run.go','internal/cli/tasks_create_cmd.go','internal/cli/builtins.go','internal/cli/seed_cmd.go','internal/cli/setup/connect.go','internal/cloudclient/client.go','scripts/install-cli.sh','scripts/doctor.sh','api/lib/barkpark_web/controllers/meta_controller.ex']
for t in targets:
    print(t,[(p['number'],p['mergeable']) for p in prs if any(f['path']==t for f in p['files'])])
"
```

Result (2026-08-17, 46 open PRs): every internal/cli target + connect.go + both scripts + meta_controller.ex CLEAN.
Only `internal/cloudclient/client.go` contended — triple: #11901 (MERGEABLE), #10811 (CONFLICTING), #10129 (CONFLICTING).

Resolutions:
- #10129 = DEPLOY-RELIABILITY (fleet verdict reads deploy rate), NOT Connectors. Branch loop-epic/the-verdict-reads-the-deploy-rate. cloud/ + cloud_status_cmd.go + client.go + semrole.go. CONFLICTING.
- #11766 = MERGEABLE OPEN; gates api capabilities surface (capabilities.ex, capabilities_controller.ex, manifest.schema.json, internal/manifest/fetch.go). Disjoint from meta_controller.ex (the wave's isProd/meta touch), which is CLEAN.
- cloud12_cmd.go (slice-3 rebuild surface) EXISTS and is UNCONTENDED by any open PR.
- cloud_status_cmd.go contended by #10720 + #10129 (both CONFLICTING) — not a wave target but the fleet LAST-SEEN intent may live there.
