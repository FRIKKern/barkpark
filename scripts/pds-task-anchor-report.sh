#!/usr/bin/env bash
#
# pds-task-anchor-report.sh — REPORT rotted `path:NNN` anchors in task bodies.
#                             It NEVER rewrites one.
#
# WHY (dr-w11-bl-task-body-file-line-anchors-rot-silently)
# -------------------------------------------------------
# A task body that cites `deploy_runner.ex:269` reads as measured precision. It
# is not falsifiable: the number carries no sha, so nothing can tell a builder
# the line moved. Measured over the OPEN children of `dr-backlog-never-started`
# at origin/main d288448d9: 62 `path:NNN` anchors, of which 39 were resolvable
# AND testable and 26 of those (67%) no longer land near the symbol the citing
# sentence names.
#
# WHY IT MUST NOT AUTO-FIX (the row's own ruling, and criterion 3)
# ---------------------------------------------------------------
# An anchor that moved has TWO causes with opposite remedies: the code moved
# (re-anchor) or the finding is gone (close the row). A rewriter picks one
# silently and destroys the evidence for the other. So this program prints a
# verdict per anchor and exits; it opens every source file READ-ONLY and holds
# no code path that writes to the tree or to the ledger. `--selftest` arm (d)
# asserts the fixture tree is byte-identical after a full red run.
#
# WHAT IT CANNOT SEE — stated here because the number above flatters it
# --------------------------------------------------------------------
# Two whole classes are invisible to any `path:NNN` checker, and both were
# measured on the same corpus:
#   * BARE `:NNN` REFERENTS. 11 of the 78 open rows carry 37 line references
#     written as `at :269` or `is at :748` — prose-bound to a filename named in
#     an earlier clause. This grammar parses to nothing here.
#   * CLAIM ROT. A body can assert something false ABOUT the code with every
#     line number correct: "`callees/2`'s `uniq_by` drops sibling clauses"
#     (refuted by run), "the charter carries no memory decision" (D39/D118/D143
#     /D119 exist), "`when event in @per_view_events` does not halt" (it halts).
#     Four of six specimens collected on 2026-09-16 were this class. No line
#     checker catches any of them. THE AUTHORING CONVENTION IS THE REMEDY;
#     this instrument is the cheap half.
#
# THE PLAUSIBILITY TEST — named, so it can be argued with
# ------------------------------------------------------
#   SYMBOL-IN-WINDOW(+/-5). For `path:NNN` in a body:
#     1. RESOLVE path against `git ls-files`: exact, else unique `*/path` suffix.
#        Zero matches -> UNRESOLVED-MISSING. Two or more -> UNRESOLVED-AMBIGUOUS
#        (`router.ex` matches both routers; a bare basename is not an address).
#     2. NNN out of range -> STALE.
#     3. Harvest CLAIM TOKENS from the sentence carrying the anchor: identifiers
#        >=4 chars, minus an English stoplist, MINUS every token derivable from
#        the path itself (a path token is not independent evidence). No token
#        left -> UNTESTABLE, never GOOD.
#     4. GOOD iff some claim token appears within lines NNN-5..NNN+5. Else STALE.
#   It is a REPORT, not a gate: UNTESTABLE and UNRESOLVED are their own buckets
#   precisely so a vacuous pass cannot hide inside GOOD.
#
# USAGE
#   bash scripts/pds-task-anchor-report.sh --parent <task-id> [--repo <dir>]
#   bash scripts/pds-task-anchor-report.sh --selftest
#
# EXIT: 0 report printed / selftest green · 1 selftest red · 2 cannot read the
#       ledger (never a silent "0 stale") · 3 usage.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT=""; REPO="$REPO_ROOT"; MODE="report"
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE="selftest"; shift ;;
    --parent) PARENT="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "pds-task-anchor-report: unknown argument: $1" >&2; exit 3 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "pds-task-anchor-report: python3 required" >&2; exit 2; }

