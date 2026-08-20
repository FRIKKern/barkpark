# w45 — pds-charter-ledger-sweep: 59 arrivals split by VINTAGE, the fail-open proven twice, the selftest hostage cut

Derived 2026-08-03 against `origin/main` **0d1936832**. The charter blob is FROZEN at
`719925cabe4a872544b33d46d1fb61ce4434abe7` — unchanged since `a46ee2425` (#9353, the wave-44
charter), so `ab8c86b05` and `0d1936832` produce IDENTICAL sweep output. Adjudication table blob
`5382bfb1a3cda1429c8161f9dc16fa3ebc314d46`, untouched since `aa81a9b6e` (#9116).

Host was NOT quiet: load1 12→44 across the session. **No wall figure here is quotable.** USER+SYS
CPU is stable; the deterministic sleep floor below is read from source, not measured.

## Setup (every command below assumes this)

```bash
W=$(mktemp -d); cd "$W"
R=/Volumes/SATECHI/github/barkpark
git -C $R show origin/main:scripts/pds-charter-ledger-sweep.sh          > sw.sh
git -C $R show origin/main:scripts/pds-charter-ledger-adjudication.md   > adj.md
git -C $R show origin/main:.claude/workflows/bp-pds-charter.md          > ch.md
```

## 1. The corpus red, at the frozen blob

```bash
bash sw.sh --charter ch.md --table adj.md > run1.txt 2>&1; echo RC=$?   # -> RC=1 (run1.txt is reused in §3)
grep -E "^charter |^table |DERIVED DISPOSITION|candidate lines /|arrivals |stale adjud" run1.txt
#   charter : ch.md (12694 lines)
#   table   : adj.md (105 adjudicated rows)
#   2. DERIVED DISPOSITION VOCABULARY — 64 tokens (5 CORE + 60 charter idiom)
#   4. ADJUDICATION — 164 candidate lines / 113 slugs, ALL adjudicated
#   unresolved-claim arrivals : 59 · misclassified : 0 · stale adjudication rows : 0
```

## 2. THE ARRIVAL COUNT IS CORPUS-COUPLED — proven by running the SAME lens over older charters

```bash
for c in aa81a9b6e 4082a3947 a46ee2425; do
  git -C $R show $c:.claude/workflows/bp-pds-charter.md > ch_$c.md
  bash sw.sh --charter ch_$c.md --table adj.md 2>&1 |
    grep -E "DERIVED DISPOSITION|candidate lines /|unresolved-claim arrivals"
done
#  aa81a9b6e (adj.md's OWN base): 51 tokens · 105 candidates / 74 slugs · arrivals 0   RC=0
#  4082a3947 (wave-43 charter)  : 62 tokens · 150 candidates /102 slugs · arrivals 45  RC=1
#  a46ee2425 (wave-44, = main)  : 64 tokens · 164 candidates /113 slugs · arrivals 59  RC=1
```

The lens is mined FROM the corpus (`sw.sh` §2 "IDIOM = tokens the charter PREDICATES of a pds-
slug"). Adding charter prose adds vocabulary, and new vocabulary retro-fires on OLD lines.

## 3. VINTAGE SPLIT of the 59 — 13 are the lens moving, not the corpus claiming

```bash
python3 - <<'EOF'
import re,hashlib
cur=open('ch.md').read().split('\n')
old39=set(" ".join(l.split()) for l in open('ch_aa81a9b6e.md'))
old43=set(" ".join(l.split()) for l in open('ch_4082a3947.md'))
arr=[];sec=False
for l in open('run1.txt'):                     # run1.txt = stdout of step 1
    if 'unresolved-claim arrivals' in l: sec=True; continue
    if sec:
        m=re.match(r'\s+charter:(\d+) (\S+) \[',l)
        if m: arr.append((int(m.group(1)),m.group(2)))
        elif 'misclassified' in l: break
a=sum(1 for ln,_ in arr if " ".join(cur[ln-1].split()) in old39)
b=sum(1 for ln,_ in arr if " ".join(cur[ln-1].split()) in old43)-a
print(len(arr),a,b,len(arr)-a-b)
EOF
#   59  13  36  10
```

* **13 RETROACTIVE** — the line text was already in the charter when `adj.md` was authored and was
  NOT a candidate then. Their tokens are engineering idiom, not disposition: `export` (1208, 7871,
  7872, 6942), `five` (4010, 4154, 4331, 10774), `router` (3984, 6942), `itself` (8207), `guarded`
  (8237), `satisfied` (4467), `cut` (11548). Same FP class the sweep already carves out for
  `fails CLOSED` at §3. **These are lens defects, not judgment.**
* **36** added between w40 and w43 · **10** added by the w44 charter.

## 4. ZERO of the 59 are reflows — the brief's "(b) fingerprint merely moved" bucket is EMPTY

`fp = sha1(slug + "|" + " ".join(line.split()))[:12]` (`sw.sh:312`) — line-number-free. All 105
committed fps still locate in today's charter (**stale adjudication rows : 0**). Only 10 arrivals
share a slug with a committed row; max text similarity to their nearest prior row is **0.64**
(`difflib.SequenceMatcher`), and 6 of 10 are below 0.45. Every arrival is a NEW sentence.

**But the display-only `line` column is 92% wrong**: locate each committed fp in today's charter
and compare to its recorded `line` — **8 of 105 match, 97 are stale, median drift 1314 lines**.

```bash
python3 - <<'EOF'
import hashlib
lines=open('ch.md').read().split('\n'); adj={}
for raw in open('adj.md'):
    if not raw.lstrip().startswith('|'): continue
    c=[x.strip() for x in raw.strip().strip('|').split('|')]
    if len(c)<5 or c[0]=='fingerprint' or set(c[0])<={'-',':'}: continue
    adj[c[0]]=(c[1],c[2])
f={}
for i,l in enumerate(lines):
    n=" ".join(l.split())
    for fp,(ln,slug) in adj.items():
        if fp not in f and hashlib.sha1((slug+"|"+n).encode()).hexdigest()[:12]==fp: f[fp]=i+1
print(len(f), sum(1 for fp,i in f.items() if str(i)==adj[fp][0]))
EOF
#   105 8
```

## 5. THE FAIL-OPEN — reproduced TWICE, byte-identically

`resolve()` (`sw.sh:195-215`) calls `bp_json([...], allow_error=True)` and treats **every**
non-`ok` outcome as absence. `command -v bp` (:100) and the ledger read (fail-closed) both pass,
so the hole only opens on the per-slug second read.

```bash
mkdir -p cache shimdead shimauth shimlive
bash sw.sh --charter ch.md --table adj.md --ledger-cache "$PWD/cache" > base.txt 2>&1  # warm

printf '#!/bin/sh\necho "dial tcp: connection refused" >&2\nexit 1\n'                  > shimdead/bp
printf '#!/bin/sh\necho %s\nexit 3\n' \
  "'"'{"ok":false,"error":{"code":"unauthorized","message":"token expired"}}'"'"       > shimauth/bp
chmod +x shimdead/bp shimauth/bp

for s in shimdead shimauth; do
  rm -f cache/confirm.json
  PATH="$PWD/$s:$PATH" bash sw.sh --charter ch.md --table adj.md --ledger-cache "$PWD/cache" > $s.txt 2>&1
  diff <(grep -v '^charter' $s.txt) <(grep -v '^charter' base.txt) >/dev/null && echo "$s: BYTE-IDENTICAL"
done
#   shimdead: BYTE-IDENTICAL
#   shimauth: BYTE-IDENTICAL
#   both still print  tally: {... 'NOT-A-TASK': 14 ...}  and the sentence
#   "Each was CONFIRMED with a second read (`bp task get`) before being called NOT-A-TASK"
```

**The false-clear direction is NOT-A-TASK, never MISCLASSIFIED.** MISCLASSIFIED is what a shim
that returns a REAL doc produces — the live-doc control, which proves the branch is not dead code:

```bash
printf '#!/bin/sh\nprintf %s "$3"\nexit 0\n' \
  "'"'{"ok":true,"doc":{"_id":"%s","lifecycle_status":"open"}}\n'"'"  > shimlive/bp; chmod +x shimlive/bp
rm -f cache/confirm.json
PATH="$PWD/shimlive:$PATH" bash sw.sh --charter ch.md --table adj.md --ledger-cache "$PWD/cache" 2>&1 | grep tally:
#   tally: {'NOT-A-DISPOSITION-ASSERTION': 38, 'MISCLASSIFIED': 14, 'AGREES': 44, 'DISAGREES': 9}
```

## 6. NO POISON — the 11 committed `non-task` confirmations are CORRECT

```bash
for s in pds-scratch-target.sh pds-pull-proof.crown pds-pull-proof.sh pds-idle-sampler.sh \
         pds-w15-fire-record.md pds-crown-launch.sh pds-ledger-census.sh \
         pds-w35-lens-stops-accusing pds-receipt-census \
         pds-w36-groupc-webhook-differentials pds-w36-brief-help-seal-divergence; do
  bp task get "$s" -o json >/dev/null 2>&1; echo "$s rc=$?"
done
#   all 11: rc=4, stdout VALID JSON: {"error":{"code":"not_found",...},"ok":false}
```

The 14 NOT-A-TASK rows are 11 distinct slugs. Every one is genuinely absent. **The fail-open has
been printing the right answer for the wrong reason** — and `bp`'s `error.code == "not_found"` on
valid JSON is the discriminator the fix needs, available today at zero cost.

## 7. THE FIX — 12 lines, rc=2 on both shims, byte-identical under a live bp

Replace `resolve()`'s post-call block (`sw.sh:203-206`):

```python
    if not isinstance(d, dict):
        unchecked("bp task get %s produced no JSON — absence is UNPROVEN, not NOT-A-TASK" % slug)
    if d.get("ok") is True and isinstance(d.get("doc"), dict):
        st = d["doc"].get("lifecycle_status") or "unknown"
    elif d.get("ok") is False and (d.get("error") or {}).get("code") == "not_found":
        st = None
    else:
        unchecked("bp task get %s returned an unrecognized shape %r — absence is UNPROVEN"
                  % (slug, sorted(d)[:6]))
```

```
FIXED + real bp   -> rc=1, tally IDENTICAL to base.txt, arrivals 59
FIXED + shimdead  -> rc=2  "UNCHECKED: bp task get pds-scratch-target.sh produced no JSON — absence is UNPROVEN, not NOT-A-TASK"
FIXED + shimauth  -> rc=2  "UNCHECKED: bp task get pds-scratch-target.sh returned an unrecognized shape ['error', 'ok'] — absence is UNPROVEN"
```

## 8. THE SELFTEST HOSTAGE IS A DEFECT, and it is ONE `case` clause

`sw.sh:539-546` asserts the literal string `"unresolved-claim arrivals : 0"` in the MUTANT run.
The subject under test is "the plant added no same-line arrival"; the assertion instead demands
the CORPUS be green. Proof the coupling is the only cause:

```bash
bash sw.sh --selftest --charter ch_aa81a9b6e.md --table adj.md   # GREEN corpus  -> "SELFTEST OK: 3 of 3", rc=0
bash sw.sh --selftest --charter ch.md          --table adj.md   # RED corpus    -> rc=1
#   SELFTEST FAIL: the mutant run did not reach a clean arrival count (rc=1)
```

Legs 2 and 3 have **never been observed on today's corpus**. Replacing the absolute with a DELTA
(capture arrivals for `$CHARTER` and for `$MUT`; fail only if they differ) reaches all three legs
against the red corpus:

```
same-line lens: rc=1, arrivals 59 -> 59 (delta 0), sentinel NOT flagged — confirmed blind, as claimed
RESIDUE-SLUG pds-selftest-cross-line-sentinel lines=12696
PROVEN: the run NAMES the planted cross-line claim as residue.
unresolved-claim arrivals : 60        <- the same-line plant, delta +1
PROVEN: an unadjudicated same-line claim reds with rc=1 and is NAMED.
=== SELFTEST OK: 3 of 3 ===           rc=0
```

The delta form is also STRICTLY STRONGER than the original: it pins `+0` and `+1` rather than
`==0` and `!=0`. It decouples the guard from adjudication permanently — adjudicating the 59 makes
the original selftest pass too, but it will be re-taken hostage by the wave-45 charter.

## 9. THE PRICE THE CPU METER CANNOT SEE

Census `pds-door-census.sh:123` disposes this door CONTENT-RED at `CPU 3.42 s LOCAL`. Measured at
load1 44: `user 3,33 sys 0,51` (CPU 3.84 s) against `real 23,23`. The gap is not scheduler noise —
**4.9 s of it is hardcoded `time.sleep`**, read from source, invisible to `user`+`sys`:

* `sw.sh:178` `time.sleep(0.4)` after each non-final ledger page — 5 pages ⇒ **4 × 0.4 = 1.6 s**
* `sw.sh:213` `time.sleep(0.3)` per uncached second read — 11 slugs ⇒ **11 × 0.3 = 3.3 s**

Plus 16 network round trips. A CPU-only price column reports **~16%** of this door's floor.

## 10. THE SLICE'S OWN CRITERION 7 NAMES THE WRONG ORACLE

`bp task get pds-w44-charter-sweep-adjudication` c7 reads: *"with a bp shim that always exits
nonzero, the run now refuses instead of printing MISCLASSIFIED"*. §5 above shows a nonzero-exit
shim prints **NOT-A-TASK**, not MISCLASSIFIED — a builder chasing that oracle finds nothing and
may conclude the fail-open is not reproducible. c8 demands a statement "in the PR body"; builders
on this cycle neither push nor open PRs.
