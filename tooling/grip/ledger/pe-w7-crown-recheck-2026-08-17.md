# pe-w7 crown-recheck re-derivation recipes (2026-08-17)

Verifier [crown-recheck] on Paper Excellence wave 7. Not committed by me — Decide commits one phase later.

## Crown gate #11889 state
```
git fetch origin && git log origin/main --oneline | grep -iE '11889'   # => EMPTY (not merged)
gh pr view 11889 --json state,mergeStateStatus,mergedAt                 # => OPEN / BLOCKED / null
```
Verdict: crown NOT lit. All three round-2 crown briefs stay parked.

## Framed CSS rule count (css-freshness gate precondition)
File is MINIFIED single-line — `grep -c` returns 1 for any match (lies). Use `grep -o | wc -l`:
```
git show origin/main:api/priv/static/assets/bp-paper-editor.css | grep -o 'bp-section--framed' | wc -l   # => 0 (main, unfreshened, 11889 unmerged)
git show origin/loop-epic/studio-canvas-keeps-and-shows-the-sectio-1:api/priv/static/assets/bp-paper-editor.css | grep -o 'bp-section--framed' | wc -l   # => 2 on the branch (NOT 3)
```
Note for Decide: branch carries 2 framed class-string occurrences, gate brief expected 3. Reconcile before dispatching css-freshness brief.

## hobby-hardening-capstone top-level style = article
`bp paper pull` fails (bpml_unprintable: toc block); doc HTTP fetch 404s (nested scope). Read style off the LIVE RENDER instead:
```
curl -s https://guerrilla.barkpark.cloud/papers/hobby-hardening-capstone | grep -oE 'class="bp-paper-shell[^"]*"'
# => class="bp-paper-shell bp-paper-surface bp-paper-article"   -> bp-paper-article == style:article
```

## framed-RENDERED count still 0 (strip inlined CSS first)
Naive grep gives 3 — all 3 fall INSIDE the single <style> span (bytes 63904-190780; hits at 86705/87295/87418). Strip then match:
```
curl -s https://guerrilla.barkpark.cloud/papers/hobby-hardening-capstone > /tmp/hhc.html
perl -0777 -pe 's/<style\b.*?</style>//gis' /tmp/hhc.html | grep -o 'bp-section--framed' | wc -l   # => 0
```