ENGINE="$(mktemp -t pds-anchor-engine.XXXXXX)"
trap 'rm -f "$ENGINE"' EXIT
cat > "$ENGINE" <<'PYENGINE'
import json,os,re,sys,collections
RX=re.compile(r'(?<![\w/.-])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:ex|exs|heex|eex|js|mjs|cjs|ts|tsx|jsx|sh|bash|go|json|yml|yaml|md|sql|css|html))[:#](\d+)\b')
BARE=re.compile(r'(?<![\w/.-]):(\d{2,6})\b')
TOK=re.compile(r'[A-Za-z_][A-Za-z0-9_]{3,}[?!]?')
STOP=set("""this that with from have been will they them their what when where which while there here about into over
under task rows line lines file files code name names call calls site sites case cases only also just even more most
than then does done doing make made take taken read reads open opens close closes check checks test tests wave note
notes body epic main head anchor anchors number numbers still land lands plausible match convention symbol optional
hint carries writes wrote cited cite says said work works reported report never always every each both must should
would because before after same other another thing things point points true false null none some many much very well
field fields value values return returns error errors right left first last next prev prior above below within without
against between during since until unless today already nothing anything something someone nobody instead rather
column columns table tables entry entries list lists count counts total totals share small large whole part parts""".split())
OPEN={"open","in_progress","blocked"}

def sentence_of(text,pos):
    lo=max(text.rfind('.',0,pos),text.rfind('\n',0,pos),text.rfind(';',0,pos))+1
    hi=len(text)
    for ch in '.\n;':
        j=text.find(ch,pos)
        if j!=-1: hi=min(hi,j)
    return text[lo:hi]

def run(repo, files, rows):
    exact=set(files); out=[]
    for r in rows:
        if r.get("lifecycle_status") not in OPEN: continue
        text=r.get("description","")+"\n"+r.get("criteria","")
        for m in RX.finditer(text):
            p,n=m.group(1),int(m.group(2))
            rec={"doc_id":r["doc_id"],"anchor":"%s:%d"%(p,n)}
            cands=[p] if p in exact else [f for f in files if f.endswith("/"+p)]
            if not cands:
                rec.update(verdict="UNRESOLVED-MISSING",why="no file at HEAD ends with this path")
            elif len(cands)>1:
                rec.update(verdict="UNRESOLVED-AMBIGUOUS",why="%d files match (%s)"%(len(cands),", ".join(cands[:3])))
            else:
                f=cands[0]; rec["file"]=f
                with open(os.path.join(repo,f),encoding="utf-8",errors="replace") as fh:
                    lines=fh.read().split("\n")          # READ-ONLY: the only file open in this program
                if n<1 or n>len(lines):
                    rec.update(verdict="STALE",why="line %d out of range (file has %d lines)"%(n,len(lines)))
                else:
                    sent=sentence_of(text,m.start())
                    pathtoks={t.lower() for t in TOK.findall(p.replace('/',' ').replace('.',' '))}
                    toks={t.rstrip('?!') for t in TOK.findall(sent)}
                    toks={t for t in toks if len(t)>=4 and t.lower() not in STOP and t.lower() not in pathtoks}
                    toks|={x for x in re.findall(r'@([a-z_][a-z0-9_]{3,})',sent) if x.lower() not in pathtoks}
                    win="\n".join(lines[max(0,n-6):n+5])
                    hits=sorted(t for t in toks if re.search(r'(?<![A-Za-z0-9_])'+re.escape(t),win))
                    rec["cited"]=lines[n-1].strip()[:100]
                    if not toks: rec.update(verdict="UNTESTABLE",why="citing sentence carries no symbol beyond the path itself")
                    elif hits:   rec.update(verdict="GOOD",why="[%s] present within +/-5 of %d"%(",".join(hits[:3]),n))
                    else:        rec.update(verdict="STALE",why="none of [%s] within +/-5 of %d"%(",".join(sorted(toks)[:5]),n))
            out.append(rec)
    return out

def bare_refs(rows):
    n_rows=n_occ=0
    for r in rows:
        if r.get("lifecycle_status") not in OPEN: continue
        t=RX.sub(" @@ ",r.get("description","")+"\n"+r.get("criteria",""))
        b=BARE.findall(t)
        if b: n_rows+=1; n_occ+=len(b)
    return n_rows,n_occ

