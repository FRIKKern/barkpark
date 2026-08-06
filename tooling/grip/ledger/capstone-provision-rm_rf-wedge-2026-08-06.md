# search-capstone: the provision `rm_rf` wedge — re-derivation recipes

Wave: deploy-truth-wave-2-2026-08-06 · verifier assignment `capstone-root-cause-and-green-proof`
Box: guerrilla 157.180.90.121 (`ssh -i ~/.ssh/barkpark_indx root@157.180.90.121`)

## Claim 1 — the producer is `Provisioner.materialize/4`'s `File.rm_rf!(src)`, which raised EEXIST mid-delete

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --since "2026-08-05 21:00" --until "2026-08-05 21:10" --no-pager -o short-iso | grep "provision failed"'

Expect: `%File.Error{reason: :eexist, path: "/opt/barkpark/sites/search-capstone/src", action: "remove files and directories recursively from"}` at 21:01:45.716.

Code: `git show origin/main:api/lib/barkpark/sites/provisioner.ex | sed -n '140,165p'` — `rm_rf!(src)` sits BETWEEN a successful `cp_r!` into `src.partial` and the `rename`. A raise there leaves `src` half-deleted; the moduledoc's "never a half-materialized `src`" (line ~47) is false for this window.

## Claim 2 — exactly 44 template files were destroyed; only search-capstone

    ssh … 'cd /opt/barkpark/templates/search-starter && find . -type f | sed "s|^\./||" | sort > /tmp/tpl.txt
            cd /opt/barkpark/sites/search-capstone/src && find . -type f -not -path "./node_modules/*" -not -path "./.next/*" | sed "s|^\./||" | sort > /tmp/cap.txt
            comm -23 /tmp/tpl.txt /tmp/cap.txt | wc -l'   # => 44

Same recipe against `search-ember/src` and `search/src` => 0 missing. `next-env.d.ts` is NOT in the template (build-generated) — do not list it as destroyed.

## Claim 3 — the marker makes the wedge PERMANENT

    ssh … 'cat /opt/barkpark/sites/search-capstone/src/.bp-provisioned'
    ssh … 'python3 -c "
import hashlib,os
root=\"/opt/barkpark/templates/search-starter\"
fs=sorted(os.path.relpath(os.path.join(dp,f),root) for dp,_,fns in os.walk(root) for f in fns)
h=hashlib.sha256()
[ (h.update(r.encode()), h.update(open(os.path.join(root,r),\"rb\").read())) for r in fs ]
print(h.hexdigest(), len(fs))"'

Both print `a59bdbc7f865934db09a04d1e75fdf10de06da7036fb0f295b873a502253facd`, 66 files. `provisioned_fresh?/3` therefore returns true forever and every later deploy skips materialize — self-heal defeated because the digest is of the TEMPLATE, never of `src`.

## Claim 4 — repairing the checkout builds GREEN, and STAGE's precondition holds

    ssh … 'rm -rf /root/capstone-repair && cp -al /opt/barkpark/sites/search-capstone/src /root/capstone-repair && rm -rf /root/capstone-repair/.next
            cd /opt/barkpark/templates/search-starter && tar cf - components lib schemas scripts next.config.mjs README.md DEPLOYING.md .env.example | (cd /root/capstone-repair && tar xf -)
            cd /root/capstone-repair && export PATH=/root/.asdf/installs/nodejs/26.5.0/bin:$PATH BARKPARK_SITE_BASE=/sites/search-capstone/
            npm run build; echo EXIT=$?; ls .next/standalone/server.js .next/static'

Expect `✓ Compiled successfully`, `EXIT=0`, `server.js` present (STAGE's `exit 13` guard at deploy/site-deploy-node.sh:1541 is satisfied).

## Claim 5 — the SECOND failure is HEALTH (exit 14), not STAGE, and it also afflicts the LIVE release

    ssh … 'for p in 8507 18606; do curl -sL --max-redirs 2 -o /dev/null -w "$p code=%{http_code} t=%{time_total}\n" --connect-timeout 2 --max-time 8 http://127.0.0.1:$p/sites/search-capstone/; done'
    # drop --max-time to see the true code

8507 = the live, previously-GREEN capstone release: `308` under the gate's 8 s ceiling, `200` at ~48 s without it. The repaired build behaves identically. Sibling search-ember slots (8584/8585) render in ~1.3 s on the same box at the same moment, so this is capstone-specific, not host load. `health_gate_node` breaks only on 200 and uses `--max-time 8` per attempt (20 attempts) => `exit 14`.

## Fixture

`/root/CAPSTONE-FAIL.log` (30993 bytes) on the box is the recorded 2026-08-05 22:54 failing build. It was NOT destroyed by this investigation — the live `src` was never touched; all work happened on `/root/capstone-repair` (hardlinked copy). Decide should commit it as the wave's fixture.
