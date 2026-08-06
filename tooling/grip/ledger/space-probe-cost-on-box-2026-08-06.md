# Re-derivation recipe — space-probe cost on guerrilla (2026-08-06)

Box: guerrilla 157.180.90.121, `~/.ssh/barkpark_indx`. All probes run with a hard
`timeout` and `nice -n 19 ionice -c3` (BP_NICE precedent: deploy/site-deploy.sh:1213).

## A. Price every named-consumer probe (the whole measurement in one shot)

```
ssh -o BatchMode=yes -o ConnectTimeout=15 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'echo ==JOURNAL==; time timeout 60 journalctl --disk-usage;
   echo ==INODES==; time timeout 120 find /opt/barkpark/sites -xdev | wc -l;
   echo ==DU2==; time timeout 300 nice -n 19 ionice -c3 du -x --max-depth=2 /opt/barkpark/sites;
   echo ==PERSLUG==; timeout 300 nice -n 19 ionice -c3 du -sh /opt/barkpark/sites/*/src/node_modules /opt/barkpark/sites/*/src/.next /opt/barkpark/sites/*/releases 2>/dev/null | sort -h | tail -25;
   echo ==ORPHANS==; ls -d /opt/barkpark/sites/*/src.* 2>/dev/null;
   echo ==ROOTFS==; df -h /; du -sh /opt/barkpark/sites /var/log/journal 2>/dev/null'
```

Repeat-timing form (cold vs warm, 3 samples each):

```
ssh ... 'for i in 1 2 3; do /usr/bin/time -f "du-depth2 %e s" nice -n 19 ionice -c3 du -x --max-depth=2 /opt/barkpark/sites >/dev/null; done'
```

## B. Where the disk actually goes (sites is NOT the top consumer)

```
ssh ... 'nice -n 19 ionice -c3 du -x --max-depth=1 / 2>/dev/null | sort -n | tail -15;
         nice -n 19 ionice -c3 du -x --max-depth=2 /var 2>/dev/null | sort -n | tail -12;
         nice -n 19 ionice -c3 du -x --max-depth=2 /root 2>/dev/null | sort -n | tail -10;
         su - postgres -c "psql -tAc \"select pg_size_pretty(pg_database_size(datname)), datname from pg_database order by pg_database_size(datname) desc limit 5\""'
```

## C. Is the fleet build gate holding? (building vs queued)

```
ssh ... 'systemctl list-units "bp-site-build*" --no-legend --all;
         lslocks | grep -i barkpark;
         ps -eo pid,ppid,stat,pcpu,rss,etime,args --sort=-pcpu | grep -E "site-deploy|npm|node|flock" | grep -v grep;
         systemd-cgtop -n1 -b --depth=2 | head -20'
```

A unit in `active running` whose cgroup holds 2 procs (`bash` + `flock -w 900 7`) and
~1.4 MB memory is QUEUED, not building. The builder is the unit whose cgroup carries
the npm/astro/next process tree (hundreds of MB).

## D. Swap, for the missing vital

```
ssh ... 'grep -i swap /proc/meminfo'
```
`SwapTotal`/`SwapFree` sit in the same file `memProcProbe` (cmd/barkpark-agent/main.go:217)
already reads — the swap vital is a second parse of an already-open file, not a new probe.
