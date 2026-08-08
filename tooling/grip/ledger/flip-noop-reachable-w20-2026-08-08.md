# flip-noop-reachable — re-derivation recipes (wave 20 verifier)

Question: is the FLIP_FROM no-op reachable on the LIVE box, can `grep | head -1`
select a foreign vhost, and does any check row assert the post-flip probe, the
provisioner restart, or "the Caddyfile now contains TARGET_PORT"?

## L1 — the live boxes (running system)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'grep -n "localhost:400[01]" /etc/caddy/Caddyfile; \
       echo COUNT=$(grep -c "localhost:400[01]" /etc/caddy/Caddyfile); \
       echo SITEROUTE=$(grep -c BARKPARK_SITE_ROUTE /etc/caddy/Caddyfile)'
    # 2026-08-08: line 82 only, COUNT=1, SITEROUTE=9 (site ports 85xx/96xx/97xx/98xx)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'cat -n /etc/caddy/Caddyfile'
    # 2026-08-08: 3 lines, one vhost, one `reverse_proxy localhost:4100`

## L2 — mechanical reproduction against the real file

    scp -i ~/.ssh/barkpark_indx root@157.180.90.121:/etc/caddy/Caddyfile live.Caddyfile
    # A) normal flip touches exactly line 82; 4010/4020/85xx/9xxx untouched
    cp live.Caddyfile a.cf
    F=$(grep -oE 'localhost:(4000|4001)' a.cf | head -1 | cut -d: -f2)
    sed -i '' "s/localhost:$F/localhost:4000/g" a.cf; diff live.Caddyfile a.cf
    # B) remove the bare slot upstream -> FLIP_FROM falls back -> sed is a NO-OP
    grep -v 'reverse_proxy localhost:4001' live.Caddyfile > b.cf; cp b.cf b.before
    F=$(grep -oE 'localhost:(4000|4001)' b.cf | head -1 | cut -d: -f2); F=${F:-4000}
    sed -i '' "s/localhost:$F/localhost:4001/g" b.cf
    cmp -s b.before b.cf && echo NOOP
    caddy validate --adapter caddyfile --config b.cf && echo "validate PASS on a no-op"

## L2 — the harnesses

    bash deploy/instance-deploy_test.sh   # 251 PASS, rc 0, 18 cases
    bash deploy/cp-deploy_test.sh         # 7 PASS, rc 0, 66 lines, control-url pin ONLY
    grep -n 'Caddy flipped to' deploy/instance-deploy_test.sh   # cases 1,2 DO assert the upstream
    grep -n 'provisioner\|schemas = \|barkpark.cloud/ = ' deploy/*_test.sh  # no probe/restart assertion

## Serialization facts that bound the race

    grep -n 'flock' deploy/instance-deploy.sh   # fd 9 whole-run deploy lock at :137-144
    grep -n '^set -' deploy/cp-deploy.sh deploy/instance-deploy.sh  # `set -uo pipefail` — NO -e

## Prior art (already filed, do not re-file)

    bp task get pds-bl-w49-post-flip-curl-only-logged     # OPEN, gh #9644, PDS epic
    bp task get runtime-caddy-preserves-foreign-vhosts    # OPEN, site-runtime writer, customer boxes
