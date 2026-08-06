# Re-derivation recipes — wire-carried build log (deploy-truth wave 2)

Verifier assignment `wire-carried-log-arm-live`, 2026-08-06. Every row re-derives a
fact from scratch. Authority level noted per row.

## R1 — the `body["log"]` arm of normalize_report is UNREACHABLE (L2, source on main)

```
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1472,1496p'
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '705,720p;1595,1615p'
git show origin/main:api/lib/barkpark_web/controllers/site_deploy_controller.ex | sed -n '221,236p'
```

`cond` arm 1 is `is_list(body["stages"])`. Every box render path — idle
(`stages: []`), Port run (`stages: run.stages`), systemd reconstruct
(`stages: fold_status_file(...)`, `[]` on read error) — emits `stages` as a LIST.
Arm 1 therefore always wins. Arm 3 also fails on shape: `log` is rendered as a
LIST (`log: status.log`), and the arm guards `is_binary`.

## R2 — zero tests pin the arm (L2)

```
git show origin/main:cloud/test/barkpark_cloud/sites_deploy_test.exs | sed -n '942,1042p'
git grep -n '"log" =>' origin/main -- cloud/test/
```

Six `normalize_report/1` tests: five drive `"stages"`, two drive `"console"`,
none drive `"log"`. The single `"log" =>` hit repo-wide (`sites_deploy_test.exs:1082`)
is `BoxRelay.HTTP.rollback/2`'s own `TARGET_BUILD=` scraper, a different code path.

## R3 — executable refutation (L1 on the identical function)

`normalize_report/1` is byte-identical at HEAD and origin/main:

```
for r in HEAD origin/main; do git show "${r}:cloud/lib/barkpark_cloud/sites/deploy.ex" \
  | awk '/def normalize_report\(body\) when is_map/,/^  def normalize_report\(_\)/'; done | uniq -c
```

then, from `cloud/`:

```
CC=clang MIX_ENV=test mix run -e 'alias BarkparkCloud.Sites.Deploy
IO.inspect Deploy.normalize_report(%{"stages"=>[%{"name"=>"PLAN","status"=>"ok"}],"log"=>["npm error code 1"]}).stages
IO.inspect Deploy.normalize_report(%{"log"=>["npm error code 1"]}).stages
IO.inspect Deploy.normalize_report(%{"log"=>"npm error code 1\nModule not found"}).stages'
```

## R4 — the log file is RAW BUILD OUTPUT ONLY (L1, live box)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'grep -c BPSTAGE /opt/barkpark/.bp-site-deploy-runs/<slug>.log; \
   grep -c site-deploy /opt/barkpark/.bp-site-deploy-runs/<slug>.log'
```

Both 0 on a real 30,993-byte failing build. `parse_lines/1` looks only for
`BPSTAGE …` and `[site-deploy hh:mm:ss] STAGE:` narration, so even a reachable
arm would yield `[]`. Contract is stated at `deploy/site-deploy-node.sh:1487-1490`.

## R5 — the truncation window, measured live (L1)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'S=/opt/barkpark/.bp-site-deploy-runs/search-capstone; PREV=0
   for i in $(seq 1 90); do SZ=$(stat -c %s $S.log 2>/dev/null || echo 0)
     [ "$SZ" -gt 5000 ] && [ ! -s /tmp/cap.log ] && cp $S.log /tmp/cap.log && echo "CAPTURED $(date -u +%H:%M:%S) $SZ"
     [ "$SZ" = 0 ] && [ "$PREV" -gt 5000 ] && echo "TRUNCATED $(date -u +%H:%M:%S) was=$PREV" && break
     PREV=$SZ; sleep 5; done'
```

Observed twice: 23:23:01 full → 23:23:41 zero; 23:26:53 full → 23:27:33 zero.
Window ≤ 40 s. `fresh_run_files/1` (`deploy_runner.ex:543`) truncates the
slug-keyed file on the next launch; `search-capstone` re-deploys continuously.

## R6 — the 500-line wire cap has 78 % headroom, not overflow (L1)

```
ssh … 'wc -l < /tmp/cap.log; grep -avc "^[[:space:]]*$" /tmp/cap.log'
```

542 raw lines, **392 non-blank**. `read_log_tail/1` splits with `trim: true`
BEFORE `Enum.take(-500)`, so blanks never count and nothing is dropped for a
29-error build. Do NOT claim the headline is truncated off the wire — it is not.
Headroom is 108 non-blank lines; a ~40-error build would begin dropping the HEAD,
where the only tier-2-matching line lives (`Error: Turbopack build failed with 29
errors:` at raw line 16 / non-blank position 11).

## R7 — poll paths that never reach normalize_report (L2)

```
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '845,890p;1147,1163p'
```

Three `fail/2` calls bypass `normalize_report/1` entirely: budget exhausted
(`poll(ctx, _, 0, _)`), non-2xx/non-404 box refusal, and grace-exhausted
unreachable. `fail/2` writes only `failure_reason` + `detail` — no `console`,
no log. A fourth hole is the 404 `build_id_mismatch`: a superseded same-slug run
answers 404 forever, so the CP burns its budget and settles "did not finish in
time" having never seen the terminal report.
