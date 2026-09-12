#!/usr/bin/env bash
#
# PDS CHARTER↔LEDGER SWEEP — read the charter's disposition claims as PROSE,
# resolve every one of them against the LIVE ledger, and PRINT the coverage the
# lens does not have.
#
# WHY THIS EXISTS. Wave 38 item 2 had two halves. One half asked whether the
# LEDGER carries rows the charter never closed; this is the OTHER half — whether
# the CHARTER reports closures the ledger does not carry. That is the epic's own
# disease turned on the epic's own decision log: a success claim ("`X` is paid")
# written without reading the store it claims about.
#
# THE HARD PART IS NOT FINDING DISAGREEMENTS. IT IS STATING THE BLIND SPOT.
# The charter is hard-wrapped prose. A same-line lens — a `pds-*` slug and a
# disposition token on ONE line — sees only the claims the line breaks happened
# to keep together. Two demonstrations of that live INSIDE this corpus and are
# named in the adjudication table:
#
#   charter:5854-5855  "NOT paid, checked and standing:" ends a line; the slug
#                      `pds-bl-w16-full-meta-permissive-default` and the word
#                      ACCEPTED begin the next. Read same-line, the claim INVERTS.
#   charter:6293-6294  "`pds-w12-crown-climb-preconditions` is lifecycle" ends a
#                      line; the value `blocked` is on the next. The lens sees
#                      the ASSERTION and never the VALUE.
#
# So this instrument REFUSES to print findings without printing coverage. The
# RESIDUE block is a FLOOR on what the same-line lens cannot reach, and
# `--selftest` PLANTS a synthetic cross-line claim in a COPY of the charter and
# proves the run NAMES it — a completeness claim with an unproven blind spot is
# the vacuous green wearing the lens instead of the corpus.
#
# THE VOCABULARY IS DERIVED, NEVER TRANSCRIBED. A five-word list
# (CLOSED/paid/dissolved/MOOT/stale-open) has been circulating in briefs. It is
# provably incomplete — this run prints how many charter lines assert `done`,
# `cancelled` or a literal `lifecycle_status:` quote that such a lens cannot see.
# The vocabulary here is mined from the charter in-process, in two parts:
#
#   CORE    the DISTINCT lifecycle_status values the LIVE ledger actually holds
#           over the pds- population. Derived from the store, not from prose.
#   IDIOM   every token the charter PREDICATES of a `pds-*` slug (slug … copula …
#           token, adverbs skipped, nominal predication dropped at a determiner),
#           minus the corpus's own stopwords — defined as the 100 most frequent
#           words IN THE CHARTER, so the stoplist is derived from the corpus too.
#
# The IDIOM half is deliberately OVER-inclusive: a completeness lens that errs
# narrow is the disease. Junk that survives is not hidden — it is adjudicated
# NOT-A-DISPOSITION-ASSERTION in the committed table, in the open.
#
# THREE MEASURED FALSE-POSITIVE SOURCES, ALL HANDLED IN THE OPEN:
#   (1) `fails CLOSED` is an ENGINEERING idiom, not a disposition. Excluded
#       explicitly, and the exclusion COUNT AND LINE NUMBERS are printed, so the
#       exclusion is auditable rather than silent.
#   (2) A slug can fire the lens on its OWN NAME (`pds-w29-s3-fake-fails-closed`).
#       Every slug is STRIPPED from the line before any token matching.
#   (3) Eight single ENGINEERING WORDS (`export`, `router`, `five`, `satisfied`,
#       `byte-identical`, `itself`, `guarded`, `cut`) that the charter predicates of
#       a slug in a table cell. Section 3b, and see IDIOM_TOKENS below for the
#       measurement that produced the list. Because IDIOM_VOCAB is mined from the
#       corpus it measures, these RETRO-FIRE: appending prose moves the stopword
#       frontier and turns a byte-identical old line into a new "arrival". Struck
#       from the VOCABULARY, never from the LINE, and section 3b prints the delta
#       by re-running the lens with the exclusion OFF — so the exclusion's own
#       line numbers and fingerprints are MEASURED every run, not transcribed.
#
# HOW IT REDS. On an UNRESOLVED-CLAIM ARRIVAL — a candidate line whose
# (slug, normalized line) fingerprint is not in the committed adjudication table
# — and on a MISCLASSIFIED ARRIVAL, where a row adjudicated NOT-A-TASK now
# resolves in the ledger (or the reverse). NEVER on a count: a count-shaped arm
# over this surface reds on unrelated ledger churn, arrival semantics does not.
# A DISAGREEMENT itself does NOT red — disagreements are FINDINGS for the lead to
# adjudicate; the table records the adjudication and the arrival arm guards it.
#
# NO BARKPARK VERB MAY REPORT SUCCESS ON AN EXIT CODE ALONE (the epic's law):
# every ledger page is scored on the ECHOED limit/offset and an asserted body
# shape, and a slug the paged corpus does not contain is CONFIRMED with a second
# read (`bp task get`) before this run is allowed to call it NOT-A-TASK.
#
# AND THE SECOND READ FAILS CLOSED, because the confirmation used to be the
# fail-open. `resolve()` asked for the row with errors ALLOWED and read a failed
# read as an absence: `None` meant BOTH "the server says no such row" and "no
# answer arrived", and `verdict()` spends `None` as NOT-A-TASK — the class that
# CLEARS the row. Measured 2026-08-03, pre-fix, over ONE fixed ledger snapshot:
# a dead bp (`exit 1`) and, sharper, an EXPIRED TOKEN (exit 3 with perfectly
# VALID JSON, `error.code == "unauthorized"`) each produced output BYTE-IDENTICAL
# to the healthy run — still printing "Each was CONFIRMED with a second read"
# over 14 rows. A JSON-parse check alone would not have caught the second. The
# discriminator was already on the wire and merely discarded: a status now needs
# `ok:true` + a doc, an ABSENCE needs `ok:false` + `error.code == "not_found"`,
# and anything else is UNCHECKED (rc=2) naming the slug. Both shims now rc=2
# while a live bp stays byte-identical to the shipped report.
#
# EXITS: 0 every candidate resolved · 1 arrival (unresolved / misclassified) or
#        a failed selftest · 2 UNCHECKED (missing dep, unreadable transport)
#
# ONE-LINE CORRECTION OWED TO THE DOOR CENSUS (recorded here, NOT applied — that
# file is owned by other wave-45 slices). `scripts/pds-door-census.sh:123`
# disposes this instrument CONTENT-RED on evidence quoting `--selftest` rc=1.
# That evidence is STALE as of this commit: the selftest is now decoupled from
# the corpus and runs rc=0 (3 of 3), while the CONTENT-RED is real and lives on
# `--check`. The row's evidence should read, verbatim:
#
#   pds-charter-ledger-sweep.sh<TAB>CONTENT-RED<TAB>by run 2026-08-03: `--check`
#   rc=1 "RED: an UNRESOLVED-CLAIM ARRIVAL is a charter claim nobody has
#   adjudicated" (59 arrivals); `--selftest` is rc=0 (3 of 3) and no longer
#   hostage to the corpus; blocked on scripts/pds-charter-ledger-adjudication.md,
#   not on price (CPU 3.42 s LOCAL)
#
# `--check` is a real invocation as of this commit and is byte-identical to the
# bare default run.
#
# THAT CORRECTION HAS SINCE BEEN PAID, AND NOT AS WRITTEN ABOVE. `pds-door-census.sh`
# now disposes this instrument ENVIRONMENT, not CONTENT-RED: the wave-49 adjudication
# block cleared the last 47 arrivals and `--check` is rc=0 from a clean archive root,
# so what remains is that the ledger side needs a bp-resolvable server and no required
# gate can run it. The paragraph above is kept as the RECORD of what was owed, not as
# a live instruction — a recorded correction that outlives its payment is exactly the
# stale claim this instrument exists to find.
#
# USAGE
#   bash scripts/pds-charter-ledger-sweep.sh            # the report
#   bash scripts/pds-charter-ledger-sweep.sh --check     # the same run, NAMED
#   bash scripts/pds-charter-ledger-sweep.sh --selftest
#   bash scripts/pds-charter-ledger-sweep.sh --emit-template   # table skeleton
#
set -uo pipefail

