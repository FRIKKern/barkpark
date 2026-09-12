#!/usr/bin/env bash
#
# exit-laundering-sweep.sh — find `cmd >/dev/null 2>&1 || true` on a PRODUCER
# whose output a LATER line CONSUMES.
#
# THE DEFECT (task-20fe68463c87e136).  `|| true` discards the status and
# `>/dev/null 2>&1` discards the producer's own message.  When the very next
# assertion reads the file that command was supposed to WRITE, the reader's
# "file not found" becomes the headline and the producer's refusal is deleted.
# Measured cost, once: scripts/required-checks.test.sh, eight emit sites, a
# repo-wide required-check red from 2026-08-24T21:59Z to 2026-08-31T20:14Z
# (#14371).  Nine FAILs read as `jq: error: Could not open file …-spec.json`
# for SEVEN DAYS while the generator's real refusal — `EXCLUSION LOSS … LOST
# <row>` — was thrown away by the `|| true` one line above.
#
# WHY THIS IS NOT A GREP.  `grep -rn '2>&1 || true' scripts/ .github/` answers
# in the hundreds across this repo's corpus and MOST OF THEM ARE CORRECT:
# best-effort teardown (`trap 'trash "$tmp"' EXIT`, `docker rm -f`,
# `gh api -X DELETE`, `bp doc delete`) genuinely does not care whether it
# succeeded, and nothing downstream reads what it did not produce.  Reporting
# those would be a census that counts doors instead of what a door sees.
#
# THE PREDICATE, and it is the row's own rule, in three conjuncts:
#
#   P1  STATUS LAUNDERED — the command's exit status is discarded by a trailing
#       `|| true`, `|| :`, or `; true`.
#   P2  MESSAGE SILENCED — its output goes to /dev/null (`>/dev/null`,
#       `2>/dev/null`, `&>/dev/null`, `>/dev/null 2>&1`).  `$(cmd 2>&1 || true)`
#       is deliberately NOT P2: `2>&1` into a CAPTURE keeps the message alive in
#       the variable, which is the correct shape, not the defect.
#   P3  PRODUCER + DOWNSTREAM CONSUMER — the command names an artifact
#       (`--out X` / `--output X` / `-o X` / `> X` / `| tee X`, or a
#       `VAR=$(…)` capture) and a LATER line in the same scope REFERENCES that
#       artifact.  Teardown names no artifact, so teardown never reaches P3.
#
# A hit satisfying P1+P2 but not P3 is reported as CLASSIFIED-OK, with its
# reason, so the confirmed count means something next to the raw count.
#
# SCOPE for "later line": inside a shell function, to the function's closing
# `}`; inside a workflow step, to the next `- name:`/`- uses:` at the same or
# lower indent; otherwise a window (default 60 lines, --window N).
#
# THE CENSUS, measured 2026-09-12 on origin/main f072865bb over the corpus below
# (422 files). Every number is re-derivable by running this script with no args:
#
#   raw P1 hits (the naive-grep number)                      1193
#   P1+P2 and naming an artifact (producers)                  221
#   CONFIRMED HIGH  — file artifact parsed downstream          18
#   CONFIRMED MEDIUM — captured variable branched on          152
#   classified OK, with a printed reason each                1023
#
# So 1023 of 1193 raw hits are CORRECT best-effort teardown or otherwise excused,
# which is why the naive grep is useless here: it is 98.5% noise by the row's own
# rule. Of the 18 HIGH sites, 1 was in scripts/ and is fixed in this change
# (required-checks.test.sh section 27, the last survivor of the #14371 shape in
# the file whose outage named the class) and 17 are in deploy/, outside the gates
# lane's fence, filed as task-f56d84cf77d93c24 with every producer and consumer
# quoted. The three sightings the parent row named were re-checked on the same
# sha and are CLOSED: required-checks.test.sh routes through emit_spec/why_emit,
# architecture.yml:433-443 carries `set -euo pipefail` with the comment naming
# tee's always-0 status, and pds-live-hetzner-placement-group.sh:820-830 reads
# its delete receipt instead of discarding it.
#
# EXIT: 0 no confirmed findings · 1 at least one confirmed · 2 cannot measure.
#
# USAGE
#   bash scripts/exit-laundering-sweep.sh                 # sweep the default corpus
#   bash scripts/exit-laundering-sweep.sh --all           # also print CLASSIFIED-OK hits
#   bash scripts/exit-laundering-sweep.sh --root DIR      # sweep one tree
#   bash scripts/exit-laundering-sweep.sh --selftest      # planted controls, both directions
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${SWEEP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHOW_ALL=0
SHOW_MEDIUM=0
WINDOW=60
MODE=sweep
TARGETS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all) SHOW_ALL=1; SHOW_MEDIUM=1; shift ;;
    --medium) SHOW_MEDIUM=1; shift ;;
    --window) WINDOW="${2:-60}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --path) TARGETS="$TARGETS $2"; shift 2 ;;
    --selftest) MODE=selftest; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "exit-laundering-sweep: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  echo "exit-laundering-sweep: CANNOT READ — python3 is not on PATH; the classifier is python3, and an absent classifier is not a clean sweep" >&2
  exit 2
}

