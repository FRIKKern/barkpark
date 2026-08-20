# Re-derivation recipe — CLI binary provenance (wave 5 verifier, 2026-08-06)

Claim: the `bp` on PATH renders an OLDER field set than origin/main for the vitals
surfaces, so a vitals criterion verified with it reads FALSE-RED.

## 1. What binary is installed, and how stale

    command -v bp && bp --version
    # {"build_date":"2026-07-31T06:54:48Z","cli_version":"dev","commit":"f59aaf717"}
    git fetch -q origin main
    git rev-list --count f59aaf717..origin/main            # 321 total
    git rev-list --count f59aaf717..origin/main -- internal/ cmd/   # 31 Go commits

## 2. The new field names are absent from the installed binary's bytes

    for m in pss_bytes swap_bytes top_relations cpu_cores; do \
      printf '%-16s %s\n' "$m" "$(strings -a $(command -v bp) | grep -c "$m")"; done
    # all four → 0

TRAP: `grep -c strained` on the binary returns 5 — every hit is a substring of
`unconstrained` / `UnconstrainedLabels`. Use `grep -oE '[A-Za-z_]*strained[A-Za-z_]*' | sort -u`.

## 3. Build origin/main WITHOUT touching the checkout (main stays on main)

    SP=$(mktemp -d); git archive origin/main | tar -x -C "$SP"
    CC=clang go build -C "$SP" -o "$SP/bp-main" ./cmd/barkpark

(The primary checkout here was 503 commits behind origin/main, so `go run ./cmd/barkpark`
in it proves nothing about main. Always archive-and-build, or state the checkout sha.)

## 4. The decisive A/B, same live server, same minute

    bp            cloud instance top guerrilla -o table   # 4 blocks: CPU Memory Disk Load
    "$SP"/bp-main cloud instance top guerrilla -o table   # 7 blocks + "database: 3.3 GB · top 10 = 98.3% of it"

    bp            cloud status -o table                   # identical…
    "$SP"/bp-main cloud status -o table                   # …to this (strained not built yet)

## 5. Default output is JSON — the raw-passthrough escape hatch

`bp cloud instance top <box>` with NO `-o` prints the control-plane envelope verbatim
(`emitMetricsRaw` → `res.Raw`, internal/cli/cloud_instance_top_cmd.go). That path shows
`pss_bytes` / `top_relations` even from the 27-commit-stale binary → FALSE-GREEN.
`bp cloud status` has NO raw path at all: `ListBarkparks` returns `[]Barkpark` with no
`Raw` field, and `-o json` re-encodes the CLI's own ranked structs.

## 6. The wire really carries what the client drops

    T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])")
    curl -s -H "Authorization: Bearer $T" https://barkpark.cloud/v1/barkparks \
      | python3 -c "import sys,json;[print(b['slug'],json.dumps(b.get('pressure'))) for b in json.load(sys.stdin)['barkparks']]"

## 7. doctor detects it and cannot block

    bash scripts/doctor.sh; echo "RC=$?"    # prints 4 issues, RC=0 (scripts/doctor.sh:177 `exit 0  # advisory`)

Fix for a human/builder: `make cli-install`.
