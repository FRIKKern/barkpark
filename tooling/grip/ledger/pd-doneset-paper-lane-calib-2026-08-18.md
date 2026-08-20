# PD done-set audit — paper-lane + calibration re-derivation (2026-08-18)

Re-derives the paper-lane verdict for the pd-block-wishlist done-set audit.

## Sweep: two Paper rows publish under published perspective (proves _draft=false)

```
TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
for s in block-wishlist-100 block-wishlist-100-review; do
  curl -s -o /dev/null -w "$s %{http_code}\n" \
    "https://guerrilla.barkpark.cloud/w/default/p/default/d/production/papers/$s/source?perspective=published" \
    -H "Authorization: Bearer $TOKEN"
done
# expect: both 200. A draft returns 404 under published perspective
# (the /papers/<slug> metadata path 404s regardless — use /source).
```

## Content substance

```
# block-wishlist-100: 100 distinct candidates B001..B100
curl -s ".../papers/block-wishlist-100/source?perspective=published" -H "Authorization: Bearer $TOKEN" \
 | python3 -c "import sys,json,re;b=json.dumps(json.load(sys.stdin)['source']);n=sorted(set(int(t) for t in re.findall(r'\\bB(\\d{3})\\b',b)));print(len(n),n[0],n[-1])"
# expect: 100 1 100

# block-wishlist-100-review: S/A/B/C tiers + counts 12/32/43/13 all present, sum=100
```

## Calibration sample (3 clean-remainder rows: bespoke close_reason + met==total)

```
for t in pbw-w1-wishlist-100-paper pbw-w1-usefulness-review-paper pbw-w1-stale-comment-truth; do
  bp task get $t -o json | python3 -c "import sys,json;c=json.load(sys.stdin)['doc']['content'];ac=c.get('acceptance_criteria') or [];print('$t',len(ac),sum(1 for x in ac if x.get('met')),repr(c.get('close_reason'))[:60])"
done
# expect: 5/5, 5/5, 3/3 — all met==total; close_reasons bespoke (NOT the
# 'Historical completion reconciled from N/N met acceptance criteria' boilerplate).
```

VERDICT: paper-lane TRUE. Zero reopens from this lane.