def report(repo,files,rows,label):
    out=run(repo,files,rows); c=collections.Counter(x["verdict"] for x in out)
    br,bo=bare_refs(rows)
    print("=== pds-task-anchor-report — SYMBOL-IN-WINDOW(+/-5) — %s ==="%label)
    for rec in out:
        print("[%-21s] %-52s %s"%(rec["verdict"],rec["anchor"],rec["doc_id"]))
        print("      %s"%rec["why"])
        if "cited" in rec: print("      line -> %r"%rec["cited"])
    print("")
    for k in ("GOOD","STALE","UNTESTABLE","UNRESOLVED-AMBIGUOUS","UNRESOLVED-MISSING"):
        print("  %-21s %d"%(k,c[k]))
    print("  %-21s %d"%("anchors checked",len(out)))
    print("  BLIND SPOT: %d open rows carry %d BARE ':NNN' refs this grammar cannot parse."%(br,bo))
    print("  NOTHING WAS REWRITTEN. An anchor that moved may mean the code moved or the finding is gone.")
    return out,c
PYENGINE

if [ "$MODE" = "selftest" ]; then
  FIX="$(mktemp -d -t pds-anchor-fix.XXXXXX)"
  mkdir -p "$FIX/a" "$FIX/b"
  printf 'one\ntwo\nthree\ndef box_at_capacity?(box, n) do\nfive\nsix\n' > "$FIX/a/runner.ex"
  printf 'x\ny\nz\n' > "$FIX/b/runner.ex"
  { echo alpha; for i in $(seq 2 39); do echo "filler $i"; done; echo '@build_slot_capacity 1'; for i in $(seq 41 60); do echo "tail $i"; done; } > "$FIX/solo.ex"
  BEFORE="$(cd "$FIX" && find . -type f -exec shasum {} \; | sort)"
  python3 - "$FIX" "${BASH_SOURCE[0]}" "$ENGINE" <<'PYSELF'
import sys,os,subprocess,importlib.util
fix,script,engine=sys.argv[1],sys.argv[2],sys.argv[3]
spec=importlib.util.spec_from_loader("eng",loader=None); eng=importlib.util.module_from_spec(spec)
exec(open(engine).read(),eng.__dict__)
files=["a/runner.ex","b/runner.ex","solo.ex"]
rows=[
 # (a) RED arm — the symbol MOVED away from the cited line
 {"doc_id":"fx-moved","lifecycle_status":"open",
  "description":"The `@build_slot_capacity` constant is at solo.ex:1 and bounds the box.","criteria":""},
 # (b) QUIET arm — the symbol is AT the cited line
 {"doc_id":"fx-good","lifecycle_status":"open",
  "description":"The `@build_slot_capacity` constant is at solo.ex:40 and bounds the box.","criteria":""},
 # (c) AMBIGUOUS arm — a bare basename is not an address
 {"doc_id":"fx-ambig","lifecycle_status":"open",
  "description":"See `box_at_capacity?` at runner.ex:4.","criteria":""},
 # (e) OUT-OF-RANGE arm
 {"doc_id":"fx-range","lifecycle_status":"open",
  "description":"The `@build_slot_capacity` constant is at solo.ex:999.","criteria":""},
 # (f) CLOSED rows are out of scope
 {"doc_id":"fx-closed","lifecycle_status":"done",
  "description":"The `@build_slot_capacity` constant is at solo.ex:1.","criteria":""},
 # (g) BARE-ref blind spot must be COUNTED, not silently dropped
 {"doc_id":"fx-bare","lifecycle_status":"open",
  "description":"box_at_capacity?/2 was cited at :721; it is at :748.","criteria":""},
]
out,c=eng.report(fix,files,rows,"SELFTEST FIXTURE")
by={r["doc_id"]:r for r in out}
fails=[]
def chk(name,cond,detail=""):
    if not cond: fails.append("%s %s"%(name,detail))
    print("  arm %-34s %s"%(name,"PASS" if cond else "FAIL "+detail))
