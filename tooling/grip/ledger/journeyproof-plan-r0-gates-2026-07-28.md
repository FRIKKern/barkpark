# Re-derivation recipe — journey-proof `--plan` side-effect-freeness + R0 gate status

Verifier lane `v-journeyproof-plan`, wave claude-ready-servers-wave-2026-07-28.
Target: `scripts/pdf-mvp0-journey-proof.sh` @ origin/main (identical in worktree).

## 1. `--plan` is side-effect-free (structural)

```sh
git show origin/main:scripts/pdf-mvp0-journey-proof.sh > /tmp/jp.sh
grep -n 'trap \|mktemp\|^if \[ "$MODE" = "plan" \]' /tmp/jp.sh
# plan block opens :435, exits :525 ; trap cleanup EXIT :580 ; mktemp -d :583
```
Plan block precedes both. Everything at :190-434 is function definitions only.

## 2. `--plan` runs clean

```sh
bash scripts/pdf-mvp0-journey-proof.sh --plan >/dev/null 2>&1; echo "exit=$?"   # 0
git status --porcelain | grep pdfjp ; ls -d ${TMPDIR:-/tmp}/pdfjp.* 2>&1        # nothing
```

## 3. R0 gates, re-derived read-only (no writes, no spend)

```sh
# 0c PR #6038
curl -s https://api.github.com/repos/FRIKKern/barkpark/pulls/6038 \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("merged"),d.get("merged_at"))'

# 0d/0e/0f anon route shapes (want 401 each)
for u in https://api.barkpark.cloud/v1/fleet/supports \
         https://api.barkpark.cloud/v1/internal/support-jobs/claim \
         https://guerrilla.barkpark.cloud/v1/fleet/support-tokens; do
  printf '%s -> ' "$u"
  curl -sS --max-time 25 -o /dev/null -w '%{http_code}\n' -X POST "$u" \
    -H 'Content-Type: application/json' -d '{}'
done

# 0f roster envelope
AT=$(python3 -c 'import json;print(json.load(open("'"$HOME"'/.config/barkpark/config.json"))["token"])')
curl -sS -o /tmp/r0.json -w 'HTTP %{http_code}\n' \
  -H "Authorization: Bearer $AT" \
  "https://guerrilla.barkpark.cloud/v1/fleet/roster?dataset=production"

# 0h MONEY-SAFETY GATE simulation (the load-bearing one)
CT=$(python3 -c 'import json;print(json.load(open("'"$HOME"'/.config/barkpark/config.json"))["cloud_token"])')
curl -sS -H "Authorization: Bearer $CT" "https://api.barkpark.cloud/v1/barkparks?scope=all" \
  | python3 -c 'import json,sys;print("\n".join(sorted({(r.get("host") or "").strip() for r in (json.load(sys.stdin) or {}).get("barkparks") or [] if r.get("mode")=="managed" and (r.get("host") or "").strip()})))'
hcloud --context barkpark server list -o json \
  | python3 -c 'import json,sys;print("\n".join(sorted({((s.get("public_net") or {}).get("ipv4") or {}).get("ip") or "" for s in json.load(sys.stdin)})))'
# intersect the two: 2026-07-28 result = 4/4 CP-managed hosts visible => gate PASSES
```

## 4. The two structural holes found (re-derive)

```sh
# trap emergency teardown is TOKEN-ONLY: the hcloud-context path leaves a billing orphan
sed -n '395,412p' /tmp/jp.sh          # :400  [ -n "$TEARDOWN_HC_TOKEN" ] guard
# D75's raw delete-by-label fallback is ABSENT
grep -n 'hcloud server delete\|delete-by-label\|--selector' /tmp/jp.sh; echo "exit=$? (1=absent)"
# R1 has no reuse-an-existing-main knob
grep -n 'PDFJP_' /tmp/jp.sh | grep -i 'main_id\|barkpark_id'; echo "exit=$? (1=absent)"
```

## 5. Doc/code drift

`sed -n '130,131p' /tmp/jp.sh` says `PDFJP_POLL_BUDGET` default 900; `sed -n '170p' /tmp/jp.sh`
sets 1800. Header comment is stale; the code value (1800) is the one that runs.
