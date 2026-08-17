# pe-w5 finale append map — re-derivation recipe (2026-08-17)

Verifier lane [finale-append-map]. Maps the exact `<section variant="framed">` append point for the
four flagship papers, whether D19's first-child-h2 beat rule bites, and the seal/incident banner text
Decide needs for the sealed-touch ruling. NOT committed by me — Decide commits.

## Re-derive the tail shape (last blocks + total count)

```
for s in eight-minute-erasure hobby-hardening-capstone paper-excellence-wave-3-2026-08-17 paper-excellence-wave-4-2026-08-17; do
  echo "=== $s ==="
  curl -s "https://guerrilla.barkpark.cloud/papers/$s/source?format=json" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);bs=d["source"]["blocks"];print("total",len(bs),"last3",[b.get("type") for b in bs[-3:]])'
done
```

NOTE: `?format=json` returns `{_rev,id,source,title}`; blocks live at `d["source"]["blocks"]`
(NOT `d["blocks"]` — the MUST-RUN one-liner in the brief slices a dict and TypeErrors).

## Re-derive banner text (seal / incident / correction callouts)

```
curl -s "https://guerrilla.barkpark.cloud/papers/<slug>/source?format=json" \
| python3 -c 'import sys,json,re
d=json.load(sys.stdin);bs=d["source"]["blocks"]
def t(b):
 o=[]
 def w(x):
  if isinstance(x,dict):
   if isinstance(x.get("value"),str):o.append(x["value"])
   for v in x.values():w(v)
  elif isinstance(x,list):
   for v in x:w(v)
 w(b);return " ".join(o)
for i,b in enumerate(bs):
 s=t(b)
 if re.search(r"seal|status:|incident|correction",s,re.I):print(i,b.get("type"),repr(b.get("title")),s[:300])'
```

## Findings (verified 2026-08-17 against guerrilla live)

| paper | total | last block | ends in section? | seal/incident? |
|---|---|---|---|---|
| eight-minute-erasure | 46 | [45] section (leads with h2 "VII · Declaration of peace") | YES | incident doctrine callout [44]; SENSITIVE (Heggemsnes Act apology) |
| hobby-hardening-capstone | 97 | [96] callout "What this run leaves behind" | no | none — cleanest target |
| paper-excellence-wave-3-2026-08-17 | 53 | [52] callout "Next wave / lead dispatch" | no | [46] "Status: SEALED" |
| paper-excellence-wave-4-2026-08-17 | 59 | [58] callout "Next wave" | no | [52] heading "...sealed"; [5] "Correction" warning |

Append is a top-level `source.blocks` push in every case; no neighbouring block edits.
D19 known one-liner BITES if the framed closer's first child is an h2: append a lede paragraph
before the heading, or accept the documented flat-leg beat loss ("document, don't fix").
