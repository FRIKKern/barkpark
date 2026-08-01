# Re-derivation recipes — cch-w18 attention/tablet band ownership (W18 verify, 2026-08-01)

Everything below is driven against an EXPORT of `origin/main`, never a worktree.
`cloud/priv/static/__preview__/breakpoint-sweep.mjs` does not exist in the primary
checkout at the time of writing (it is on `origin/main` only) — export, don't `cd`.

## R0 — export merged main and build the two candidate trees

```bash
P=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $P
M=$(mktemp -d) && cp -R $P/cloud $M/            # candidate M2 (.instance-card-head)
cat >> $M/cloud/priv/static/app.css <<'EOF'
.instance-card-head { flex-wrap: wrap; }
.instance-card-head .status-pill { white-space: normal; height: auto; min-height: 24px; padding-top: 2px; padding-bottom: 2px; align-items: flex-start; }
.instance-card-head .status-pill-dot { margin-top: 5.5px; }
.instance-card-head .status-pill-detail { overflow: visible; text-overflow: clip; }
EOF
B=$(mktemp -d) && cp -R $M/cloud $B/            # candidate M2 + T (tablet host)
cat >> $B/cloud/priv/static/app.css <<'EOF'
.attention-row .status-pill { white-space: normal; height: auto; min-height: 24px; padding-top: 2px; padding-bottom: 2px; align-items: flex-start; }
.attention-row .status-pill-dot { margin-top: 5.5px; }
.attention-row .status-pill-detail { overflow: visible; text-overflow: clip; }
EOF
```

M2 is D197's ratified remedy reconstructed verbatim from its own prose (`flex-wrap`
plus three wrapper-scoped rules cloned from the merged `.fleet-status` precedent at
`app.css:5332-5341`). T is the same recipe re-hosted — the FOURTH copy of the
five/six-declaration wrap recipe in this file.

## R1 — the bespoke driver (both hosts, both scenarios, both themes, 9 widths)

Script: `<scratchpad>/w18attn/attn-probe.mjs` (CDP mechanics copied verbatim from
`breakpoint-sweep.mjs`: `Cdp` class, fresh target per cell, served-bytes ==
disk-bytes refusal). It measures, per `.attention-row` and per `.instance-card-head`:
`detail.clientWidth/scrollWidth`, `pill.scrollHeight/clientHeight`,
`pill.getBoundingClientRect().height/bottom`, `detail.bottom - pill.bottom`, plus
`documentElement.scrollWidth/clientWidth`.

```bash
export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
OUT_JSON=pristine.json node attn-probe.mjs $P/cloud/priv/static 4471 PRISTINE
OUT_JSON=m2.json       node attn-probe.mjs $M/cloud/priv/static 4472 M2
OUT_JSON=both.json     node attn-probe.mjs $B/cloud/priv/static 4473 BOTH
```

Axes: `WIDTHS=320,360,390,430,620,720,768,769,800` x
`SCENS=overview-attention,mixed-fleet` x `{light,dark}` = 36 cells per tree.

## R2 — the four decisive comparisons

```bash
node -e '
const P=require("./pristine.json"),M=require("./m2.json"),B=require("./both.json");
const k=r=>r.scen+"|"+r.theme+"|"+r.width, mm=new Map(M.map(r=>[k(r),r])), bb=new Map(B.map(r=>[k(r),r]));
// 1. does M2 touch .attention-row anywhere?
console.log("attention diffs P->M2:", P.filter(p=>JSON.stringify(p.attention)!==JSON.stringify(mm.get(k(p)).attention)).length);
// 2. true worst attention cell on merged main, scenario-named
const w=[];for(const p of P)for(const a of p.attention)if(a.dClient<a.dScroll)w.push([+(100*(1-a.dClient/a.dScroll)).toFixed(1),a.dClient+"/"+a.dScroll,k(p),a.text]);
w.sort((x,y)=>y[0]-x[0]);console.log(w.slice(0,4));
// 3. residual clips after each candidate
const res=(T,f)=>T.flatMap(r=>f(r).filter(a=>a.dClient<a.dScroll)).length;
console.log("head clips left after M2:",res(M,r=>r.cardHead),"attn clips left after T:",res(B,r=>r.attention));
// 4. does T disturb M2s host GEOMETRY (as opposed to page position)?
const strip=a=>a.map(({i,text,dClient,dScroll,pClientH,pScrollH,pH,below})=>({i,text,dClient,dScroll,pClientH,pScrollH,pH,below}));
console.log("geometry diffs M2->M2+T:", M.filter(m=>JSON.stringify(strip(m.cardHead))!==JSON.stringify(strip(bb.get(k(m)).cardHead))).length,
            "position-only:", M.filter(m=>JSON.stringify(m.cardHead)!==JSON.stringify(bb.get(k(m)).cardHead)).length);'
```

Expected on 2026-08-01 merged main (`b266a1a5e`): `0` · worst =
`41.4% 139/237 mixed-fleet|*|320 "Payment failed — subscription past due"` ·
`0` and `0` · `0` geometry diffs and `8` position-only diffs.

## R3 — the baseline deltas, measured not arithmetic (D158 recipe)

```bash
(cd $M && node cloud/priv/static/__preview__/cssom-parity.mjs 2>&1 | tail -8)   # names 1256
(cd $B && node cloud/priv/static/__preview__/cssom-parity.mjs 2>&1 | tail -8)   # names 1259
grep -E '^[0-9]+$' $P/cloud/priv/static/__preview__/cssom-heads.baseline        # 1252
```

M2 = +4 (confirms D202). T = +3 (1259 − 1256). Both carry a sidecar hunk, so they
serialise through the one-hand queue even though their CSS never collides.

## R4 — the sweep cannot see either defect's own scenario

```bash
(cd $P && CHROME=... OVERFLOW_GUARD_PORT=4383 node cloud/priv/static/__preview__/breakpoint-sweep.mjs \
   --render --widths 320,620,720,768,769,800 --cell overview-attention 2>&1 | tail -3)
grep -n '"overview-attention"' $P/cloud/priv/static/__preview__/breakpoint-sweep.mjs
git grep -c instance-card-head origin/main -- cloud/priv/static/__preview__ .github scripts
```

The sweep exits 2 (`--cell named 1 cell that does not exist`) — `overview-attention`
is a RESIDUE entry at `breakpoint-sweep.mjs:421`, rendered by no cell. And
`instance-card-head` returns ZERO hits over every instrument, confirming D198's
coverage hole on merged bytes.

## R5 — the guard is green on the defect AND green on both remedies

```bash
(cd $P && CHROME=... OVERFLOW_GUARD_PORT=4501 node cloud/priv/static/__preview__/overflow-guard.mjs; echo EXIT=$?)
(cd $B && CHROME=... OVERFLOW_GUARD_PORT=4502 node cloud/priv/static/__preview__/overflow-guard.mjs; echo EXIT=$?)
```

Both `OVERFLOW GUARD PASS`, exit 0. Its `GR109-attention-row-dead-rule` leg drives
`.attention-row` at exactly 768 and 900 and asserts `flex-direction`/`align-items`
only — it never enters the 769-899 band where the tablet clip lives, and it never
looks at text. A remedy landing without extending a leg ships unguarded.
