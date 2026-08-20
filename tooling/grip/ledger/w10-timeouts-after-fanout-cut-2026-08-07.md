# Re-derivation recipes — wave 10 verifier [timeouts-after-fanout-cut] — 2026-08-07 04:39–04:50Z

Host: guerrilla 157.180.90.121. ACTIVE SLOT AT READ TIME = **blue** (green stopped 04:14:29Z;
blue started 04:13:20Z). Everything below is UNIT-AGNOSTIC (`journalctl` with no `-u`) precisely
because the slot flipped mid-window — a per-slot read of either slot alone is wrong.

## R1 — active slot (never assume; wave 9's erratum)

    ssh -o ConnectTimeout=20 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl is-active barkpark-slot@blue barkpark-slot@green; ss -ltnp | grep :4000; \
       systemctl show barkpark-slot@blue -p ActiveEnterTimestamp,MainPID; \
       journalctl -u barkpark-slot@green --since "2026-08-07 03:00" --no-pager -o short-iso | grep -iE "Stopping|Stopped"'

## R2 — hourly DBConnection timeout series, unit-agnostic, 12 h

    ssh -o ConnectTimeout=30 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --since "-12h" --no-pager -o short-iso | grep DBConnection.ConnectionError | cut -c1-13 | sort | uniq -c'

## R3 — longest quiet gap (is the post-cut silence unprecedented?)

    ssh ... 'journalctl --since "-12h" --no-pager -o short-iso | grep DBConnection.ConnectionError | cut -c1-19 | sort' > to.txt
    python3 -c "import datetime;ts=[datetime.datetime.strptime(l.strip(),'%Y-%m-%dT%H:%M:%S') for l in open('to.txt') if l.strip()];ts.sort();print(sorted(((ts[i+1]-ts[i]).total_seconds()/60,str(ts[i]),str(ts[i+1])) for i in range(len(ts)-1))[::-1][:6]);print('last',ts[-1])"

## R4 — hourly request volume (normalizer: a zero with no traffic is not a zero)

    ssh ... 'journalctl --since "-12h" --no-pager -o short-iso | grep -E "Sent [0-9]{3}" | cut -c1-13 | sort | uniq -c'

## R5 — webhook fan-out: filter timing, hourly deliveries, like-for-like 47-min windows

    ssh ... "sudo -u postgres psql -d barkpark_prod -Atc \"select name, types::text, active, updated_at from webhooks order by updated_at desc limit 10;\""
    ssh ... "sudo -u postgres psql -d barkpark_prod -Atc \"select date_trunc('hour',inserted_at) h, count(*) from webhook_deliveries where inserted_at > now() - interval '10 hours' group by 1 order by 1;\""
    ssh ... "sudo -u postgres psql -d barkpark_prod -Atc \"select 'wh_post_47min', count(*) from webhook_deliveries where inserted_at >= '2026-08-07 03:47' and inserted_at < '2026-08-07 04:34' union all select 'wh_pre_47min_A', count(*) from webhook_deliveries where inserted_at >= '2026-08-07 03:00' and inserted_at < '2026-08-07 03:47' union all select 'docs_post_47', count(*) from documents where updated_at >= '2026-08-07 03:47' and updated_at < '2026-08-07 04:34' union all select 'docs_pre_47A', count(*) from documents where updated_at >= '2026-08-07 03:00' and updated_at < '2026-08-07 03:47';\""

## R6 — THE DISCRIMINATING READ: /v1/graph hourly, vs timeouts, vs webhooks

    ssh ... 'journalctl --since "-12h" --no-pager -o short-iso | grep "/v1/graph" | cut -c1-13 | sort | uniq -c'

    python3 -c "
    import statistics as s
    g=[202,468,461,439,60,0,66,84,80,156,76,148,16]   # /v1/graph  16h..04h
    t=[412,686,1391,664,55,0,100,5,11,112,2,88,0]     # timeouts   16h..04h
    w=[190,155,5,0,105,550,320,1015,305,887,35]       # webhooks   18h..04h
    def r(x,y):
        mx,my=s.mean(x),s.mean(y)
        return sum((a-mx)*(b-my) for a,b in zip(x,y))/((sum((a-mx)**2 for a in x)*sum((b-my)**2 for b in y))**.5)
    print(r(g,t), r(w,t[2:]), r(w,g[2:]))"

    # expected: 0.900   -0.139   0.061

## R7 — swap paging (the standing 'swap thrashing' hypothesis) is CHRONIC, not hourly-discriminating

    ssh ... 'LC_ALL=C sar -W -f /var/log/sysstat/sa06; LC_ALL=C sar -W -f /var/log/sysstat/sa07'

## Verdict this file supports

The timeouts stopping at 03:48:53Z is NOT attributable to the 03:43–03:46Z fan-out cut.
Three earlier gaps in the same 12 h (127.6 / 69.2 / 58.0 min) exceed the post-cut quiet;
hour 21:00Z served 4,300 requests with ZERO timeouts hours before the filter existed;
r(webhook deliveries, timeouts) = -0.139 while r(/v1/graph calls, timeouts) = +0.900.
The fan-out cut itself is real and larger than charted (31.7x amplification -> 1.84x).