CHARTER=".claude/workflows/bp-pds-charter.md"
TABLE="scripts/pds-charter-ledger-adjudication.md"
CACHE=""
MODE="report"
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --charter)        CHARTER="${2:-}"; shift 2 ;;
    --table)          TABLE="${2:-}"; shift 2 ;;
    --ledger-cache)   CACHE="${2:-}"; shift 2 ;;
    # `--check` is the default report under the name the door census cites it by,
    # so an evidence string can quote an invocation that actually exists.
    --check)          MODE="report"; shift ;;
    --emit-template)  MODE="template"; shift ;;
    --residue-slugs)  MODE="residue"; shift ;;
    --selftest)       SELFTEST=1; shift ;;
    -h|--help)        sed -n '2,123p' "$0"; exit 0 ;;   # through the USAGE block
    *) echo "pds-charter-ledger-sweep: UNCHECKED: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  echo "pds-charter-ledger-sweep: UNCHECKED: python3 is not installed — the lens cannot run" >&2; exit 2; }
command -v bp >/dev/null 2>&1 || {
  echo "pds-charter-ledger-sweep: UNCHECKED: bp is not installed — the ledger side cannot be read" >&2; exit 2; }
[ -r "$CHARTER" ] || {
  echo "pds-charter-ledger-sweep: UNCHECKED: charter not readable at '$CHARTER'" >&2; exit 2; }

# One cache per invocation tree, so the selftest's second and third runs read the
# SAME ledger snapshot as the first — a mutation proof must vary ONE thing.
CACHE_OWNED=0
if [ -z "$CACHE" ]; then
  CACHE="$(mktemp -d "${TMPDIR:-/tmp}/pds-charter-ledger-sweep.XXXXXX")" || {
    echo "pds-charter-ledger-sweep: UNCHECKED: cannot create a cache directory" >&2; exit 2; }
  CACHE_OWNED=1
fi
cleanup() { [ "$CACHE_OWNED" = "1" ] && [ -n "${CACHE:-}" ] && rm -rf "$CACHE"; }
trap cleanup EXIT

