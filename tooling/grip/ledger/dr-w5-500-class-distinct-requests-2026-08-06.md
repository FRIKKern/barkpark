# Re-derivation recipes — guerrilla 500 census by DISTINCT request_id (2026-08-06)

Wave 5 verifier `500-class-distinct-requests`. Every row re-derives from scratch.

## R1 — capture the window (all later rows read /tmp/j.txt)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'journalctl -u "barkpark-slot@*" --since "-8h" --no-pager > /tmp/j.txt; wc -l /tmp/j.txt; grep -c "Sent 500" /tmp/j.txt'
```
Observed 2026-08-06 ~08:0xZ: 390158 lines, 6472 `Sent 500`.

## R2 — distinct-request_id 500 census, joined to path

One 500 emits ~20 stack lines but exactly ONE `Sent 500` line, so `Sent 500`
lines already ARE distinct requests (6472 lines -> 6472 distinct ids, verified).
Paths come from the `[info] <METHOD> <path>` line carrying the same request_id.

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'python3 - <<EOF
import re,collections
rx_req=re.compile(r"request_id=(\S+).*\[info\] (GET|POST|PUT|PATCH|DELETE) (\S+)")
rx_500=re.compile(r"request_id=(\S+).*\[info\] Sent 500")
req_path={};err=set()
for line in open("/tmp/j.txt",errors="replace"):
    m=rx_req.search(line)
    if m: req_path[m.group(1)]=m.group(3)
    m2=rx_500.search(line)
    if m2: err.add(m2.group(1))
def f(p):
    for pre in ("/v1/data","/v1/tasks","/v1/graph"):
        if p.startswith(pre): return pre+"*"
    return "other /v1/*" if p.startswith("/v1/") else "non-v1"
fam=collections.Counter();tot=collections.Counter()
for p in req_path.values(): tot[f(p)]+=1
for r in err:
    p=req_path.get(r)
    if p: fam[f(p)]+=1
for k in tot: print(k,fam[k],tot[k],round(100*fam[k]/tot[k],2))
EOF'
```
Observed: /v1/tasks* 2506/30338 = 8.26% | /v1/graph* 1451/2812 = 51.60% |
/v1/data* 245/3090 = 7.93% | other /v1/* 1238/45268 | non-v1 1031/49871.
Totals 6471 500s over 131379 path-resolved requests (1 id unmapped).

## R3 — cause census (the decisive one)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'python3 - <<EOF
import re
rx_id=re.compile(r"request_id=(\S+)")
err=set();dbconn=set();dbdrop=set()
for line in open("/tmp/j.txt",errors="replace"):
    if "Sent 500" in line:
        m=re.search(r"request_id=(\S+).*\[info\] Sent 500",line)
        if m: err.add(m.group(1))
    if "DBConnection.ConnectionError" in line:
        m=rx_id.search(line)
        if m:
            dbconn.add(m.group(1))
            if "connection not available and request was dropped" in line: dbdrop.add(m.group(1))
print(len(err),len(err&dbconn),len(err&dbdrop))
EOF'
```
Observed: 6472 / 6472 / 4746 -> 100.0% of 500s are DBConnection.ConnectionError,
73.3% are literal pool-queue drops.

## R4 — pool parameters actually in force

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'systemctl show barkpark-slot@green -p Environment -p EnvironmentFiles; grep -c POOL_SIZE /opt/barkpark/.env; grep -ic pool /opt/barkpark/.slots/green.env; nproc; free -m'
git show origin/main:api/config/runtime.exs | grep -n "pool_size\|queue_target\|queue_interval"
git grep -n "queue_target\|queue_interval" origin/main -- api/config
```
Observed: no POOL_SIZE / queue_* in any env source -> pool_size = 10 (runtime.exs
default), queue_target/queue_interval UNSET in prod (only api/config/test.exs sets
them) -> Ecto defaults 50 ms / 1000 ms. Host: 2 cores, 3819 MB RAM, 1142/2047 MB
swap in use.

## R5 — can ErrorJSON name the exception?

```
git show origin/main:api/lib/barkpark_web/controllers/error_json.ex
grep -n "reason" api/deps/phoenix/lib/phoenix/endpoint/render_errors.ex
grep -n "defp prepare_assigns" -A12 api/deps/phoenix/lib/phoenix/controller.ex
grep -n "render_assigns = Map.put" api/deps/phoenix/lib/phoenix/controller.ex
```
render_errors.ex:120-122 normalizes and passes `%{kind, reason, stack, status}`;
controller.ex:1019-1035 `prepare_assigns` merges those INTO conn.assigns; :989
`render_assigns = Map.put(conn.assigns, :conn, conn)`. So inside
`ErrorJSON.render/2` BOTH `assigns.reason` and `conn.assigns.reason` hold the
normalized exception. Today `reason_for_template/1` throws it away and returns
`{:error, :unknown}` for everything non-404.

## R6 — is there any 5xx counter on the beat?

```
git grep -nE "5xx|status_5|error_rate|http_errors" origin/main -- '*.go' '*.ex' '*.exs'
git show origin/main:api/lib/barkpark_web/request_stats.ex | grep -n "handle_event" -A6
```
Zero functional hits (all matches are prose comments about upstream HTTP).
`RequestStats.handle_event/4` binds `_meta` and inserts `{key, duration_ms}` —
the status code is present in the telemetry meta and DISCARDED. Beat carries
`req_per_s` + `p95_ms` (internal/agent/report.go:117-125) and no error axis.
