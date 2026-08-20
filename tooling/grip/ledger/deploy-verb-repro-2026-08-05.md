# deploy.sh banner reaches after 30 failed health probes — re-derivation recipe

PDS wave 48, verifier `deploy-verb-repro`. All commands run from the repo root.

## 1. The banner is unconditional (RUN PROOF, not inference)

Extract the verbatim loop + banner from origin/main and run it against a dead port:

```bash
git show origin/main:deploy.sh > /tmp/deploy_main.sh
python3 - <<'EOF'
lines=open('/tmp/deploy_main.sh').read().split('\n')
block = lines[261:270] + ['TLS_READY=""','ADMIN_TOKEN=""'] + lines[313:319]
open('/tmp/verbatim_block.sh','w').write('#!/usr/bin/env bash\nset -euo pipefail\n'+'\n'.join(block)+'\n')
EOF
sed -i '' 's|localhost:4000|localhost:59999|' /tmp/verbatim_block.sh   # dead port
mkdir -p /tmp/shim && printf '#!/bin/sh\necho "10.0.0.9"\n' > /tmp/shim/hostname && chmod +x /tmp/shim/hostname
PATH=/tmp/shim:$PATH bash /tmp/verbatim_block.sh; echo "RC=$?"
```

Expected (measured 2026-08-05): 60.5s wall, NO `   Ready!` line, banner
`  Barkpark is running!` printed, `RC=0`.

The `hostname` shim is required only on macOS — deploy.sh:315 calls `hostname -I`,
which is Linux-only. Without the shim the run dies at :315 (exit 1) BEFORE the
banner, which would falsely look like a fail-closed script.

`curl -s --max-time 1 http://localhost:59999/api/schemas; echo $?` must print `7`
(connection refused) for the dead-port premise to hold. Port 4000 on this host
returns `28` (timeout) — do NOT use 4000.

## 2. The go:embed twin

```bash
diff <(git show origin/main:deploy.sh) <(git show origin/main:internal/cli/setup/assets/deploy.sh) && echo EMBED_TWIN_IDENTICAL
```

Identical on origin/main. A fix must touch both — but the gate catches a
one-sided edit: `.github/workflows/vendored-assets.yml` runs `make cli-assets-check`
(`cmp deploy.sh internal/cli/setup/assets/deploy.sh`, Makefile:108) on any PR
touching `deploy.sh` or `internal/cli/setup/assets/**`. Workflow: edit the ROOT
copy, then `make cli-assets-sync`.

## 3. Duplicate-filing check

```bash
bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys;s=json.dumps(json.load(sys.stdin)['doc']);print([ (k,s.count(k)) for k in ['deploy.sh','Barkpark is running','curl-installed'] ])"
grep -n 'deploy.sh' .claude/workflows/bp-pds-charter.md
```

task-fb4fb869490b4213 mentions none of those strings — it is about SITE
deployments through the control plane (`/v1/sites/:id/deployments`), a different
mechanism. The PDS charter mentions only `deploy/instance-deploy.sh` and
`deploy/site-deploy.sh`, never the root `deploy.sh`. NOT already filed.

CAVEAT on `bp search query "\"Barkpark is running\""`: quotes are not honoured —
it returns 1478 OR-matched documents. bp search cannot settle a duplicate-filing
question; grep the charter and read the candidate task's body.
