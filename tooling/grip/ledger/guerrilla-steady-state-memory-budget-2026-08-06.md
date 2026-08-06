# Guerrilla steady-state memory budget — re-derivation recipe (2026-08-06)

Verifier lane `steady-state-memory-budget`, deploy-reliability wave 3.
Every number below is re-derivable by the command beside it. Box: guerrilla
`157.180.90.121`, key `~/.ssh/barkpark_indx`. All readings taken 2026-08-06
~08:50-08:58 UTC, WITH one site build in flight (caught live — `npm run build`
pid 3879079).

## Headline

The box is not swapping itself to death because of builds. **The kernel
OOM-kills the API.** 35 OOM kills in 14 days, 34 of them `beam.smp`.

## The one probe that decides it

```sh
ssh -o BatchMode=yes -o ConnectTimeout=15 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'journalctl -k --since "-14d" --no-pager | grep -oE "Killed process [0-9]+ \(([^)]+)\)" \
   | sed -E "s/.*\((.*)\)/\1/" | sort | uniq -c | sort -rn'
# → 35 beam.smp / 1 python3
```

## Budget (PSS, not RSS — RSS triple-counts postgres shared_buffers)

```sh
ssh … root@157.180.90.121 'for f in /proc/[0-9]*/smaps_rollup; do p=${f#/proc/}; p=${p%/smaps_rollup}; \
  read pss swap < <(awk "/^Pss:/{a+=\$2} /^Swap:/{b+=\$2} END{print a, b}" $f 2>/dev/null); \
  [ -n "$pss" ] && echo "$pss $swap $p $(cat /proc/$p/comm 2>/dev/null)"; done | sort -rn | head -25'
```

| consumer | PSS | Swap | footprint |
|---|---|---|---|
| beam.smp (API) | 1,528 MB | 1,176 MB | **2,704 MB** |
| build in flight (node+npm+next) | 355 MB | ~9 MB | 364 MB |
| postgres (~15 backends, shared_buffers 128MB) | ~260 MB | ~110 MB | ~370 MB |
| 8 serving slots | ~92 MB | ~494 MB | ~586 MB |
| caddy/agent/mcp/journald/multipathd/systemd | ~95 MB | ~7 MB | ~102 MB |
| **census total** | **2,460 MB** | **2,160 MB** | **4,620 MB** |

RAM `MemTotal` = 3,819 MB; swap 2,047 MB with only **94 MB free** (95.5% full).
Anonymous demand overshoots RAM by **~801 MB with the build, ~446 MB without it.**
Removing the build does NOT bring the box under its own RAM.

```sh
ssh … 'grep -E "MemTotal|MemFree|MemAvailable|Cached|SwapTotal|SwapFree" /proc/meminfo; free -m'
```

## Room for the 1500M build scope? No.

`MemAvailable` measured 1,140 MB < the scope's `MemoryMax=1500M`
(`api/lib/barkpark/sites/deploy_runner.ex:116`). The build gate's OWN design
comment (`deploy/lib/site-deploy-common.sh`, ~line 243) computes
`floor(894M MemAvailable / 1500M) = 1 (0 at the low-water mark)` — the measured
box sits AT that low-water mark. N=1 is already one too many.

## Lever ranking (measured headroom, not opinion)

```sh
# slot → Caddy upstream mapping; the refutation of "retire idle slots"
ssh … 'for u in $(systemctl list-units "barkpark-site@*" --state=active --no-legend | awk "{print \$1}"); do \
  mp=$(systemctl show $u -p MainPID --value); \
  echo "$u port=$(ss -lntp | grep "pid=$mp," | awk "{print \$4}" | sed "s/.*://" | head -1) \
  swap=$(awk "/^Swap:/{t+=\$2} END{print t}" /proc/$mp/smaps_rollup)kB \
  pss=$(awk "/^Pss:/{t+=\$2} END{print t}" /proc/$mp/smaps_rollup)kB"; done; \
  grep -nE "reverse_proxy" /etc/caddy/Caddyfile'
```

1. **Bound/shrink the BEAM** — 2,704 MB = 58% of the census, 73% of RAM.
   Historical kill sizes 2,621–3,301 MB anon-rss. Only GB-scale lever.
2. **`MemorySwapMax=0` on the build scope** — recovers 0 MB, but costs the build
   ~nothing (measured: build procs held ~9 MB swap total) and stops a build from
   being the process that tips the API into the OOM killer. Zero occurrences of
   `MemorySwapMax` repo-wide (`git grep -c MemorySwapMax` → 0).
3. **Retire idle serving slots — MEASURED NEARLY WORTHLESS.** The three slots
   bound to no Caddy upstream (`next-capstone__b`:8585, `next-proof__b`:9647,
   `search-ember__a`:9808) hold **190 MB of swap but 2.2 MB of RAM** between
   them. The kernel already reclaimed them. Frees swap, not memory.
4. **Move the build off the box** — removes a 355 MB transient, leaves the
   446 MB steady-state overshoot, and costs the second box the owner refused.

## Collateral facts worth keeping

- The API runs `mix phx.server`, **not a release**
  (`tr "\0" " " < /proc/$(pgrep -f beam.smp)/cmdline`), `MIX_ENV=prod`.
- `barkpark.service` carries **no resource directives at all** —
  `systemctl show barkpark.service -p MemoryMax` → `infinity`.
- BEAM memory is **all anonymous and diffuse** (RssTotal 1,189,868 kB /
  Anonymous 1,165,692 kB; largest single mapping only 54 MB) — allocator
  carriers, not one mmap'd leak. Distribution is down (`epmd -names` empty),
  so `:erlang.memory()` could NOT be read — which subsystem grows is UNPROVEN.
- Slot count is volatile: 8 active at 08:50, 9 at 08:55 (`search__a` booted
  mid-probe). Any fixed count in a brief is wrong by the time it is read.
- `attentionStatus()` (`internal/cli/cloud_status_cmd.go:50`) takes zero vitals
  inputs — confirmed by reading all eight cases.
- Swap as a RESOURCE vital does not exist in the repo: all 149 `swap` hits in
  `*.go`/`*.ex` are "compare-and-swap"/"swappable".
