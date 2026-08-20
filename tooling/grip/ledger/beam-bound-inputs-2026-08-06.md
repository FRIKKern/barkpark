# Re-derivation recipes — beam bound inputs (verifier, wave 5, 2026-08-06 ~14:54–15:00Z)

Host: guerrilla 157.180.90.121, key `~/.ssh/barkpark_indx`. Every row is a literal command.

## R1 — Paired agent-beat vs /proc read (the trust question)

```
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
for i in 1 2 3 4 5; do
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'date -u +%T; P=$(pgrep -o beam.smp); echo "pid=$P nbeam=$(pgrep -c beam.smp)"; grep -E "^Pss:|^Swap:|^Rss:" /proc/$P/smaps_rollup | tr "\n" " "; echo'
curl -s -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/barkparks | python3 -c 'import sys,json
for r in json.load(sys.stdin)["barkparks"]:
  if r["slug"]=="guerrilla":
    p=r.get("pressure") or {}
    print("  API beam_pss=",p.get("beam_pss_bytes"),"beam_swap=",p.get("beam_swap_bytes"),"at=",p.get("reported_at"))'
sleep 20; done
```
Verdict recorded: swap reconciles inside 0.3% (API 193356 kB @14:54:20 vs /proc 192872 kB @14:54:27;
API 191868 kB @14:55:20 falls BETWEEN /proc 192100 @14:55:09 and 191516 @14:55:30). PSS does not:
API 1246538 kB @14:54:20 vs /proc 1473478 kB @14:54:27 = 15.4% apart.

## R2 — PSS volatility burst (why a single-beat PSS cannot found a bound)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'P=$(pgrep -o beam.smp); for i in $(seq 1 12); do awk "/^Pss:/{p=\$2}/^Swap:/{s=\$2}END{print strftime(\"%T\"), p, s}" /proc/$P/smaps_rollup; sleep 2; done'
```
Recorded 14:56:56–14:57:18: Pss 1190507 → 1688846 kB (+42%) inside 22 s.

## R3 — cgroup peaks (the bound input systemd already keeps, for free)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl show barkpark-slot@green -p MemoryHigh -p MemoryMax -p MemoryPeak -p MemorySwapPeak -p MemoryCurrent'
```
Recorded: MemoryPeak=2099748864, MemorySwapPeak=826621952, MemoryHigh=infinity, MemoryMax=infinity.

## R4 — slot@blue "FAILED" is a stop-timeout, not a serving failure

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl status barkpark-slot@blue --no-pager | head -25; systemctl status barkpark-slot@green --no-pager | head -12; grep -n reverse_proxy /etc/caddy/Caddyfile; cat /opt/barkpark/.slots/blue.env /opt/barkpark/.slots/green.env'
```
Recorded: blue `failed (Result: timeout) since 14:22:49`, `State 'stop-sigterm' timed out. Killing.`,
`0B memory swap peak`; green active since 14:20:37 on port 4001; Caddy `reverse_proxy localhost:4001`.

## R5 — the probe's process-selection rule (lexical, not oldest, not serving)

```
git show origin/main:cmd/barkpark-agent/main.go | sed -n '430,455p'    # findBeamPID: os.ReadDir + first comm match
```
os.ReadDir sorts by filename; proved with a 4-entry temp dir → `1000, 4179607, 4185178, 999`.

## R6 — OOM census and swap floor

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -k --since "14 days ago" | grep -oiP "Killed process \d+ \(\K[^)]+" | sort | uniq -c; grep -E "^MemTotal|^SwapTotal|^SwapFree" /proc/meminfo; cat /proc/pressure/memory'
```
Recorded: 32 beam.smp + 1 python3; SwapFree 149720/2097148 kB (92.9% full); PSI memory full avg10=6.95.
