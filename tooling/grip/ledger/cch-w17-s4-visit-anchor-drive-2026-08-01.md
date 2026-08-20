# Re-derivation recipe — s4 (Visit link gated on deployment), driven on origin/main

Boot the SHIPPED preview bytes from origin/main (never the worktree) and drive
Chrome at the scenario's OWN deep link. A `?scen=` with no hash renders the
default route and every anchor count reads 0 — a false green.

```bash
cd /Volumes/SATECHI/github/barkpark
D=$(mktemp -d) && git archive origin/main cloud/priv/static | tar -x -C $D
node $D/cloud/priv/static/__preview__/serve.mjs --port 4302 &
sleep 2
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# LIST (5 rows, mixed freshness states) — pill vs anchor, per row
"$CH" --headless=new --disable-gpu --window-size=390,900 --virtual-time-budget=8000 \
  --dump-dom 'http://localhost:4302/?scen=sites&theme=light#sites' > /tmp/dom-sites.html

# INSTANCE workspace — the SAME sitesListRows rendered through siteRow (app.js:7534)
"$CH" --headless=new --disable-gpu --window-size=390,900 --virtual-time-budget=8000 \
  --dump-dom 'http://localhost:4302/?scen=sites&theme=light#instance/5b2c1e00-0000-4000-8000-0000000000a1' \
  > /tmp/dom-inst.html

# DETAIL, never-deployed class (all three behave identically)
for id in cb cc cd; do :; done   # bound=…cb unknown=…cc mismatch=…cd
"$CH" --headless=new --disable-gpu --window-size=390,900 --virtual-time-budget=8000 \
  --dump-dom 'http://localhost:4302/?scen=site-binding-bound&theme=light#site/5b2c1e00-0000-4000-8000-0000000000cb' \
  > /tmp/dom-bound.html

# DETAIL, positive (live current deployment) — the surviving-anchor case
"$CH" --headless=new --disable-gpu --window-size=390,900 --virtual-time-budget=8000 \
  --dump-dom 'http://localhost:4302/?scen=env-editor&theme=light#site/5b2c1e00-0000-4000-8000-0000000000c1' \
  > /tmp/dom-live.html
```

Counters that decide:

```bash
grep -o 'class="site-open"' /tmp/dom-sites.html | wc -l     # 5 of 5 rows
grep -o 'Not deployed'      /tmp/dom-sites.html | wc -l     # 1
grep -o 'btn btn-ghost btn-sm site-open' /tmp/dom-bound.html | wc -l  # 1
grep -o 'dep-pill' /tmp/dom-bound.html | wc -l              # 0  → chip absent
grep -o '<h1 class="site-title">[^!]\{0,120\}' /tmp/dom-live.html     # chip Live present
```

ASSERT DOM SIZE BEFORE TRUSTING A ZERO: a shell-only render is ~35.4KB with
`site-row` count 0. A real render is 36.8–43.9KB.
