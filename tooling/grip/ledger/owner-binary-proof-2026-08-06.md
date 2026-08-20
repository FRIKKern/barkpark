# owner-binary-proof — 2026-08-06 (wave 6 verifier, deploy-reliability)

Re-derivation recipes for the claim: *the owner cannot see the wave because of the
binary on their PATH — and a rebuild from origin/main does not fix it either.*

All commands run on the owner's host, 2026-08-06 ~17:39–17:45Z. Nothing was
installed over `/Users/pelle/.local/bin/bp`; test binaries went to a scratchpad
BINDIR so the stale-state evidence survives.

## 1. The installed binary and how far behind it is

    bp version
    # {"build_date":"2026-07-31T06:54:48Z","cli_version":"dev","commit":"f59aaf717"}
    git rev-list --count f59aaf717..origin/main    # 322
    git rev-list --count origin/main..f59aaf717    # 0

## 2. Pressure is on the wire, absent from the CLI

    CTK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])")
    curl -s -H "Authorization: Bearer $CTK" https://api.barkpark.cloud/v1/barkparks \
      | python3 -c "import json,sys;[print(b['slug'],json.dumps(b.get('pressure'))) for b in json.load(sys.stdin)['barkparks']]"
    # guerrilla {"load1":5.6,"cpu_cores":2,"cpu_percent":98,"swap_used_percent":79,
    #            "beam_swap_bytes":889495552,"disk_used_percent":77,...}
    # jarl      {"disk_used_percent":96,...}

    bp cloud status -o json | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)['barkparks'][0]))"
    # no 'pressure' key; guerrilla renders status=ok rank=8 bucket=healthy

    strings -a $(which bp) | grep -cE 'swap_used_percent|cpu_cores|beam_pss_bytes'   # 0

## 3. A rebuild from clean origin/main changes NOTHING (the premise-breaker)

    SP=<scratchpad>
    git clone --no-checkout https://github.com/FRIKKern/barkpark.git $SP/mainco
    git -C $SP/mainco checkout ef77af2748ceda54fdd6e078f71a6e6044b55439
    make -C $SP/mainco cli-install BINDIR=$SP/bin-main       # ~24s
    strings -a $SP/bin-main/bp | grep -cE 'swap_used_percent|cpu_cores|beam_pss_bytes'   # 0

## 4. The binary built from PR #9887 head DOES carry them, and renders live

    git -C $SP/mainco fetch --depth=5 https://github.com/FRIKKern/barkpark.git \
      aa19dcca3a5a8f2f6edd014e9369c3a5f5c263c2 && git -C $SP/mainco checkout FETCH_HEAD
    make -C $SP/mainco cli-install BINDIR=$SP/bin-9887
    strings -a $SP/bin-9887/bp | grep -cE 'swap_used_percent|cpu_cores|beam_pss_bytes'   # 3
    script -q /dev/null $SP/bin-9887/bp cloud status | sed -e 's/\x1b\[[0-9;]*m//g' | grep -iE 'guerrilla|jarl'
    # strained  Guerrilla  … load 6.3 on 2 cores (3.1x, 1m avg) · 1.7 GB in swap
    # filling   jarl       … disk 96% used (fills at 90%) · vitals unreadable — agent predates the vitals beat

## 5. No instrument will ever tell the owner to rebuild

    bp doctor --onboarding -o json   # "cli":{"installed":"dev","up_to_date":true,...}; exit 0
    bp upgrade --check               # "this is a dev build … upgrade via git pull + make cli-build"; exit 2
    gh api --paginate repos/FRIKKern/barkpark/releases --jq '.[].tag_name' | grep '^cli-v' | head -1
    # cli-v1.16.0, published 2026-07-24 — tag-driven, so a merge publishes no CLI release

## 6. Degraded suppresses the pressure sentence (observed, 17:41:23Z)

    script -q /dev/null $SP/bin-9887/bp cloud status   # while guerrilla's health check was failing
    # degraded  Guerrilla … DETAIL: —
    grep -n 'case "strained"\|case "filling"\|"degraded"' $SP/mainco/internal/cli/cloud_status_cmd.go
    # attentionDetail has no degraded arm; degraded (rung 4) outranks strained (5)
