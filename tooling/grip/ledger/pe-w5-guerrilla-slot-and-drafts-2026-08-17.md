<!-- doc-tier: cold | canonical-for: pe-w5-guerrilla-slot-and-drafts-rederivation | budget: 800tok -->
# Paper Excellence W5 — guerrilla slot + int_3 drafts + env-inheritance re-derivation (2026-08-17)

Verifier bundle [guerrilla-slot-and-drafts]. All facts derived live on guerrilla 157.180.90.121.

## (a) Active slot re-pin

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cat /opt/barkpark/.slots/green.sha /opt/barkpark/.instance-deploy-last; git -C /opt/barkpark rev-parse HEAD; systemctl is-active barkpark-slot@green barkpark-slot@blue; grep -oE "localhost:[0-9]+" /etc/caddy/Caddyfile | tail -1'
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'ss -ltnp | grep :4001; grep -i port_override /opt/barkpark/.slots/green.env'

Result: green.sha == .instance-deploy-last == /opt/barkpark HEAD == `0ff6fae4a6` (three-way match).
green active, blue inactive. Caddy catch-all reverse_proxy for guerrilla.barkpark.cloud = localhost:4001 (Caddyfile line 91). beam.smp PID 2533193 (== slot@green MainPID) LISTENs on :4001. green.env BARKPARK_PORT_OVERRIDE=4001.

CAVEAT (fourth equality FAILS, harmlessly): origin/main HEAD = `a9d29985d6`, which is 4 commits AHEAD of the deployed 0ff6fae. All four are cloud/cloud-console fixes (#11846-#11849) — none touch api paper rendering or stamp minting; both HEADs are same-day (2026-08-17, 47 min apart). Serving build stays "fresh HEAD BEAM" for the census argument; the "== origin/main HEAD" clause in the assignment does not literally hold.

    git -C <repo> log --oneline 0ff6fae..a9d29985   # the 4-commit cloud-console gap

## (b) The 2 draft int_3 papers (NOT probe papers — do not delete)

    ssh ... 'sudo -u postgres psql -d barkpark_prod -tAc "SELECT id, slug_text, status, updated_at FROM documents WHERE type='"'"'paper'"'"' AND status='"'"'draft'"'"' AND content->'"'"'body_html_sv'"'"'='"'"'3'"'"'::jsonb;"'

- `4751a2c2-db3c-4e8a-a9f6-0b0dae189314` — slug_text NULL, title NULL, draft, updated 2026-07-11 (anonymous slug-less draft).
- `5da4866f-e059-440b-ae1d-f86e912c7878` — slug `task-quality-experiment-round-03-attack-2026-07-18`, draft, updated 2026-07-18. Slug reads experiment/attack-adjacent; verify against the 11-probe delete allowlist before any sweep so it is not collateral.

## (c) MIX_BUILD_ROOT survives into exec'd start.sh mix under green.env

    ssh ... 'cd /opt/barkpark/api; set -a; source /opt/barkpark/.slots/green.env; set +a; ./start.sh mix run --no-start -e "IO.puts(\"MBR=\" <> (System.get_env(\"MIX_BUILD_ROOT\") || \"UNSET\"))"'

Result: `MBR=/opt/barkpark/api/_build_green`. start.sh line 69 does `exec mix "$@"`; the sourced env survives the exec. D25 op-chain env-inheritance link PROVEN.