run_lens() {
  SWEEP_CHARTER="$1" SWEEP_TABLE="$2" SWEEP_CACHE="$CACHE" SWEEP_MODE="$3" \
    python3 -I - <<'PYEOF'
import collections, hashlib, json, os, re, subprocess, sys, time

CHARTER = os.environ["SWEEP_CHARTER"]
TABLE   = os.environ["SWEEP_TABLE"]
CACHE   = os.environ["SWEEP_CACHE"]
MODE    = os.environ.get("SWEEP_MODE", "report")

UNCHECKED = 2
ARRIVAL   = 1

def unchecked(msg):
    print("pds-charter-ledger-sweep: UNCHECKED: " + msg, file=sys.stderr)
    sys.exit(UNCHECKED)

# ---------------------------------------------------------------- the ledger
# Paged, and every page is scored on the ECHOED limit/offset plus an asserted
# body shape. A server that silently caps a page is a TRANSPORT FAILURE here,
# never a smaller board.

def bp_json(args):
    try:
        p = subprocess.run(["bp"] + args, capture_output=True, text=True, timeout=120)
    except Exception as e:                                  # noqa: BLE001
        unchecked("bp %s did not run: %s" % (" ".join(args), e))
    if p.returncode != 0:
        unchecked("bp %s exited %d: %s" % (" ".join(args), p.returncode, p.stderr.strip()[:200]))
    try:
        return json.loads(p.stdout)
    except Exception:                                       # noqa: BLE001
        unchecked("bp %s did not return JSON: %s" % (" ".join(args), p.stdout.strip()[:200]))

def bp_probe(args):
    """The RAW (returncode, parsed-or-None) of a read whose NEGATIVE answer is
    itself evidence. `bp_json` cannot serve this: a read that must distinguish
    "the server said no such row" from "the read did not happen" needs the exit
    code AND the body, and any helper that collapses both into None hands the
    caller a confirmed absence it never confirmed."""
    try:
        p = subprocess.run(["bp"] + args, capture_output=True, text=True, timeout=120)
    except Exception as e:                                  # noqa: BLE001
        unchecked("bp %s did not run: %s" % (" ".join(args), e))
    try:
        return p.returncode, json.loads(p.stdout)
    except Exception:                                       # noqa: BLE001
        return p.returncode, None

LEDGER_PATH = os.path.join(CACHE, "ledger.json")

def load_ledger():
    if os.path.exists(LEDGER_PATH):
        with open(LEDGER_PATH) as fh:
            d = json.load(fh)
        return d["status"], d["pages"]
    status, pages, offset, limit = {}, [], 0, 1000
    while True:
        d = bp_json(["doc", "query", "task", "--fields", "lifecycle_status",
                     "--limit", str(limit), "--offset", str(offset), "-o", "json"])
        r = d.get("result", d)
        for key in ("count", "limit", "offset", "documents"):
            if key not in r:
                unchecked("ledger page at offset %d has no '%s' — body shape unasserted" % (offset, key))
        if r["limit"] != limit or r["offset"] != offset:
            unchecked("ledger page ASKED limit=%d offset=%d and the server ECHOED limit=%s offset=%s"
                      % (limit, offset, r["limit"], r["offset"]))
        if not isinstance(r["documents"], list):
            unchecked("ledger page at offset %d has a non-list 'documents'" % offset)
        # count is the terminator below, so it is scored against what actually
        # arrived. A page whose count and documents disagree is a TRANSPORT
        # FAILURE; read as a short page it ends the walk and hands back a
        # SMALLER BOARD with no error.
        if r["count"] != len(r["documents"]):
            unchecked("ledger page at offset %d says count=%s and delivered %d documents"
                      % (offset, r["count"], len(r["documents"])))
        # `hasMore` is EXACT (the server reads limit+1). When it is present it
        # decides; a short page only ends the walk when nothing contradicts it.
        has_more = r.get("hasMore")
        if has_more is not None and not isinstance(has_more, bool):
            unchecked("ledger page at offset %d has a non-boolean hasMore=%r" % (offset, has_more))
        if has_more is True and r["count"] < limit:
            unchecked("ledger page at offset %d delivered %d of %d rows and the server "
                      "says hasMore=true -- a TRUNCATED page is not the end of the board"
                      % (offset, r["count"], limit))
        for doc in r["documents"]:
            status[doc["_id"]] = doc.get("lifecycle_status")
        pages.append((offset, r["count"]))
        if has_more is False:
            break
        if has_more is None and r["count"] < limit:
            break
        offset += limit
        time.sleep(0.4)
    try:
        os.makedirs(CACHE, exist_ok=True)
        with open(LEDGER_PATH, "w") as fh:
            json.dump({"status": status, "pages": pages}, fh)
    except OSError:
        pass
    return status, pages

STATUS, PAGES = load_ledger()

CONFIRM_PATH = os.path.join(CACHE, "confirm.json")
CONFIRM = {}
if os.path.exists(CONFIRM_PATH):
    with open(CONFIRM_PATH) as fh:
        CONFIRM = json.load(fh)

def resolve(slug):
    """Live lifecycle_status, or None. A slug the paged corpus does not carry is
    CONFIRMED with a second read before this run may call it NOT-A-TASK: the
    paged read is published-perspective, so a draft row would read as absent.

    FAIL-CLOSED, BOTH WAYS. `None` here is the strongest claim this instrument
    makes about a row — it is what CLEARS a NOT-A-TASK adjudication — so it is
    returned ONLY on the server's own `ok:false` + `error.code == "not_found"`.
    A read that merely FAILED (a dead bp, or an expired token answering exit 3
    with perfectly VALID JSON) is not an absence and must not spend as one: both
    were measured BYTE-IDENTICAL to a healthy run before this guard existed."""
    if slug in STATUS:
        return STATUS[slug]
    if slug in CONFIRM:
        return CONFIRM[slug]
    rc, d = bp_probe(["task", "get", slug, "-o", "json"])
    ok_doc  = isinstance(d, dict) and d.get("ok") is True and isinstance(d.get("doc"), dict)
    absent  = (isinstance(d, dict) and d.get("ok") is False
               and isinstance(d.get("error"), dict)
               and d["error"].get("code") == "not_found")
    if not ok_doc and not absent:
        unchecked("second read of '%s' exited %d and answered neither ok:true+doc nor "
                  "ok:false+error.code=not_found — its ABSENCE IS UNPROVEN, and an unproven "
                  "absence must never be spent as NOT-A-TASK (body: %s)"
                  % (slug, rc, json.dumps(d)[:160] if d is not None else "<no JSON on stdout>"))
    st = (d["doc"].get("lifecycle_status") or "unknown") if ok_doc else None
    CONFIRM[slug] = st
    try:
        with open(CONFIRM_PATH, "w") as fh:
            json.dump(CONFIRM, fh)
    except OSError:
        pass
    time.sleep(0.3)
    return st

# --------------------------------------------------------------- the corpus
with open(CHARTER) as fh:
    text = fh.read()
lines = text.split("\n")

SLUG  = re.compile(r"pds-[a-z0-9][a-z0-9-]{3,}(?:\.[a-z]+)?")
COP   = re.compile(r"\b(?:is|was|are|were|been|stays?|stayed|remains?|remained|reads?|becomes?|became)\b", re.I)
TOKEN = re.compile(r"\*{0,2}`?([A-Za-z][A-Za-z_-]{2,})`?\*{0,2}")
IDIOM = re.compile(r"fail(?:s|ed|ing)?[ -]closed|fail-closed", re.I)

# THE SECOND IDIOM EXCLUSION, AND IT IS A TOKEN LIST BECAUSE THE EVIDENCE IS A
# TOKEN LIST. `fails CLOSED` is a PHRASE, so it is excluded as a phrase and it
# drops the whole line. These eight are single ENGINEERING words — the charter
# predicates them of a slug in a table cell ("`export` is atomic", "the router
# is five rounds") and the mined vocabulary then reads them as dispositions.
#
# EVERY ENTRY IS MEASURED, NOT GUESSED, AND THE MEASUREMENT IS NAMED: the wave-46
# adjudication block (scripts/pds-charter-ledger-adjudication.md, "THE VINTAGE
# SPLIT") took each of that wave's 71 arrivals, asked whether the identical
# whitespace-normalised line ALREADY EXISTED at aa81a9b6e — the commit that
# authored the then-105-row table — and found 14 that did. All 14 fired on one of
# these eight tokens and on nothing else. They were RETROACTIVE arrivals: the
# charter line never changed, the LENS changed under it, because IDIOM_VOCAB is
# mined from the corpus it measures and RANK is recomputed over the whole file,
# so appending prose moves the stopword frontier and admits vocabulary that
# retro-fires on byte-identical old lines.
#
# WHAT THIS IS NOT. It is not an allowlist widened until the run goes green: the
# run is ALREADY rc=0 with 0 arrivals before this exclusion exists, so nothing
# here buys a green. It removes 14 adjudications that were lens repair wearing
# an adjudication's clothes, and it removes nothing else — proven by fingerprint
# diff at a pinned charter blob, not asserted.
#
# AND IT IS NARROWER THAN THE PHRASE EXCLUSION ON PURPOSE. A token here is struck
# from the VOCABULARY, never from the LINE: a line that predicates both `export`
# and `CLOSED` of a slug still fires on `CLOSED`. The phrase arm drops lines; this
# arm drops words, so it cannot hide a real disposition riding the same line.
IDIOM_TOKENS = {
    "export",         # charter:1208, :6986, :7915, :7916 — the workspace-export verb
    "router",         # charter:4028, :6986 — a dispatch-table column
    "five",           # charter:4054, :4198, :4375, :10818 — a count of rounds/sites
    "satisfied",      # charter:4511 — a criterion/ratchet predicate, not a lifecycle
    "byte-identical", # charter:4587 — an equality claim about output
    "itself",         # charter:8251 — a reflexive pronoun the DET list does not carry
    "guarded",        # charter:8281 — describes the ARM, never the row
    "cut",            # charter:11592 — dispatch scope ("CUT from this wave")
}

DET   = {"a", "an", "the", "its", "it", "this", "that", "these", "those", "his", "her",
         "their", "our", "one", "two", "three", "not", "no", "only", "still", "also",
         "what", "why", "how", "all"}

words = re.findall(r"[A-Za-z][A-Za-z_'-]{1,}", text)
freq  = collections.Counter(w.lower() for w in words)
RANK  = {w: i for i, (w, _) in enumerate(freq.most_common())}
STOP_RANK = 100          # the corpus's own 100 most frequent words are its stopwords

def predications(line):
    """(slug, token) pairs where THIS line predicates TOKEN of SLUG.
    Every slug is stripped from the window first, so a slug can never fire the
    lens on its own name."""
    out = []
    for m in SLUG.finditer(line):
        tail = SLUG.sub(" ", line[m.end():m.end() + 70])
        cm = COP.search(tail)
        if not cm:
            continue
        seg = tail[cm.end():].strip()
        for _ in range(3):
            t = TOKEN.match(seg)
            if not t:
                break
            w = t.group(1)
            lw = w.lower()
            if lw in DET:            # nominal predication ("is a bare bash default")
                break
            if lw.endswith("ly"):    # adverb — skip to the predicate itself
                seg = seg[t.end():].strip()
                continue
            out.append((m.group(0), w))
            break
    return out

CORE = sorted({v for k, v in STATUS.items() if k.startswith("pds-") and v})
_pred = collections.defaultdict(set)
for _l in lines:
    if IDIOM.search(_l):
        continue
    for _s, _t in predications(_l):
        _pred[_t.lower()].add(_s)

def build_vocab(excluded):
    """(idiom_vocab, vocab, vre) with `excluded` struck from the MINED half only.
    CORE is never touched: it is the ledger's own status values, and a token
    excluded from CORE would make the lens unable to read a real lifecycle."""
    iv = {t: s for t, s in _pred.items()
          if RANK.get(t, 10 ** 9) >= STOP_RANK and not t.endswith("-") and "_" not in t
          and t not in excluded}
    vc = set(iv) | set(CORE)
    vre = re.compile(r"(?<![A-Za-z-])(" +
                     "|".join(sorted((re.escape(t) for t in vc), key=len, reverse=True)) +
                     r")(?![A-Za-z])", re.I)
    return iv, vc, vre

IDIOM_VOCAB, VOCAB, VRE = build_vocab(IDIOM_TOKENS)

TERMINAL_LIVE = {"done", "cancelled"}
LIVE_STATES   = set(CORE) | {"researching"}

def candidates(VOCAB, VRE):
    """Same-line claims, in three shapes: PREDICATION, TABLE row, LIFECYCLE quote."""
    out, idiom_hits = [], []
    for i, l in enumerate(lines):
        if not SLUG.search(l):
            continue
        if IDIOM.search(l):
            idiom_hits.append(i + 1)
            continue
        shapes, hits = [], []
        pr = [(s, t) for s, t in predications(l) if t.lower() in VOCAB]
        if pr:
            shapes.append("PREDICATION")
            hits += pr
        if l.lstrip().startswith("|"):
            cells = [c.strip() for c in l.strip().strip("|").split("|")]
            slugs = [m.group(0) for c in cells for m in SLUG.finditer(c)]
            tbl = []
            if slugs:
                for c in cells:
                    if SLUG.search(c):
                        continue
                    for t in VRE.findall(c):
                        tbl.append((slugs[0], t))
            if tbl:
                shapes.append("TABLE")
                hits += tbl
        lq = re.search(r"lifecycle_status[\"']?\s*[:=]?\s*[\"']?([a-z_]+)", l)
        if lq and lq.group(1) in LIVE_STATES:
            shapes.append("LIFECYCLE_QUOTE")
            hits.append((SLUG.search(l).group(0), lq.group(1)))
        if not hits:
            continue
        slug = hits[0][0]
        norm = " ".join(l.split())
        fp = hashlib.sha1((slug + "|" + norm).encode()).hexdigest()[:12]
        out.append({"line": i + 1, "fp": fp, "slug": slug, "shapes": shapes,
                    "tokens": sorted({t.lower() for _, t in hits}), "text": norm})
    return out, idiom_hits

CANDS, IDIOM_LINES = candidates(VOCAB, VRE)
CAND_LINE_IDX = {c["line"] - 1 for c in CANDS}

# THE EXCLUSION'S OWN DELTA, MEASURED EVERY RUN, NEVER TRANSCRIBED. The lens is
# run a SECOND time with the token exclusion OFF and the two candidate sets are
# differenced. This is the only honest way to print the exclusion's line numbers:
# a token reaches the candidate set down two independent paths (PREDICATION and
# TABLE-cell), so reading the line numbers off the predication fold alone reports
# a TRUE number attached to a FALSE story — `export` would print one line when it
# strikes four. The second pass is pure text over the same `lines`; it costs no
# ledger read and no network.
_IV0, _V0, _VRE0 = build_vocab(set())
CANDS_UNEXCLUDED, _ = candidates(_V0, _VRE0)
_kept = {c["fp"] for c in CANDS}
STRUCK = [c for c in CANDS_UNEXCLUDED if c["fp"] not in _kept]
STRUCK_BY = collections.defaultdict(list)
for _c in STRUCK:
    for _t in _c["tokens"]:
        if _t in IDIOM_TOKENS:
            STRUCK_BY[_t].append(_c)
# A named token that strikes NOTHING is an INERT entry. Printed, never dropped:
# a hand list whose dead entries read as silence is a hand list that rots.
INERT_TOKENS = sorted(t for t in IDIOM_TOKENS if not STRUCK_BY.get(t))

def residue(VRE, CAND_LINE_IDX):
    """Lines carrying a disposition token with a slug WITHIN ±2 LINES but never on
    the same line. This is the FLOOR of what the same-line lens cannot reach —
    not a total: a claim four lines from its slug is in neither number."""
    rlines, rslugs = [], collections.defaultdict(list)
    for i, l in enumerate(lines):
        if i in CAND_LINE_IDX or IDIOM.search(l) or SLUG.search(l):
            continue
        if not VRE.search(l):
            continue
        near = []
        for j in (i - 2, i - 1, i + 1, i + 2):
            if 0 <= j < len(lines):
                near += [m.group(0) for m in SLUG.finditer(lines[j])]
        if not near:
            continue
        rlines.append(i + 1)
        for s in set(near):
            rslugs[s].append(i + 1)
    return rlines, rslugs

RES_LINES, RES_SLUGS = residue(VRE, CAND_LINE_IDX)

if MODE == "residue":
    for s in sorted(RES_SLUGS):
        print("RESIDUE-SLUG %s lines=%s" % (s, ",".join(str(n) for n in RES_SLUGS[s][:4])))
    print("RESIDUE-LINES %d RESIDUE-SLUGS %d" % (len(RES_LINES), len(RES_SLUGS)))
    sys.exit(0)

if MODE == "template":
    print("| fingerprint | line | slug | asserted | note |")
    print("|---|---|---|---|---|")
    for c in CANDS:
        print("| %s | %d | %s | TODO | %s |" % (c["fp"], c["line"], c["slug"], c["text"][:110]))
    sys.exit(0)

# ------------------------------------------------------ the committed table
ASSERTED = {"terminal", "non-terminal", "historical", "non-disposition", "non-task"}
adj = {}
if not os.path.exists(TABLE):
    unchecked("adjudication table not found at '%s' — run --emit-template first" % TABLE)
with open(TABLE) as fh:
    for raw in fh:
        if not raw.lstrip().startswith("|"):
            continue
        cells = [c.strip() for c in raw.strip().strip("|").split("|")]
        if len(cells) < 5 or cells[0] in ("fingerprint",) or set(cells[0]) <= {"-", ":"}:
            continue
        fp, line, slug, asserted, note = cells[0], cells[1], cells[2], cells[3], cells[4]
        if asserted not in ASSERTED:
            unchecked("adjudication row %s carries an unknown verdict class '%s'" % (fp, asserted))
        adj[fp] = {"line": line, "slug": slug, "asserted": asserted, "note": note}

def verdict(c):
    a = adj[c["fp"]]["asserted"]
    live = resolve(c["slug"])
    if a == "non-task":
        return ("MISCLASSIFIED" if live else "NOT-A-TASK"), live
    if live is None:
        return "MISCLASSIFIED", live
    if a in ("historical", "non-disposition"):
        return "NOT-A-DISPOSITION-ASSERTION", live
    if a == "terminal":
        return ("AGREES" if live in TERMINAL_LIVE else "DISAGREES"), live
    return ("AGREES" if live not in TERMINAL_LIVE else "DISAGREES"), live

arrivals = [c for c in CANDS if c["fp"] not in adj]
resolved = [c for c in CANDS if c["fp"] in adj]
rows = []
for c in resolved:
    v, live = verdict(c)
    rows.append((c, v, live))

# ------------------------------------------------------------------ report
def rule(t):
    print("\n" + t)
    print("-" * len(t))

print("PDS CHARTER↔LEDGER SWEEP")
print("charter : %s (%d lines)" % (CHARTER, len(lines)))
print("table   : %s (%d adjudicated rows)" % (TABLE, len(adj)))

rule("1. LEDGER READ — paged, echo-asserted, %d rows" % len(STATUS))
for off, n in PAGES:
    print("  page offset=%-5d rows=%d (echo asserted)" % (off, n))
pdsn = collections.Counter(v for k, v in STATUS.items() if k.startswith("pds-"))
print("  pds- population: %d rows  %s" % (sum(pdsn.values()), dict(pdsn)))
print("  CORE (live distinct lifecycle_status over pds-): %s" % ", ".join(CORE))
print("  CORE IS AN ACCEPTED LIVE-DRIFT CHANNEL, RULED ON, NOT OVERLOOKED. It has moved")
print("  5 -> 6 over an identical charter blob, so a charter that never changes can still")
print("  change this lens. It is NOT pinned, for three reasons: (a) pinning it is the very")
print("  transcription this instrument exists to refuse — a status the ledger newly holds")
print("  would become a word the lens cannot read; (b) it is bounded by the lifecycle enum,")
print("  a small closed set, not by prose anyone may append; (c) its drift is ADDITIVE and")
print("  LOUD — a new CORE token can only ADD candidates, and an unadjudicated candidate is")
print("  an ARRIVAL that reds and is NAMED. The idiom half had neither property, which is")
print("  why that half is excluded above and this half is not.")

rule("2. DERIVED DISPOSITION VOCABULARY — %d tokens (%d CORE + %d charter idiom)"
     % (len(VOCAB), len(CORE), len(IDIOM_VOCAB)))
print("  derivation: CORE = the ledger's own live status values; IDIOM = tokens the")
print("  charter PREDICATES of a pds- slug, minus the charter's own 100 most frequent")
print("  words. Nothing here is transcribed from a brief.")
for t in sorted(VOCAB, key=lambda t: (-len(IDIOM_VOCAB.get(t, ())), t)):
    n = sum(1 for l in lines if re.search(r"(?<![A-Za-z-])" + re.escape(t) + r"(?![A-Za-z])", l, re.I))
    mark = "CORE " if t in CORE else "idiom"
    print("  %-5s %-22s predicated_of_slugs=%-3d charter_lines=%d"
          % (mark, t, len(IDIOM_VOCAB.get(t, ())), n))

five = {"closed", "paid", "dissolved", "moot", "stale-open"}
blind_to_five = [c for c in CANDS if not (set(c["tokens"]) & five)]
def charter_lines_with(pat):
    return sum(1 for l in lines if re.search(pat, l, re.I))
rule("2b. THE FIVE-WORD LIST IN CIRCULATION IS PROVABLY INCOMPLETE")
print("  CLOSED/paid/dissolved/MOOT/stale-open would see %d of %d candidate lines;"
      % (len(CANDS) - len(blind_to_five), len(CANDS)))
print("  it is BLIND to %d of them. Charter lines it cannot read at all:" % len(blind_to_five))
for label, pat in (("done", r"(?<![A-Za-z-])done(?![A-Za-z])"),
                   ("cancelled", r"(?<![A-Za-z-])cancelled(?![A-Za-z])"),
                   ("lifecycle_status:", r"lifecycle_status")):
    print("    %-18s %d charter lines" % (label, charter_lines_with(pat)))

rule("3. `fails CLOSED` IDIOM EXCLUSION — %d slug-bearing lines excluded" % len(IDIOM_LINES))
print("  lines: %s" % ", ".join(str(n) for n in IDIOM_LINES))
print("  (an engineering idiom, not a disposition — the largest measured FP source)")

rule("3b. ENGINEERING-IDIOM TOKEN EXCLUSION — %d of %d named tokens strike %d lines"
     % (len(IDIOM_TOKENS) - len(INERT_TOKENS), len(IDIOM_TOKENS), len(STRUCK)))
print("  Struck from the VOCABULARY, never from the LINE: a line carrying both an excluded")
print("  token and a real disposition still fires on the disposition. The phrase arm above")
print("  drops LINES; this arm drops WORDS, so it cannot hide a disposition riding along.")
print("  DELTA MEASURED, NOT TRANSCRIBED — the lens is re-run with the exclusion OFF and")
print("  the candidate sets differenced. %d candidates without it, %d with."
      % (len(CANDS_UNEXCLUDED), len(CANDS)))
for t in sorted(STRUCK_BY):
    cs = sorted(STRUCK_BY[t], key=lambda c: c["line"])
    print("  %-16s %d line%s: %s" % (t, len(cs), "" if len(cs) == 1 else "s",
                                     ", ".join(str(c["line"]) for c in cs)))
if INERT_TOKENS:
    print("  INERT ENTRIES — named in the exclusion and striking NOTHING at this charter blob.")
    print("  Printed rather than dropped: a hand list whose dead entries read as silence rots")
    print("  unobserved. %s" % ", ".join(INERT_TOKENS))
print("  EVERY STRUCK CANDIDATE, BY FINGERPRINT — so a committed adjudication that stops")
print("  being a candidate is NAMED here, not merely counted as a stale row in section 7:")
print("  %-13s %-6s %-46s %-13s %s" % ("fingerprint", "line", "slug", "committed", "tokens"))
_struck_committed = 0
for c in sorted(STRUCK, key=lambda c: c["line"]):
    _a = adj.get(c["fp"], {}).get("asserted", "-")
    if c["fp"] in adj:
        _struck_committed += 1
    print("  %-13s %-6d %-46s %-13s %s"
          % (c["fp"], c["line"], c["slug"][:46], _a, ",".join(c["tokens"])))
if _struck_committed:
    print("  %d of the %d STILL CARRY A COMMITTED ADJUDICATION. Those rows, and only those,"
          % (_struck_committed, len(STRUCK)))
    print("  are the `stale adjudication rows` in section 7 — retire them there, or the number")
    print("  becomes a permanent advisory that the next genuine dropped claim can hide inside.")
else:
    print("  None of the %d still carries a committed adjudication: every one was retired from"
          % len(STRUCK))
    print("  the table, which is why `stale adjudication rows` in section 7 reads 0.")

rule("4. ADJUDICATION — %d candidate lines / %d slugs, ALL adjudicated" %
     (len(CANDS), len({c["slug"] for c in CANDS})))
print("  %-6s %-13s %-46s %-13s %-8s %s" % ("line", "fingerprint", "slug", "asserted", "live", "verdict"))
for c, v, live in sorted(rows, key=lambda r: r[0]["line"]):
    print("  %-6d %-13s %-46s %-13s %-8s %s"
          % (c["line"], c["fp"], c["slug"][:46], adj[c["fp"]]["asserted"], live or "-", v))
tally = collections.Counter(v for _, v, _ in rows)
print("  tally: %s" % dict(tally))

dis = [(c, v, live) for c, v, live in rows if v == "DISAGREES"]
rule("5. DISAGREEMENTS — %d" % len(dis))
for c, _, live in sorted(dis, key=lambda r: r[0]["line"]):
    print("  charter:%d  %s" % (c["line"], c["slug"]))
    print("    charter asserts : %s" % adj[c["fp"]]["asserted"])
    print("    live lifecycle  : %s" % live)
    print("    note            : %s" % adj[c["fp"]]["note"])
    print("    line            : %s" % c["text"][:150])

nonterm_res = [s for s in RES_SLUGS if (STATUS.get(s) or "") not in TERMINAL_LIVE and s in STATUS]
idiom_only = [c for c in CANDS if not (set(c["tokens"]) & set(CORE))]
nontask = [c for c, v, _ in rows if v == "NOT-A-TASK"]
rule("6. COVERAGE — WHAT THIS LENS CANNOT SEE (printed, never omitted)")
print("  (a) CROSS-LINE RESIDUE — A FLOOR, NOT A TOTAL")
print("      %d charter lines carry a disposition token with a slug within ±2 lines" % len(RES_LINES))
print("      but NEVER on the same line. They expose %d slugs the same-line lens never" % len(RES_SLUGS))
print("      reaches, %d of them LIVE NON-TERMINAL. Same-line coverage of the slugs" % len(nonterm_res))
print("      this corpus discusses: %d of %d (%.0f%%)."
      % (len({c["slug"] for c in CANDS}),
         len({c["slug"] for c in CANDS} | set(RES_SLUGS)),
         100.0 * len({c["slug"] for c in CANDS}) / max(1, len({c["slug"] for c in CANDS} | set(RES_SLUGS)))))
print("      floor, because a claim >2 lines from its slug is in NEITHER number.")
print("      examples: %s" % ", ".join(sorted(nonterm_res)[:6]))
print("  (b) VOCABULARY GAP")
print("      %d of %d candidate lines rest on a CHARTER IDIOM with no ledger status word"
      % (len(idiom_only), len(CANDS)))
print("      on the line — %d distinct slugs. A lens built from ledger statuses alone"
      % len({c["slug"] for c in idiom_only}))
print("      would miss every one of them. Worked example:")
for c in CANDS:
    if c["slug"] == "pds-bl-bp-search-false-negative":
        print("      charter:%d %s -> tokens %s, live %s"
              % (c["line"], c["slug"], c["tokens"], resolve(c["slug"])))
        break
print("  (c) NON-TASK FALSE POSITIVES")
print("      %d candidate lines name a `pds-` string that is NOT a task (script" % len(nontask))
print("      filenames, Paper slugs, planned slugs never filed). Each was CONFIRMED")
print("      with a second read (`bp task get`) before being called NOT-A-TASK:")
for c in sorted(nontask, key=lambda c: c["line"]):
    print("      charter:%-6d %s" % (c["line"], c["slug"]))

rule("7. ARRIVALS — the red arm")
mis = [(c, v, live) for c, v, live in rows if v == "MISCLASSIFIED"]
stale = [fp for fp in adj if fp not in {c["fp"] for c in CANDS}]
print("  unresolved-claim arrivals : %d" % len(arrivals))
for c in arrivals:
    print("    charter:%d %s [%s] %s" % (c["line"], c["slug"], ",".join(c["tokens"]), c["text"][:110]))
print("  misclassified arrivals    : %d" % len(mis))
for c, _, live in mis:
    print("    charter:%d %s adjudicated %s, live reads %s"
          % (c["line"], c["slug"], adj[c["fp"]]["asserted"], live))
print("  stale adjudication rows   : %d (advisory — the charter may drop a claim)" % len(stale))

if arrivals or mis:
    print("\nRED: an UNRESOLVED-CLAIM ARRIVAL is a charter claim nobody has adjudicated.")
    print("Adjudicate it in %s (asserted ∈ %s) and re-run." % (TABLE, "|".join(sorted(ASSERTED))))
    sys.exit(ARRIVAL)
print("\nOK: every one of the %d candidate claims is adjudicated and resolved against the live ledger."
      % len(CANDS))
PYEOF
}