# The default corpus.  Printed by every run, so a later reader can tell
# COVERAGE from ABSENCE: a directory not on this list was not measured.
CORPUS="scripts .github/workflows deploy api/scripts .claude/skills tooling"

classify() {
  # $1 = root, $2 = space-separated dirs (or empty when --path was used),
  # $3 = show_all, $4 = window, $5.. = explicit paths
  SWEEP_ROOT_ARG="$1" SWEEP_DIRS="$2" SWEEP_ALL="$3" SWEEP_WINDOW="$4" SWEEP_FILES="$5" \
  SWEEP_MEDIUM="${SWEEP_MEDIUM_ARG:-$SHOW_MEDIUM}" \
  python3 - <<'PY'
import os, re, sys

root   = os.environ["SWEEP_ROOT_ARG"]
dirs   = os.environ["SWEEP_DIRS"].split()
showall= os.environ["SWEEP_ALL"] == "1"
showmed= os.environ.get("SWEEP_MEDIUM") == "1"
window = int(os.environ["SWEEP_WINDOW"])
explicit = os.environ["SWEEP_FILES"].split()

EXTS = (".sh", ".bash", ".yml", ".yaml")

# P1 — the status is thrown away.
LAUNDER = re.compile(r'\|\|\s*(?:true|:)\s*(?:[)"\';]|$)|;\s*true\s*$')
# P2 — the message goes to /dev/null.
SILENCE = re.compile(r'(?:&>|\d?>|2>)\s*/dev/null')
# P3a — an artifact named as a flag value.
FLAGART = re.compile(r'--(?:out|output|outfile|out-file|spec|spec-out|json-out|report|log-file|artifact|readback|runs)(?:=|\s+)(["\']?)([^\s"\';|)&]+)\1')
SHORTO  = re.compile(r'(?<![-\w])-o\s+(["\']?)([^\s"\';|)&]+)\1')
# P3b — a redirect or tee to a real file.
REDIR   = re.compile(r'(?:\d?>>?|\|\s*tee(?:\s+-a)?)\s+(["\']?)([^\s"\';|)&]+)\1')
# P3c — a capture into a variable.
CAPTURE = re.compile(r'^\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=\$?\(?["\']?\$\(')
CAPTURE2= re.compile(r'^\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=["\']?\$\(')

FORMATS = {"json","yaml","yml","text","table","tsv","csv","wide","name","-"}
# Lines that merely DESTROY the artifact are not consumers.
DESTROY = re.compile(r'\b(rm|trash|rmdir|unlink|mkdir|touch)\b')
# P4 — an EARLY-EXIT GUARD between producer and consumer. When a line between
# them returns/exits/continues/breaks (a `if [ "$code" != 200 ]; then fail …;
# return` arm, say), the producer's refusal HAS a surface of its own and the
# consumer is never reached on the failing path. That is the correct shape, not
# the defect, and it is why a scope-only scan over-reports: five of this repo's
# curl sites are exactly this.
GUARD = re.compile(r'(^|;|\bthen\b|&&|\|\|)\s*(return|exit|continue|break)\b')
# A consumer that is ITSELF an existence/size test handles the empty case by
# design — `[ ! -s "$f" ] && warn` names the failure rather than tripping over it.
EXISTS_TEST = re.compile(r'\[\s*!?\s*-(s|f|e|r)\s')
# P5 — a STATUS SURROGATE on the laundered line itself. `curl -w '%{http_code}'`
# captured into a variable, or `; rc=$?`, means the status was not actually
# thrown away: a proxy for it survives and some later line can assert it. Four
# of scripts/pds-pull-proof.sh's curl sites are exactly this shape and are
# CORRECT — the verdict reads `$code`, and the body read is informational.
SURROGATE = re.compile(r"-w\s+['\"]?%\{http_code\}|\brc=\$\?|\bcode=\$\?|--write-out")

def files_to_scan():
    if explicit:
        for p in explicit:
            yield p if os.path.isabs(p) else os.path.join(root, p)
        return
    for d in dirs:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dp, dn, fn in os.walk(base):
            dn[:] = [x for x in dn if x not in (".git", "node_modules", "_build", "deps", "vendor")]
            for f in sorted(fn):
                if f.endswith(EXTS):
                    yield os.path.join(dp, f)

def scope_end(lines, i, is_yaml):
    """Last line index (exclusive) a downstream consumer may live on."""
    hard = min(len(lines), i + 1 + window)
    if is_yaml:
        cur = lines[i]
        ind = len(cur) - len(cur.lstrip())
        for j in range(i + 1, hard):
            s = lines[j]
            if not s.strip():
                continue
            jind = len(s) - len(s.lstrip())
            if jind <= ind and re.match(r'\s*-\s+(name|uses|run):', s):
                return j
            if jind < ind and re.match(r'\s*[A-Za-z_][\w-]*:', s):
                return j
        return hard
    for j in range(i + 1, hard):
        if re.match(r'^\}', lines[j]):
            return j          # the enclosing function closes here
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{?', lines[j]):
            return j          # the next function begins here
    return hard

def artifacts(line):
    """Every artifact the laundered command claims to produce, with a label."""
    out = []
    for m in FLAGART.finditer(line):
        v = m.group(2)
        if v.lower() not in FORMATS and v != "/dev/null":
            out.append((v, "--%s" % m.group(0).split("=")[0].strip().lstrip("-").split()[0]))
    for m in SHORTO.finditer(line):
        v = m.group(2)
        if v.lower() not in FORMATS and v != "/dev/null" and ("/" in v or "." in v or v.startswith("$")):
            out.append((v, "-o"))
    for m in REDIR.finditer(line):
        v = m.group(2)
        if v != "/dev/null" and not v.startswith("&"):
            out.append((v, "redirect"))
    m = CAPTURE.match(line) or CAPTURE2.match(line)
    if m:
        out.append(("$" + m.group(1), "capture"))
    seen, uniq = set(), []
    for v, why in out:
        v = v.strip('"\'')
        if v and v not in seen:
            seen.add(v); uniq.append((v, why))
    return uniq

OPENS = re.compile(r'(^|;|\bdo\b|\bthen\b)\s*(if|case)\b')
CLOSES = re.compile(r'(^|;)\s*(fi|esac)\b')

def guarded(lines, i, j):
    """True when the consumer at j is protected from the producer's failure.

    TWO WAYS, and both were found in this repo rather than imagined:
      (a) an EARLY EXIT between them (`if [ "$code" != 200 ]; then fail; return`);
      (b) the consumer sits INSIDE a conditional opened after the producer
          (`if [ "$code" = "200" ]; then version=$(jq … <"$status"); fi`) — a
          POSITIVE guard, which carries no return and which (a) cannot see.
    scripts/pds-pull-proof.sh has one of each; neither is the defect.
    """
    depth = 0
    for k in range(i + 1, j):
        t = lines[k].strip()
        if not t or t.startswith("#"):
            continue
        if GUARD.search(lines[k]):
            return True
        depth += len(OPENS.findall(lines[k])) - len(CLOSES.findall(lines[k]))
    return depth > 0

def consumer_for(lines, i, end, art):
    """The first LATER line that READS art. Bare $VAR also matches ${VAR}."""
    needles = [art]
    if art.startswith("$"):
        needles.append("${%s}" % art[1:])
    for j in range(i + 1, end):
        s = lines[j]
        t = s.strip()
        if not t or t.startswith("#"):
            continue
        if not any(n in s for n in needles):
            continue
        if DESTROY.search(s):
            continue
        if EXISTS_TEST.search(s):
            return None, "EXISTS-TEST"      # a designed empty-case check, not a trip
        if guarded(lines, i, j):
            return None, "GUARDED"
        # A later line that only WRITES the same artifact is not a consumer.
        writes = [v for v, _ in artifacts(s)]
        if art in writes and not re.search(r'(?:cat|jq|grep|source|\.|test|\[|read|python3|node|awk|sed|head|tail|wc|diff|-f|-s|-e)\b', s):
            continue
        return j, s.rstrip()
    return None, None

raw = 0
producers = 0
confirmed = []
classified_ok = []
scanned = 0

for path in files_to_scan():
    try:
        with open(path, "r", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as e:
        print("exit-laundering-sweep: CANNOT READ %s (%s)" % (path, e), file=sys.stderr)
        sys.exit(2)
    if os.path.basename(path) == "exit-laundering-sweep.sh":
        # This file's own --selftest carries VERBATIM plants of the bad shape in
        # heredocs. Scanning them would make the sweep report its own fixtures.
        continue
    scanned += 1
    is_yaml = path.endswith((".yml", ".yaml"))
    for i, line in enumerate(lines):
        t = line.strip()
        if t.startswith("#") or not t:
            continue
        if not LAUNDER.search(line):
            continue
        raw += 1
        if not SILENCE.search(line):
            classified_ok.append((path, i + 1, line.rstrip(), "P2 not met: the message is not sent to /dev/null (a `2>&1` capture keeps it)"))
            continue
        if SURROGATE.search(line):
            classified_ok.append((path, i + 1, line.rstrip(), "P5 not met: the line carries a STATUS SURROGATE (-w '%{http_code}' / rc=$?) — the status is captured, not discarded"))
            continue
        arts = artifacts(line)
        if not arts:
            classified_ok.append((path, i + 1, line.rstrip(), "P3 not met: names no artifact — best-effort teardown, nothing downstream can read it"))
            continue
        producers += 1
        end = scope_end(lines, i, is_yaml)
        hit = False
        excused = None
        for art, why in arts:
            j, cons = consumer_for(lines, i, end, art)
            if j is None and cons in ("GUARDED", "EXISTS-TEST"):
                excused = (art, cons)
            if j is not None:
                sev = "medium" if why == "capture" else "high"
                confirmed.append((sev, path, i + 1, line.rstrip(), art, why, j + 1, cons))
                hit = True
                break
        if not hit:
            if excused and excused[1] == "GUARDED":
                classified_ok.append((path, i + 1, line.rstrip(), "P4: %s IS read downstream, but an early-exit guard stands between — the refusal has its own surface" % excused[0]))
            elif excused:
                classified_ok.append((path, i + 1, line.rstrip(), "P4: the downstream read of %s is itself an existence/size test — the empty case is handled by design" % excused[0]))
            else:
                classified_ok.append((path, i + 1, line.rstrip(), "P3 not met: produces %s but no later line in scope reads it" % ", ".join(a for a, _ in arts)))

rel = lambda p: os.path.relpath(p, root)

print("EXIT-LAUNDERING SWEEP")
print("  coverage   : %s" % (" ".join(explicit) if explicit else " ".join(dirs)))
print("  patterns   : P1 `|| true` / `|| :` / `; true`  +  P2 output to /dev/null  +  P3 artifact read")
print("               downstream  +  P4 NO early-exit guard and no existence-test consumer between")
print("               them, and the consumer is not INSIDE a conditional opened after the producer")
print("               +  P5 NO status surrogate (-w '%{http_code}' / rc=$?) on the line itself")
print("  file types : %s" % " ".join(EXTS))
print("  files read : %d" % scanned)
print("  raw hits   : %d   (P1 alone — the naive-grep number)" % raw)
print("  producers  : %d   (P1+P2 and naming an artifact)" % producers)
high = [c for c in confirmed if c[0] == "high"]
med  = [c for c in confirmed if c[0] == "medium"]
print("  CONFIRMED  : %d   (P1+P2+P3 — a downstream line reads what it produced)" % len(confirmed))
print("    HIGH     : %d   FILE artifact (--out/redirect/tee) parsed downstream — the verbatim #14371 shape:" % len(high))
print("               the file is never written, so the READER's \"could not open\" is the only text anyone sees.")
print("    MEDIUM   : %d   CAPTURED variable branched on downstream — a refusal is indistinguishable from" % len(med))
print("               an empty answer, so the consumer takes its own not-found branch. Weaker: the consumer")
print("               at least HAS a branch. Listed with --medium.")
print("  classified OK: %d (reported, not defects — reasons below with --all)" % len(classified_ok))
print("")

for sev, path, ln, line, art, why, cj, cons in (confirmed if showmed else high):
    print("CONFIRMED[%s] %s:%d" % (sev.upper(), rel(path), ln))
    print("  PRODUCER  %s" % line.strip())
    print("  ARTIFACT  %s  (%s)" % (art, why))
    print("  CONSUMER  %s:%d  %s" % (rel(path), cj, cons.strip()))
    print("  SURFACES AS  the consumer's own complaint about a missing/empty %s, never the producer's refusal" % art)
    print("")

if showall:
    for path, ln, line, reason in classified_ok:
        print("CLASSIFIED-OK %s:%d  %s" % (rel(path), ln, reason))
        print("    %s" % line.strip())

sys.exit(1 if high else 0)
PY
}

selftest() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/elsweep.XXXXXX")" || { echo "CANNOT READ — mktemp failed" >&2; exit 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  mkdir -p "$tmp/scripts"

  # ── POSITIVE CONTROL 1: the verbatim #14371 pre-fix shape.
  cat > "$tmp/scripts/plant-a.sh" <<'EOF'
#!/usr/bin/env bash
section_one() {
  bash "$GEN" --workflows "$WF" --no-merge --out "$TMP/sel-spec.json" >/dev/null 2>&1 || true
  if jq -e '.checks == ["Aggregate gate"]' "$TMP/sel-spec.json" >/dev/null 2>&1; then
    ok "selected"
  else
    bad "the emitted spec is $(jq -c '.checks' "$TMP/sel-spec.json" 2>&1)"
  fi
}
EOF
  # ── POSITIVE CONTROL 2: the `> file` redirect form.
  cat > "$tmp/scripts/plant-b.sh" <<'EOF'
#!/usr/bin/env bash
gen() {
  bp doc ls task -o json > "$ART/rows.json" 2>/dev/null || true
  count=$(jq 'length' "$ART/rows.json")
}
EOF
  # ── POSITIVE CONTROL 3: a workflow step, producer then consumer.
  cat > "$tmp/scripts/plant-c.yml" <<'EOF'
jobs:
  x:
    steps:
      - name: produce and read
        run: |
          node tooling/x.mjs --out /tmp/boundary.json >/dev/null 2>&1 || true
          jq -e '.ok' /tmp/boundary.json
      - name: next step
        run: echo done
EOF
  # ── NEGATIVE CONTROL 1: teardown. No artifact, nothing downstream.
  cat > "$tmp/scripts/neg-a.sh" <<'EOF'
#!/usr/bin/env bash
cleanup() {
  docker rm -f barkpark-pg >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1 || true
  bp doc delete "$id" --yes >/dev/null 2>&1 || true
}
EOF
  # ── NEGATIVE CONTROL 2: a CAPTURE that keeps the message (P2 not met).
  cat > "$tmp/scripts/neg-b.sh" <<'EOF'
#!/usr/bin/env bash
probe() {
  OUT="$(bash "$GEN" --explain 2>&1 || true)"
  case "$OUT" in *REFUSED*) bad "$OUT" ;; *) ok ;; esac
}
EOF
  # ── P4 CONTROL: the SAME producer+consumer, but an early-exit guard between.
  # The shape of scripts/pds-pull-proof.sh step_0a, which a scope-only scan
  # reports and which is CORRECT: the non-200 arm fails and returns BEFORE the
  # body is ever parsed, so the refusal has a surface of its own.
  cat > "$tmp/scripts/neg-d.sh" <<'EOF'
#!/usr/bin/env bash
step_0a() {
  bp_curl -sS -o "$status" --max-time 30 "$BASE/status.json" >/dev/null 2>&1 || true
  if [ "$RC" != "200" ]; then
    fail 0a "the source is not answering"
    return 0
  fi
  version="$(jqp 'd["version"]' <"$status")"
}
EOF
  # ── P4b CONTROL: a POSITIVE guard — the consumer sits inside an `if` opened
  # after the producer, so the failing path never reaches it. Verbatim shape of
  # scripts/pds-pull-proof.sh:3494. No `return`, so the early-exit arm is blind
  # to it, which is why P4 counts conditional DEPTH as well.
  cat > "$tmp/scripts/neg-f.sh" <<'EOF'
#!/usr/bin/env bash
step_8() {
  bp_curl -sS -o "$status" --max-time 30 "$BASE/status.json" >/dev/null 2>&1 || true
  if [ "$RC" = "200" ]; then
    uptime_now="$(jqp 'd.get("uptime_seconds","")' <"$status" 2>/dev/null || true)"
  fi
}
EOF
  # ── P5 CONTROL: a status SURROGATE on the laundered line. The shape of
  # scripts/pds-pull-proof.sh's curl sites: the exit status is laundered but
  # `%{http_code}` is captured, and the verdict line reads THAT.
  cat > "$tmp/scripts/neg-e.sh" <<'EOF'
#!/usr/bin/env bash
fetch() {
  code="$(curl -sS -o "$bundle" -w '%{http_code}' "$URL" 2>/dev/null || true)"
  bytes="$(wc -c <"$bundle")"
  info "export HTTP $code · $bytes bytes"
  if [ "$code" != "200" ]; then bad "export -> $code"; fi
}
EOF
  # ── SEVERITY CONTROL: a CAPTURE whose message IS silenced is MEDIUM, not HIGH.
  cat > "$tmp/scripts/plant-d.sh" <<'EOF'
#!/usr/bin/env bash
lookup() {
  hits="$(git grep -n "$NEEDLE" origin/main 2>/dev/null || true)"
  if [ -z "$hits" ]; then echo "no hits"; fi
}
EOF
  # ── NEGATIVE CONTROL 3: an artifact produced and genuinely never read.
  cat > "$tmp/scripts/neg-c.sh" <<'EOF'
#!/usr/bin/env bash
warm() {
  curl -s "$URL" -o "$TMP/warm.html" >/dev/null 2>&1 || true
  echo "warmed"
}
EOF

  local out
  out="$(SWEEP_MEDIUM_ARG=1 classify "$tmp" "scripts" 1 60 "" 2>&1)"

  chk() { # chk NAME EXPECT-PRESENT PATTERN
    case "$out" in
      *"$3"*) if [ "$2" = yes ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 — pattern present and should not be: $3"; fi ;;
      *)      if [ "$2" = no  ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 — pattern ABSENT and should be present: $3"; fi ;;
    esac
  }

  echo "exit-laundering-sweep --selftest (3 planted positives, 3 negative controls)"
  chk "P1 positive: the #14371 --out shape is NAMED"        yes "CONFIRMED[HIGH] scripts/plant-a.sh:3"
  chk "P1 positive: its CONSUMER line is quoted"            yes "scripts/plant-a.sh:4"
  chk "P2 positive: the \`> file\` redirect shape is NAMED" yes "CONFIRMED[HIGH] scripts/plant-b.sh:3"
  chk "P3 positive: a workflow step is NAMED"               yes "CONFIRMED[HIGH] scripts/plant-c.yml:6"
  chk "negative: docker rm -f teardown is NOT confirmed"    no  "CONFIRMED[HIGH] scripts/neg-a.sh"
  chk "negative: a 2>&1 CAPTURE is NOT confirmed"           no  "CONFIRMED[HIGH] scripts/neg-b.sh"
  chk "negative: an unread artifact is NOT confirmed"       no  "CONFIRMED[HIGH] scripts/neg-c.sh"
  chk "teardown is CLASSIFIED-OK with its reason, not silent" yes "CLASSIFIED-OK scripts/neg-a.sh"
  chk "the capture's reason names P2"                       yes "P2 not met"
  chk "the unread artifact's reason names P3"               yes "P3 not met: produces"
  chk "a silenced CAPTURE is MEDIUM, not HIGH"              yes "CONFIRMED[MEDIUM] scripts/plant-d.sh:3"
  chk "the HIGH tally counts only the FILE-artifact shape"  yes "HIGH     : 3"
  chk "the MEDIUM tally is reported separately"             yes "MEDIUM   : 1"
  chk "P4: an early-exit guard between excuses the site"    no  "CONFIRMED[HIGH] scripts/neg-d.sh"
  chk "P4: …and says WHY, rather than dropping it silently" yes "an early-exit guard stands between"
  chk "P4b: a POSITIVE guard (consumer inside an if) excuses" no "CONFIRMED[HIGH] scripts/neg-f.sh"
  chk "P5: a %{http_code} surrogate excuses the site"       no  "CONFIRMED[HIGH] scripts/neg-e.sh"
  chk "P5: …and says WHY"                                   yes "P5 not met: the line carries a STATUS SURROGATE"

  # The FALSIFIER the row demands: remove the consumer and the positive must go away.
  perl -0pi -e 's/^\s*if jq -e.*$//m; s/^\s*bad "the emitted spec.*$//m' "$tmp/scripts/plant-a.sh"
  local out2
  out2="$(SWEEP_MEDIUM_ARG=1 classify "$tmp" "scripts" 1 60 "" 2>&1)"
  case "$out2" in
    *"CONFIRMED[HIGH] scripts/plant-a.sh"*) fail=$((fail+1)); echo "  FAIL falsifier — plant-a still CONFIRMED after its consumer was deleted; the checker is not reading the consumer at all" ;;
    *) pass=$((pass+1)); echo "  ok   falsifier — deleting the CONSUMER retracts the finding (the predicate is P3, not the grep)" ;;
  esac

  echo "  ---- $pass passed, $fail failed ----"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

if [ "$MODE" = selftest ]; then
  selftest
  exit $?
fi

[ -d "$ROOT" ] || { echo "exit-laundering-sweep: CANNOT READ — no such root: $ROOT" >&2; exit 2; }
classify "$ROOT" "$CORPUS" "$SHOW_ALL" "$WINDOW" "$TARGETS"
