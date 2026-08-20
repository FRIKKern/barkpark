# Re-derivation recipes — /v1/graph 500-attribution + BEAM RSS, guerrilla 2026-08-07 03:00–03:11Z

Wave: deploy-reliability wave 9, verifier v11-graph-500-attribution.
Box: guerrilla 157.180.90.121. Active slot at time of run: **green** (pid 464677, started 02:35:02Z, port **4001**).
origin/main: 95642c5500119d5ef5bb938a47516cacb5ab0f05.

## 0. Resolve the active slot FIRST (never assume, never `-u barkpark`)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for s in blue green; do echo -n "$s: "; systemctl is-active barkpark-slot@$s.service; done'

## 1. 500-attribution — join by request_id, NEVER `grep -B3`

`grep -B3 "Sent 500"` is WRONG on this journal: concurrent requests interleave, so the
preceding lines belong to other requests. It reported `19 site-deploy / 8 graph`;
the request_id join reports `27 graph / 18 search / 3 query`. Same log, opposite answer.

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /tmp;
      journalctl -u barkpark-slot@green.service --since "6 hours ago" --no-pager > g6.log;
      awk "/Sent 500/ {for(i=1;i<=NF;i++) if(\$i ~ /^request_id=/) {sub(/request_id=/,\"\",\$i); print \$i}}" g6.log | sort -u > ids500.txt;
      grep -F -f ids500.txt g6.log | grep -oE "request_id=[^ ]+ \[info\] (GET|POST|PUT|DELETE|PATCH) [^ ]+" |
        awk "{print \$3, \$4}" | sed -E "s#/w/[^/]+/p/[^/]+##" | sort | uniq -c | sort -rn'

Also take the time distribution — the 6 h total is NOT a rate:

    ... 'grep "Sent 500" /tmp/g6.log | cut -c1-15 | sed "s/:..$//" | uniq -c'

## 2. Does one /v1/graph call move BEAM RSS?

The prescribed one-shot curl CANNOT work as written: `BARKPARK_HEALTH_TOKEN` is **absent**
from `/opt/barkpark/.env` (grep matches nothing → empty Bearer → 401), and the slot listens
on **4001**, not 4000 (`curl localhost:4000` → `000`). An empty-token 401 in 7 ms would have
looked like a clean measurement of "no effect".

Instead: sample `/proc/<beam>/status` at 1 Hz and align against naturally-occurring graph
calls in the journal. Baseline drifts ±70 MB in 6 s under load, so a bare before/after pair
is unmeasurable — you need the 1 Hz series and the call timestamps side by side.

    P=$(systemctl show -p MainPID --value barkpark-slot@green.service)
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "for i in \$(seq 1 180); do echo \"\$(date -u +%H:%M:%S) \$(awk '/VmRSS/{print \$2}' /proc/$P/status)\"; sleep 1; done > /tmp/rss2.txt"
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl -u barkpark-slot@green.service --since "03:07:45" --until "03:10:50" --no-pager | grep "GET /v1/graph" | cut -c1-15'

Then window the series ±6 s around each graph start. Take a CONTROL window with no graph
call — the box also spikes to 1.47 GB without one, so "graph is the only spiker" is false.

## 3. Verdict blindness (source, origin/main — not the 528-commit-behind worktree)

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '50,120p'   # attentionStatus reads ZERO vitals
    git show origin/main:internal/agent/report.go | grep -nE 'json:"'          # beam_pss_bytes / err_5xx_per_s / p95_ms ARE reported
    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '1077,1200p'  # derive_graph_corpus materialization