if [ "$SELFTEST" = "1" ]; then
  echo "=== SELFTEST: the lens must be able to MISS, and it must be able to FIRE ==="
  MUT="$CACHE/charter-mutant.md"
  SENTINEL="pds-selftest-cross-line-sentinel"

  # (0) FAIL-CLOSED ORACLE: the corpus must not already contain its own sentinel,
  #     or a "the run named it" pass proves nothing.
  if grep -q "$SENTINEL" "$CHARTER"; then
    echo "SELFTEST FAIL: the charter already contains the sentinel '$SENTINEL'" >&2
    exit 1
  fi

  # (1) THE BLIND SHAPE: slug on one line, the disposition verb on the NEXT.
  cp "$CHARTER" "$MUT" || { echo "SELFTEST UNCHECKED: cannot copy the charter" >&2; exit 2; }
  {
    echo ""
    echo "- **PDS-SELFTEST — the planted cross-line claim.** The row \`$SENTINEL\`"
    echo "  is paid and CLOSED on this wave's numbers."
  } >> "$MUT"

  # NOTE: containment is tested with `case`, never `printf | grep -q`. Under
  # `pipefail`, grep -q exits on its FIRST match and SIGPIPEs the writer, so the
  # pipeline reports 141 and the assertion inverts — a selftest that fails on a
  # PASS. Measured here 2026-08-02; it cost a debugging round, so it is written
  # down rather than re-learned.
  # THE SUBJECT UNDER TEST IS THE PLANT'S DELTA, NEVER THE CORPUS'S HEALTH.
  # This assertion used to demand the literal `unresolved-claim arrivals : 0` in
  # the mutant run — i.e. it demanded the whole charter be ADJUDICATED before the
  # lens could be tested at all. So the selftest died at leg 1 the moment the
  # corpus went red and LEGS 2 AND 3 NEVER RAN. A delta is both decoupled and
  # STRICTLY STRONGER: it pins the cross-line plant at exactly +0 (and, at leg 3,
  # the same-line plant at exactly +1) instead of `== 0` and `!= 0`.
  arrivals_of() {
    printf '%s\n' "$1" \
      | sed -n 's/^ *unresolved-claim arrivals *: *\([0-9][0-9]*\) *$/\1/p' | head -1
  }

  echo "--- same-line lens over the mutant (must NOT flag the planted claim) ---"
  base_out="$(run_lens "$CHARTER" "$TABLE" "report" 2>&1)"; base_rc=$?
  base_n="$(arrivals_of "$base_out")"
  same_line_out="$(run_lens "$MUT" "$TABLE" "report" 2>&1)"; same_line_rc=$?
  mut_n="$(arrivals_of "$same_line_out")"
  case "$same_line_out" in
    *"$SENTINEL"*)
      echo "SELFTEST FAIL: the same-line lens named a CROSS-LINE claim — the plant is wrong" >&2
      exit 1 ;;
  esac
  if [ -z "$base_n" ] || [ -z "$mut_n" ]; then
    echo "SELFTEST FAIL: no arrival count to compare (charter rc=$base_rc '$base_n', mutant rc=$same_line_rc '$mut_n')" >&2
    printf '%s\n' "$same_line_out" | tail -20 >&2
    exit 1
  fi
  if [ "$mut_n" != "$base_n" ]; then
    echo "SELFTEST FAIL: the CROSS-LINE plant moved the arrival count $base_n -> $mut_n (delta must be 0)" >&2
    exit 1
  fi
  echo "same-line lens: rc=$same_line_rc, arrivals $base_n -> $mut_n (delta 0), sentinel NOT flagged — confirmed blind, as claimed"

  echo "--- residue lens over the mutant (MUST name the planted claim) ---"
  res_out="$(run_lens "$MUT" "$TABLE" "residue" 2>&1)"
  case "$res_out" in
    *"RESIDUE-SLUG $SENTINEL"*)
      printf '%s\n' "$res_out" | grep "RESIDUE-SLUG $SENTINEL"
      echo "PROVEN: the run NAMES the planted cross-line claim as residue." ;;
    *)
      echo "SELFTEST FAIL: the residue lens did NOT name '$SENTINEL' — the coverage number is decoration" >&2
      exit 1 ;;
  esac

  # (2) THE ARM MUST ALSO BE ABLE TO FIRE: a SAME-LINE claim is an arrival, and an
  #     arrival must red. A guard that cannot fail is not a guard.
  MUT2="$CACHE/charter-mutant-same-line.md"
  cp "$CHARTER" "$MUT2" || { echo "SELFTEST UNCHECKED: cannot copy the charter" >&2; exit 2; }
  {
    echo ""
    echo "- **PDS-SELFTEST — the planted same-line claim.** \`$SENTINEL\` is CLOSED."
  } >> "$MUT2"
  echo "--- same-line lens over a planted SAME-LINE claim (MUST red as an arrival) ---"
  arr_out="$(run_lens "$MUT2" "$TABLE" "report" 2>&1)"; arr_rc=$?
  arr_n="$(arrivals_of "$arr_out")"
  case "$arr_rc:$arr_out" in
    1:*"$SENTINEL"*)
      printf '%s\n' "$arr_out" | grep "unresolved-claim arrivals"
      printf '%s\n' "$arr_out" | grep "$SENTINEL" | head -1 ;;
    *)
      echo "SELFTEST FAIL: a planted same-line claim did not red (rc=$arr_rc) — the arm cannot fire" >&2
      exit 1 ;;
  esac
  if [ "$arr_n" != "$((base_n + 1))" ]; then
    echo "SELFTEST FAIL: the SAME-LINE plant moved the arrival count $base_n -> $arr_n (delta must be exactly 1)" >&2
    exit 1
  fi
  echo "PROVEN: an unadjudicated same-line claim reds with rc=1, is NAMED, and moves arrivals $base_n -> $arr_n (delta 1)."

  # (3) THE ENGINEERING-IDIOM EXCLUSION, PROVEN BESIDE ITS OWN CONTROL. Leg 2 above
  #     is the control and it has just run: a plant whose predicate is a REAL
  #     disposition (`is CLOSED`) moves arrivals by exactly +1. This leg varies ONE
  #     thing — the predicate becomes an ENGINEERING word from IDIOM_TOKENS — over
  #     the SAME sentence shape, the SAME slug, the SAME ledger snapshot, and demands
  #     exactly +0. Without the exclusion this leg FAILS: `guarded` is predicated of a
  #     pds- slug elsewhere in the charter and sits above the stopword frontier, so it
  #     is in the mined vocabulary and the plant is a candidate. That is the mutation
  #     proof, and it lives here rather than in a report so it re-runs forever.
  MUT3="$CACHE/charter-mutant-idiom.md"
  cp "$CHARTER" "$MUT3" || { echo "SELFTEST UNCHECKED: cannot copy the charter" >&2; exit 2; }
  {
    echo ""
    echo "- **PDS-SELFTEST — the planted engineering-idiom claim.** \`$SENTINEL\` is guarded by the arm."
  } >> "$MUT3"
  echo "--- same-line lens over a planted ENGINEERING-IDIOM claim (must NOT fire) ---"
  idi_out="$(run_lens "$MUT3" "$TABLE" "report" 2>&1)"; idi_rc=$?
  idi_n="$(arrivals_of "$idi_out")"
  # A bare containment test over the WHOLE report is wrong here and was measured
  # wrong: section 3b NAMES every struck candidate, so the sentinel appears in a
  # PASSING run. The two assertions are (a) it is named there, as STRUCK — positive
  # evidence the exclusion acted on this very line, not merely that nothing happened
  # — and (b) it is absent from the ARRIVALS block, which is the section that reds.
  idi_struck="$(printf '%s\n' "$idi_out" | sed -n '/^3b\./,/^4\./p')"
  idi_arr="$(printf '%s\n' "$idi_out" | sed -n '/unresolved-claim arrivals/,/misclassified arrivals/p')"
  case "$idi_struck" in
    *"$SENTINEL"*) : ;;
    *) echo "SELFTEST FAIL: section 3b does not name '$SENTINEL' as struck — the plant never"  >&2
       echo "               reached the exclusion, so a delta of 0 proves nothing" >&2
       exit 1 ;;
  esac
  case "$idi_arr" in
    *"$SENTINEL"*)
      echo "SELFTEST FAIL: an ENGINEERING-IDIOM predicate (\`is guarded\`) still fires the lens" >&2
      printf '%s\n' "$idi_arr" >&2
      exit 1 ;;
  esac
  if [ -z "$idi_n" ] || [ "$idi_n" != "$base_n" ]; then
    echo "SELFTEST FAIL: the ENGINEERING-IDIOM plant moved arrivals $base_n -> '$idi_n' (delta must be 0, rc=$idi_rc)" >&2
    exit 1
  fi
  echo "PROVEN: \`is guarded\` moves arrivals $base_n -> $idi_n (delta 0) while \`is CLOSED\`, the"
  echo "        same sentence with a real disposition, moved $base_n -> $arr_n (delta 1)."

  echo "=== SELFTEST OK: 4 of 4 ==="
  exit 0
fi

run_lens "$CHARTER" "$TABLE" "$MODE"
exit $?
