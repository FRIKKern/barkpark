# journald vs search-template D31 — re-derivation recipes (2026-08-06)

Verifier assignment `journald-vs-d31-ruling`, deploy-truth wave 2. Every row is a
literal command that re-derives the fact from scratch. Host: guerrilla
`157.180.90.121`, key `~/.ssh/barkpark_indx`.

| # | Fact | Command |
|---|---|---|
| 1 | D31's title and its "Why" (which is about DeployRunner's in-memory re-attach seam, NOT about operator log retrieval) | `git show origin/main:.claude/workflows/bp-search-template-charter.md \| sed -n '45p'` |
| 2 | journald holds 29/29 `Module not found` lines for a failed build, keyed by build_id in the unit name, 33,227 bytes | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -u bp-site-build-search-capstone-caf056f10a8b6837-1785972211879.service --no-pager -o cat \| grep -c "Module not found"'` |
| 3 | The FILE seam for the same slug is 0 bytes ~3 min later — truncated by the next launch | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'wc -c < /opt/barkpark/.bp-site-deploy-runs/search-capstone.log'` |
| 4 | 29-errors-per-unit across many distinct failed builds (no truncation, no rate-limit drops) | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl --since "2026-08-05 12:00" --grep "Module not found" --no-pager -o with-unit \| grep -oE "bp-site-build-[a-z0-9-]+\.service" \| sort \| uniq -c \| sort -rn \| head'` |
| 5 | journald rate-limit suppression count = 0 | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl --since "2026-08-04" --no-pager -o cat \| grep -c "Suppressed .* messages"'` |
| 6 | journald.conf is `[Journal]` only (no overrides) and there is no conf.d | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -vE "^#\|^$" /etc/systemd/journald.conf; ls /etc/systemd/journald.conf.d/'` |
| 7 | Effective bound: 3.6 G used on a 38 G root (systemd 255 default SystemMaxUse = min(10% fs, 4G) = 3.8 G) | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl --disk-usage; df -h /var/log; systemctl --version \| head -1'` |
| 8 | Retention floor = oldest retained entry, and it is queryable in 0.13 s | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl --no-pager -o short-iso \| head -1'` |
| 9 | OOM-killed unit DOES flush its output: 200/200 pre-kill lines + the partial line, `Result=oom-kill` | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cat >/tmp/oomprobe.sh <<EOF ... EOF; systemd-run --unit=bp-oom-probe-B --property=MemoryMax=20M --property=MemorySwapMax=0 --property=Type=oneshot /bin/bash /tmp/oomprobe.sh; sleep 12; systemctl show bp-oom-probe-B.service -p Result; journalctl -u bp-oom-probe-B.service -o cat \| grep -c "^LINE_"'` (full script body in the verifier proof) |
| 10 | Read-path cost: EXACT unit 0.16 s, unit GLOB 121 s | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'U=bp-site-build-search-capstone-caf056f10a8b6837-1785972211879.service; /usr/bin/time -f "%e s" journalctl -u $U --no-pager -o cat >/dev/null; /usr/bin/time -f "%e s" journalctl -u "bp-site-build-search-capstone-caf056f10a8b6837-*" --since "2026-08-05 23:20" --until "2026-08-05 23:50" --no-pager -o cat >/dev/null'` |
| 11 | ~9,495 distinct `bp-site-build-*` units retained in the journal | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -F _SYSTEMD_UNIT \| grep -c bp-site-build'` |
| 12 | The Deployment row has `build_id` and `build_log_url` but NO `unit_name` — the exact-unit fast path is not addressable from the row today | `git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex \| sed -n '100,130p'; git grep -ln unit_name origin/main -- cloud/` |
| 13 | The build tees raw stdout+stderr to `$BARKPARK_SITE_LOG_FILE` AND to the unit's stdout (hence both sinks hold it) | `git show origin/main:deploy/site-deploy-node.sh \| sed -n '1490,1520p'` |
| 14 | The log file is keyed on slug and truncated per launch | `git show origin/main:api/lib/barkpark/sites/deploy_runner.ex \| sed -n '520,545p'` |

Uncontested caveat for Decide: `journalctl -u <glob>` is a 121 s query and was still
unfinished after 25 min without a `--since` window; any journald read path MUST
persist the exact unit name (or the started-at ms) on the Deployment row.