print("")
chk("(a) moved anchor REDS as STALE", by.get("fx-moved",{}).get("verdict")=="STALE", str(by.get("fx-moved")))
chk("(a2) ... and NAMES the row", "fx-moved" in by)
chk("(b) unmoved anchor stays GOOD", by.get("fx-good",{}).get("verdict")=="GOOD", str(by.get("fx-good")))
chk("(c) bare basename -> AMBIGUOUS", by.get("fx-ambig",{}).get("verdict")=="UNRESOLVED-AMBIGUOUS", str(by.get("fx-ambig")))
chk("(e) out-of-range -> STALE", by.get("fx-range",{}).get("verdict")=="STALE", str(by.get("fx-range")))
chk("(f) closed row not reported", "fx-closed" not in by)
chk("(g) bare ':NNN' counted as blind spot", eng.bare_refs(rows)[1]>=2, str(eng.bare_refs(rows)))
chk("(h) engine holds no write mode", "'w'" not in open(engine).read() and "'a'" not in open(engine).read())
chk("(i) live path issues no bp write verb",
    not any(("bp "+v) in open(script).read() for v in ["task cl"+"ose","doc pa"+"tch","task st"+"amp","doc cr"+"eate"]))
open(os.path.join(fix,"__verdicts.json"),"w").write("ok")  # outside the fixture set, proves the harness CAN write
sys.exit(1 if fails else 0)
PYSELF
  RC=$?
  AFTER="$(cd "$FIX" && find . -path ./__verdicts.json -prune -o -type f -exec shasum {} \; | sort)"
  if [ "$BEFORE" != "$AFTER" ]; then
    echo "  arm (d) fixture tree byte-identical after run   FAIL — THE PROGRAM EDITED A SOURCE FILE"
    RC=1
  else
    echo "  arm (d) fixture tree byte-identical after run   PASS"
  fi
  rm -rf "$FIX"
  if [ "$RC" -eq 0 ]; then echo "SELFTEST PASS: 10 arms, 0 failed."; else echo "SELFTEST FAIL"; fi
  exit "$RC"
fi

[ -n "$PARENT" ] || { echo "pds-task-anchor-report: --parent <task-id> is required (or --selftest)" >&2; exit 3; }
command -v bp >/dev/null 2>&1 || { echo "pds-task-anchor-report: bp not on PATH — CANNOT READ the ledger (exit 2, never a silent zero)" >&2; exit 2; }

LEDGER="$(mktemp -t pds-anchor-ledger.XXXXXX)"
if ! env -u BARKPARK_TOKEN bp task ls --parent "$PARENT" --all -o json >"$LEDGER" 2>/dev/null; then
  rm -f "$LEDGER"; echo "pds-task-anchor-report: ledger walk failed — CANNOT READ (exit 2)" >&2; exit 2
fi
if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["docs"]; sys.exit(0 if d else 1)' "$LEDGER"; then
  rm -f "$LEDGER"; echo "pds-task-anchor-report: ledger walk returned ZERO rows — CANNOT READ (exit 2)" >&2; exit 2
fi
FILES="$(mktemp -t pds-anchor-files.XXXXXX)"
git -C "$REPO" ls-files >"$FILES"
python3 - "$REPO" "$FILES" "$LEDGER" "$PARENT" "$ENGINE" <<'PYLIVE'
import sys,json,importlib.util
repo,filelist,ledger,parent,engine=sys.argv[1:6]
spec=importlib.util.spec_from_loader("eng",loader=None); eng=importlib.util.module_from_spec(spec)
exec(open(engine).read(),eng.__dict__)
files=[l.rstrip("\n") for l in open(filelist)]
rows=[{"doc_id":d["doc_id"],"lifecycle_status":d.get("lifecycle_status"),
       "description":(d.get("content") or {}).get("description") or "",
       "criteria":"\n".join((c.get("criterion") or c.get("text") or "") for c in ((d.get("content") or {}).get("acceptance_criteria") or []))}
      for d in json.load(open(ledger))["docs"]]
eng.report(repo,files,rows,"children of %s"%parent)
PYLIVE
rm -f "$LEDGER" "$FILES"
exit 0
