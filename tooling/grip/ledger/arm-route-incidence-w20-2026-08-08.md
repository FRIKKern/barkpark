# arm-route-incidence — wave 20 re-derivation recipes (2026-08-08)

Verifier: `arm-route-incidence`. Box: guerrilla `157.180.90.121`, key `~/.ssh/barkpark_indx`.

## R1 — how many live sites carry a route marker, and how many site dirs exist

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -c BARKPARK_SITE_ROUTE /etc/caddy/Caddyfile; grep -n "BARKPARK_SITE_ROUTE" /etc/caddy/Caddyfile; ls /opt/barkpark/sites/'
```
2026-08-08: 9 markers, 10 site dirs. The unmarked dir is `search`.

## R2 — public reachability of every site dir

```
for p in search astro-search search-ember next-proof perfect-proof live-auto perfect-demo-2 next-capstone search-capstone nodeproof-20260718-73191; do printf "%-28s %s\n" "$p" "$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 15 https://guerrilla.barkpark.cloud/sites/$p/)"; done
```
2026-08-08: `search` 404, other nine 200.

## R3 — durable site-deploy log dir + the not-armed string incidence

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'D=/opt/barkpark/.bp-site-deploy-runs; ls $D/*.log|wc -l; grep -rh "leaving Caddy untouched" $D | sort | uniq -c; grep -rh "skipping /sites/" $D | sort | uniq -c; grep -rl "route already armed" $D | wc -l'
```
2026-08-08: 1,178 `.log` files; ZERO hits for all three strings — including `route already armed`,
which MUST fire on every re-deploy of an armed site. The zero is VACUOUS: `.log` carries only the
raw npm child output (`BUILD_LOG`, site-deploy.sh:1202), `.status` carries only `BPSTAGE` lines.
`log()` output goes to the script's stdout, which nothing on the box persists.

## R4 — `search` runs: every one is a "first deploy"

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'D=/opt/barkpark/.bp-site-deploy-runs; L=$(ls $D | grep -E "^search-[0-9a-f]{16}\.status$"); cd $D; echo COUNT=$(echo "$L"|wc -l); for f in $L; do grep -o "for slot [ab]" $f; done|sort|uniq -c; for f in $L; do grep -o "slot [ab] :[0-9]*" $f; done|sort|uniq -c; for f in $L; do grep -o "SWITCH status=[a-z]*" $f; done|sort|uniq -c'
```
2026-08-08: 208 status files (2026-08-06T11:41Z .. 2026-08-08T00:09Z), 206 `for slot a`, 0 slot b,
247 `slot a :8404`, 128 `SWITCH status=ok`, 0 `SWITCH status=failed`.

## R5 — the cause: marker PREFIX collision

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -n "BARKPARK_SITE_ROUTE:search" /etc/caddy/Caddyfile; grep -q "BARKPARK_SITE_ROUTE:search" /etc/caddy/Caddyfile; echo rc=$?; awk -v m="BARKPARK_SITE_ROUTE:search" "index(\$0,m){inb=1} inb&&match(\$0,/reverse_proxy[[:space:]]+localhost:[0-9]+/){p=substr(\$0,RSTART,RLENGTH);sub(/.*localhost:/,\"\",p);print p;exit}" /etc/caddy/Caddyfile'
```
2026-08-08: the bare marker `BARKPARK_SITE_ROUTE:search` matches lines 34 and 43
(`search-capstone`, `search-ember`); `grep -q` rc=0; the emulated `active_caddy_port()` returns
**8506** — `search-capstone`'s port, outside `search`'s own pair (8404/8405).

## R6 — port-pair conformance of every node site

`.previous` gives the previous slot+port; the Caddyfile marker block gives the active port; the
deterministic derivation is `8300 + (cksum(slug) % 800) * 2`.

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -n -A6 "BARKPARK_SITE_ROUTE" /etc/caddy/Caddyfile | grep reverse_proxy; for f in /opt/barkpark/sites/*/.previous; do echo "$f: $(cat $f)"; done; ss -ltnp'
for s in next-capstone search-capstone search-ember next-proof nodeproof-20260718-73191 search; do b=$(( 8300 + ( $(printf '%s' "$s" | cksum | cut -d' ' -f1) % 800 ) * 2 )); echo "$s pair=($b,$((b+1)))"; done
```
2026-08-08: 5/5 ARMED node sites in-pair (8584/8506/9809/9647/9754). One out-of-pair read: `search`
(8506 vs pair 8404/8405), caused by R5, not by the global sed the file's comment warns about.

## R7 — both engines' self-tests, on this tree

```
cd /Volumes/SATECHI/github/barkpark && bash deploy/site-deploy.sh --self-test; echo rc=$?
cd /Volumes/SATECHI/github/barkpark && bash deploy/site-deploy-node.sh --self-test; echo rc=$?
```
2026-08-08: 128/128 PASS rc=0 and 108/108 PASS rc=0. Neither suite covers a slug that is a
STRICT PREFIX of an already-armed slug — that is the gap R5 exploits.

## Line-number correction

The brief cites `site-deploy.sh:2231-2233` for the no-slot-anchor return-0 path. The file is 1,365
lines. The real path is `deploy/site-deploy.sh:1309-1312`. The node twin is
`deploy/site-deploy-node.sh:262-265` (returns 1 there, fail-closed).
