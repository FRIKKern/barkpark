# cch-w7 Movement 0 — gr-* band sweep, re-derivation recipes

Verifier `movement0-sweep-gr`, 2026-07-28. Tree: `origin/main` @ `f38c01920985f6fc1581229dacb713345e4783a5`
(fetched at run start). Host: primary checkout, load not measured; every command below is read-only.

## 0. Materialise the tree once (all `<file>` reads below are against THIS, not the worktree)

```
git fetch origin -q && git rev-parse origin/main
rm -rf /tmp/mainx && mkdir -p /tmp/mainx && git archive origin/main cloud internal scripts docs api .claude design Makefile | tar -x -C /tmp/mainx
```

## 1. Roster — paginated offset-walk (NEVER a single limit=1000 call)

```
python3 - <<'EOF'
import json,os,urllib.request,time
tok=json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))["token"]
docs=[];off=0
while True:
    for _ in range(4):
        try:
            r=urllib.request.Request(f"https://guerrilla.barkpark.cloud/v1/tasks?limit=200&offset={off}",headers={"Authorization":"Bearer "+tok})
            d=json.load(urllib.request.urlopen(r,timeout=60)); break
        except Exception as e: print("retry",off,e); time.sleep(3); d=None
    if d is None or 'docs' not in d: raise SystemExit("fail at "+str(off))
    n=len(d['docs']); docs+=d['docs']; print(off,n,flush=True)
    if n<200: break
    off+=200
json.dump(docs,open("/tmp/all_tasks.json","w")); print("TOTAL",len(docs))
EOF
```
3480 rows in 18 pages. One transient HTTP 500 at offset 800 (`request_id GMZzM8m5mDMvLSkAGHnx`); a bare
retry returned 200 in 1.9s. A walk without retry silently truncates — keep the retry.

Epic roster: `parent_id == "cloud-console-hardening-epic"` → 135 direct children
(83 open / 41 done / 9 cancelled / 2 considering). Of the 83 open: 50 `gr-*`, 29 `cch-*`, 4 foreign-prefix.
Three more open `gr-*` sit one level down under `gr-p5r5-successor-seal` (53 in the gr band).

## 2. Per-row adjudication recipes (content, never a cited line number)

| row | command | today's output |
|---|---|---|
| gr-blk-revoke-harness-gap | `grep -n "DELETE /v1/account/sessions" /tmp/mainx/cloud/priv/static/__preview__/scenarios.mjs` | matchers + 404 miss arm present |
| gr-blk-smoke-click-inert | `grep -n "click()" /tmp/mainx/cloud/priv/static/__preview__/smoke.mjs` | `click() { return el.dispatchEvent(...) }` |
| gr-blk-oauth-head-mint | `grep -n refuse_head_on_side_effecting_gets /tmp/mainx/cloud/lib/barkpark_cloud/web/router.ex` | fence present |
| gr-backlog-provider-reconnect | `sed -n '2033,2064p' /tmp/mainx/cloud/priv/static/app.js` | "EVERY available kind is selectable … a credential ROTATION" |
| gr-blk-ledger-close-bypass-audit | `grep -n ensure_task_close_is_cas /tmp/mainx/api/lib/barkpark/content/mutations.ex` | 4 call sites (177/268/312/341) |
| gr-blk-primary-checkout-reconcile | `git status --porcelain \| wc -l; git rev-list --count origin/main..HEAD` | 3 untracked (this wave's ledger), ahead 0 |
| gr-backlog-e02-deploy-actor | `grep -n "RATIFY" /tmp/mainx/.claude/workflows/bp-cloud-console-hardening-charter.md` | :429 "**RATIFY TRIGGER-ONLY**" |
| gr-blk-worktree-registry-bloat | `git worktree prune --dry-run -v \| wc -l; ls .git/worktrees \| wc -l` | 0 prunable / 1553 registered |
| gr-bl-tasks-route-parent-filter-ignored | `curl -s ".../v1/tasks?limit=200&filter%5Bparent_id%5D=cloud-console-hardening-epic"` | 200 rows, 11+ distinct parents |
| gr-bl-close-time-audit-vacuous-green | `curl -s .../v1/tasks/cloud-console-hardening-epic \| jq '.doc.children[0]\|keys'` | no `updated_at` |
| gr-bl-task-move-noop-help-drift | `curl -s .../v1/capabilities \| grep -c reparented` | 1 — summary still unconditional |
| gr-bl-reap-orphaned-preview-port-squatters | `lsof -nP -iTCP:4199 -sTCP:LISTEN` | empty (exit 1) — squatter gone |
| gr-backlog-css-check-missing-classes | `cd /tmp/mainx/cloud/priv/static && node __css_check.mjs; echo $?` | exit 0, `R3 1 known gap(s) … owned by gr-backlog-css-check-missing-classes` |

## 3. Merge SHAs used, all ancestor-verified

```
for s in 8c9c116c5 26acc7a91 0ed73651f 2a6b673cc 515f14fdd a893c3821; do
  git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR :: $(git log -1 --format=%s $s)"; done
```
Branch SHA control (standing law 1): `4b989a650` (the click-oracle branch commit) reads NOT-ancestor while its
squash `8c9c116c5` reads ANCESTOR — cite merge SHAs only.
