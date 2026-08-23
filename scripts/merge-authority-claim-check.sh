#!/usr/bin/env bash
#
# merge-authority-claim-check.sh — the merge-authority PHANTOM-WARRANT guard.
#
# WHAT THIS SCRIPT'S RED ACTUALLY DOES, said plainly: it runs as a STEP of
# elixir.yml's `path-escape` job. That job is in `elixir-gate`'s `needs` with
# gate value NEVER (elixir.yml:764), and `Elixir gate` is one of the four
# contexts branch protection requires on main under enforce_admins:true. A red
# here therefore reds a REQUIRED context and STOPS THE MERGE. That sentence is
# the entire reason this file exists, and it is checked rather than asserted:
# scripts/elixir-path-escape-check.test.sh derives the job's placement and its
# gate value from the YAML.
#
# ── THE FINDING THIS PAYS ────────────────────────────────────────────────────
#
# The repo already owns one merge-authority guard: `blocking_authority_check`
# in scripts/required-checks-verify.sh (#12631). It is correct and it has NO
# MERGE AUTHORITY. Its only real-tree workflow invocation is
# required-checks-drift.yml:153, inside the job `Required-check spec drift
# (advisory)`, which carries `continue-on-error: true` — an excluded context by
# this repo's own spec (S2 ADVISORY). The cure for a merge-authority phantom was
# itself mounted on a context that cannot stop a merge. This file is the same
# class of check, wired to a context that can.
#
# It is NOT a copy of blocking_authority_check, and deliberately differs on the
# two axes that made that guard narrow:
#
#   1. VOCABULARY. blocking_authority_check matches exactly `(blocking)` in a
#      NAME, plus `BLOCKING|blocks the merge|must block|merge gate` in prose.
#      This one adds: `required`, `gate`/`gates`, `enforce`/`enforces`/
#      `enforced`, `stops the merge`, `cannot merge`, `blocking gate` and
#      `merge authority`. Widening the vocabulary is the point; NEVER narrow it
#      to make a run green — correct the prose or raise the finding instead.
#   2. POSITION. blocking_authority_check reads job NAMES, step NAMES and the
#      comment block ABOVE a job key, plus one whole-FILE header verdict. It is
#      structurally blind to STEP-BODY COMMENTS — the comment lines indented
#      inside a job's `steps:` — because those lines are also the adjacent block
#      of the NEXT job and it drops them on purpose. This guard reads them, and
#      attributes each one to the job it actually sits in.
#
# ── THE SUBJECT IS DELIBERATELY NARROW ───────────────────────────────────────
#
#   * .github/workflows/*.yml and *.yaml — file headers and step-body comments.
#   * docs/ops/merge-gates.md — the doctrine card that names contexts.
#
# Nothing else. A guard that swept the whole tree for the word `gate` would
# drown in its own baseline and be switched off within a week.
#
# ── WHAT COUNTS AS AN UNRESOLVED CLAIM ───────────────────────────────────────
#
# A comment line that asserts merge authority in a scope the COMMITTED SPEC
# (.github/required-checks.json) denies. Scope is resolved FROM the spec — the
# 4 required contexts and the 25 exclusion rows — never from a list typed here:
#
#   * A job is AUTHORITATIVE when its rendered name is a required context, or
#     when it is in the transitive `needs` closure of one, inside its own file.
#   * A file is AUTHORITATIVE when any of its jobs is.
#   * A file-header claim in a file with no authoritative job is UNRESOLVED.
#   * A step-body claim inside a non-authoritative job is UNRESOLVED.
#   * A docs/ops/merge-gates.md line that asserts authority while naming a
#     context the spec's `exclusions` array holds is UNRESOLVED.
#
# TWO THINGS RESOLVE A CLAIM, and both are deliberate:
#
#   * A DENIAL. Prose whose job is to say a context has NO authority ("but
#     NEVER blocks the merge", "is not required", "advisory") is the CURE, not
#     the disease. Reddening a correction is the fastest way to get a guard
#     switched off — required-checks-verify.sh:608 learned that first.
#   * The repo's existing escape hatch, `spec-authority: advisory-ok — <reason>`
#     anywhere in the same contiguous comment block. The reason text is
#     MANDATORY and non-empty: a bare token is a silencer, a reason is a
#     decision somebody can review, so a bare `spec-authority:` still reds.
#
# ── THE BASELINE, AND WHY IT IS NOT ZERO ─────────────────────────────────────
#
# Main is not clean on this vocabulary, and pretending otherwise would mean
# either narrowing the vocabulary (defeating the point) or shipping a red that
# no PR can clear. So the guard forbids the count from RISING, exactly as
# BLOCKING_HEADER_UNRESOLVED_BASELINE=3 does one file over. A new claim reds; a
# removed one prints a note asking for the baseline to come down, because a
# guard that reds on its own repair is a trap.
#
#   BASELINE DERIVED 2026-08-19 against origin/main @ 2b8605d082, by running:
#       bash scripts/merge-authority-claim-check.sh --print-baseline   ->  9
#   RE-DERIVED 2026-08-23 against origin/main @ 0223e0962d (381 commits later —
#   this guard was stranded uncommitted on a worktree since the first
#   derivation and never rode a real PR), by running the same command  ->  16.
#   Seven new claims accrued in the interim (none narrows the vocabulary; each
#   is the same "prose discusses merge authority in a denied scope" shape as
#   the original nine — see the inventory below). Every run prints the current
#   count, so drift is visible before it is fatal, and `--list` prints every
#   row with its file, scope and line.
#
#   THE 16, so the next reader inherits a ledger and not a number. None is a
#   phantom warrant of the #12631 kind — each is prose that discusses merge
#   authority in a denied scope, which the vocabulary cannot tell apart from
#   asserting it, and each is cheaper to leave at the baseline than to reword
#   under a guard that would then red on its own repair:
#     absent-context-census.yml:26           "become eligible to gate a merge"
#     astro-search-finder-test.yml:19        "Gates a PR only once registered as a required check"
#     connectors.yml:65                      a note ABOUT a merge-authority claim that was corrected
#     connectors.yml:163 (shim-confinement)  "This comment said BLOCKING until 2026-08-19"
#     connectors.yml:173 (shim-confinement)  "BLOCKING — it is one of the three held at"
#     connectors.yml:174 (shim-confinement)  "BLOCKING_HEADER_UNRESOLVED_BASELINE=3 in"
#     connectors.yml:226 (test)              "THIS COMMENT OPENED BLOCKING, unlike js-tests.yml's"
#     doc-gates.yml:15                       quotes the "(blocking)" names #12631 deleted
#     go-format.yml:22                       "gofmt drift ceiling (blocking)` is a"
#     required-checks-drift.yml:68           "the human gate `hg-…`. When that lands,"
#     scaffy-catalog-drift.yml:19            "gate a merge pre-merge: drift is a serve-side condition"
#     security.yml:358 (sobelow-inline-overlap) "BLOCKING as of wave 24" (excluded aggregator job)
#     shell-harnesses.yml:11                 "the fleet's merge verb"
#     shell-harnesses.yml:180                "MERGE-GATE AUTOSTAMP BRIDGE (task-8fb6aa7b6d57f737)"
#     shell-harnesses.yml:827 (doc-gates-paths-parity) same bridge banner, second job
#     docs/ops/merge-gates.md:214            "`gofmt drift ceiling (blocking)` … is a real,"
#   A SEVENTEENTH reds. That is the contract.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#
#   bash scripts/merge-authority-claim-check.sh              # the gate
#   bash scripts/merge-authority-claim-check.sh --selftest   # the mutation harness
#   bash scripts/merge-authority-claim-check.sh --list       # every claim row
#   bash scripts/merge-authority-claim-check.sh --print-baseline
#
# An unknown flag exits 2 with a named usage line. That is not decoration:
# scripts/gate-announces-skips.test.sh — the harness already riding this very
# job — swallows an unknown flag at rc=0, and it is the file the next builder
# will copy. A guard that silently accepts `--slftest` is a guard that silently
# does nothing.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/.." && pwd)"

# THE COMMITTED BASELINE. See the derivation block above. Lower it freely;
# raising it requires saying, in the commit message, which new claim was
# accepted and why the committed spec cannot back it.
MERGE_AUTHORITY_CLAIM_BASELINE=16

SPEC_PATH="$REPO_ROOT/.github/required-checks.json"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
DOCS_PATH="$REPO_ROOT/docs/ops/merge-gates.md"
LIST_ROWS=0

usage() {
  cat >&2 <<'USAGE'
usage: merge-authority-claim-check.sh [--selftest] [--list] [--print-baseline]
                                      [--spec <required-checks.json>]
                                      [--workflows <dir>] [--docs <merge-gates.md>]
  (no flags)         scan, and fail if unresolved merge-authority claims rise above the baseline
  --selftest         run the mutation harness against THIS file's own scan function
  --list             print every scanned row (CLAIM, RESOLVED, DENIAL, HATCH)
  --print-baseline   print only the current unresolved count, for deriving the baseline
USAGE
}

# ── THE SCAN ─────────────────────────────────────────────────────────────────
# ONE implementation, called by the gate and by --selftest alike. --selftest
# must never re-type this logic: a sibling link-lint selftest greened with its
# gate fully disarmed because it reimplemented the scan it was supposed to be
# proving (cgsi-s3). The only difference between a gate run and a selftest run
# is WHICH spec / workflows / docs paths get passed in.
scan_subject() {
  local spec="$1" workflows="$2" docs="$3"
  python3 -c '
import json, os, re, sys

spec_path, workflows_dir, docs_path = sys.argv[1], sys.argv[2], sys.argv[3]

# The vocabulary. WIDER than blocking_authority_check on purpose (see header),
# in TWO tiers, because width without a subject is noise and noise is how a
# guard gets switched off.
#
#   STRONG — the phrase asserts merge authority all by itself.
VOCAB_STRONG = re.compile(
    r"(?:\(blocking\)"
    r"|blocks the merge|must block|merge gate|blocking gate|merge authority"
    r"|stops the merge|stop the merge|cannot merge)",
    re.IGNORECASE,
)
#   Shouted BLOCKING stays case-SENSITIVE: lowercased it is an ordinary adjective.
VOCAB_STRONG_CS = re.compile(r"(?<![A-Za-z])BLOCKING(?![A-Za-z])")
#   WIDE — the tokens this guard adds over blocking_authority_check. Each is an
#   ordinary English word the prose in this repo uses descriptively, over and over
#   ("the drift gate", "enforces byte budgets"), so a wide token counts only when
#   it is applied TO THE MERGE in the same line. That conjunction is what makes
#   the widening a finding instead of a 269-row baseline nobody reads.
VOCAB_WIDE = re.compile(
    r"(?:(?<![A-Za-z])required(?![A-Za-z])"
    r"|(?<![A-Za-z])gates?(?![A-Za-z])"
    r"|(?<![A-Za-z])enforces?(?![A-Za-z])"
    r"|(?<![A-Za-z])enforced(?![A-Za-z]))",
    re.IGNORECASE,
)
# The object a wide token has to be applied to. Deliberately does NOT contain
# "required set" / "required context" / "required check": those share the word
# `required` with the wide tier, so every descriptive sentence about the spec
# ("main required set is exactly [...]") would conjoin with itself and count.
# 37 of the first 37 rows measured this way were that self-conjunction.
MERGE_OBJECT = re.compile(
    r"(?:(?<![A-Za-z])merges?(?![A-Za-z])|(?<![A-Za-z])merging(?![A-Za-z])"
    r"|branch protection"
    r"|(?<![A-Za-z])lands?(?![A-Za-z])|(?<![A-Za-z])landing(?![A-Za-z]))",
    re.IGNORECASE,
)

# Prose whose job is to DENY authority is the cure, not the disease.
DENIAL = re.compile(
    r"(?:(?<![A-Za-z])never(?![A-Za-z])|(?<![A-Za-z])not(?![A-Za-z])"
    # The apostrophe class is spelled out rather than written `n.t`: a dot there
    # matches the `no` inside `cannot`, which silently reclassified the
    # strongest claim in the vocabulary ("you cannot merge") as its own denial.
    r"|(?<![A-Za-z])no(?![A-Za-z])|(?<![A-Za-z])n[’\x27]t(?![A-Za-z])"
    r"|(?<![A-Za-z])advisory(?![A-Za-z])|non-blocking"
    # `cannot` is NOT a denial word on its own: "you cannot merge until this
    # passes" is the strongest authority claim in the vocabulary. Only the
    # phrases where `cannot` disowns authority count.
    r"|cannot (?:block|stop|be required|be a merge|carry|red)|no merge authority"
    r"|(?<![A-Za-z])neither(?![A-Za-z])|(?<![A-Za-z])nor(?![A-Za-z])"
    r"|(?<![A-Za-z])excluded(?![A-Za-z])"
    r"|(?<![A-Za-z])skipped(?![A-Za-z]))",
    re.IGNORECASE,
)
HATCH = re.compile(u"spec-authority:[ \\t]*advisory-ok[ \\t]*(?:\u2014|--)[ \\t]*\\S")
HATCH_BAD = re.compile(r"spec-authority:")


# `merge-gates` is a FILE NAME in this repo, not a sentence. Left in, every
# cross-reference to docs/ops/merge-gates.md conjoins `gates` with `merge` and
# lands in the baseline as a claim nobody made. Neutralised before matching, and
# neutralised ONLY as the exact path token, so real prose is untouched.
PATH_NOISE = re.compile(r"merge-gates(?:\.md)?", re.IGNORECASE)


def claims(raw_text):
    text = PATH_NOISE.sub("@@DOC@@", raw_text)
    if VOCAB_STRONG.search(text) or VOCAB_STRONG_CS.search(text):
        return True
    return bool(VOCAB_WIDE.search(text) and MERGE_OBJECT.search(text))


def die(msg):
    sys.stderr.write("FAIL: %s\n" % msg)
    sys.exit(3)


if not os.path.isfile(spec_path):
    die("cannot read the committed spec %s — this guard decides scope FROM the spec, "
        "so with no spec it has no opinion and must never pass vacuously" % spec_path)
spec = json.load(open(spec_path))
required = set()
for c in ((spec.get("protection") or {}).get("required_status_checks") or {}).get("checks", []):
    if c.get("context"):
        required.add(c["context"])
excluded = [r.get("context", "") for r in spec.get("exclusions", []) if r.get("context")]
if not required:
    die("the spec %s lists ZERO required contexts — every scope would read as denied "
        "and the count would be noise, not a finding" % spec_path)

if not os.path.isdir(workflows_dir):
    die("cannot read %s — scanning zero workflows is the vacuous pass this guard refuses"
        % workflows_dir)
files = sorted(
    os.path.join(workflows_dir, f)
    for f in os.listdir(workflows_dir)
    if f.endswith(".yml") or f.endswith(".yaml")
)
if not files:
    die("no *.yml or *.yaml under %s — scanning zero workflows is the vacuous pass "
        "this guard refuses" % workflows_dir)

JOB_RE = re.compile(r"^  ([A-Za-z0-9_.-]+):[ \t]*(?:#.*)?$")
NAME_RE = re.compile(r"^    name:[ \t]*(.*?)[ \t]*$")
NEEDS_RE = re.compile(r"^    needs:[ \t]*(.*?)[ \t]*$")
LIST_RE = re.compile(r"^      - ([A-Za-z0-9_.-]+)[ \t]*$")
COMMENT_RE = re.compile(r"^[ \t]*#[ \t]?(.*)$")
JOBS_RE = re.compile(r"^jobs:[ \t]*$")
TOP_RE = re.compile(r"^[A-Za-z]")


def tmpl_matches_required(rendered):
    # A `name:` carrying an unexpanded ${{ }} renders a family of contexts. Punch
    # the holes out and match as a regex — the same transform required-checks-
    # verify.sh uses — so a matrixed aggregator is not mistaken for a denied job.
    if "${{" not in rendered:
        return rendered in required
    pat = re.escape(rendered)
    pat = re.sub(r"\\\$\\\{\\\{.*?\\\}\\\}", ".+", pat)
    return any(re.match(r"\A" + pat + r"\Z", c) for c in required)


rows = []


def emit(kind, path, scope, lineno, text):
    rows.append("%s\t%s\t%s\t%d\t%s" % (kind, path, scope, lineno, text.strip()[:160]))


for path in files:
    rel = os.path.relpath(path, os.path.dirname(os.path.dirname(workflows_dir)))
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()

    # PASS 1 — the job graph, so authority is a fact read off the spec and never
    # a guess about the filename.
    jobs, cur = {}, None
    in_jobs, in_needs = False, False
    for raw in lines:
        if JOBS_RE.match(raw):
            in_jobs, cur, in_needs = True, None, False
            continue
        if in_jobs and TOP_RE.match(raw):
            in_jobs, cur, in_needs = False, None, False
            continue
        if not in_jobs:
            continue
        m = JOB_RE.match(raw)
        if m:
            cur = m.group(1)
            jobs[cur] = {"name": "", "needs": []}
            in_needs = False
            continue
        if cur is None:
            continue
        m = NAME_RE.match(raw)
        if m:
            v = re.sub(r"[ \t]*#.*$", "", m.group(1)).strip().strip("\"\x27")
            jobs[cur]["name"] = v
            in_needs = False
            continue
        m = NEEDS_RE.match(raw)
        if m:
            v = m.group(1).strip()
            if v.startswith("["):
                jobs[cur]["needs"] = [x.strip().strip("\"\x27")
                                      for x in v.strip("[]").split(",") if x.strip()]
                in_needs = False
            elif v:
                jobs[cur]["needs"] = [v.strip("\"\x27")]
                in_needs = False
            else:
                in_needs = True
            continue
        if in_needs:
            m = LIST_RE.match(raw)
            if m:
                jobs[cur]["needs"].append(m.group(1))
                continue
            if raw.strip():
                in_needs = False

    if not jobs:
        emit("PARSE", rel, "-", 0,
             "no jobs could be read from this workflow — the scan cannot decide its authority")

    authoritative = set(k for k, j in jobs.items() if tmpl_matches_required(j["name"] or k))
    changed = True
    while changed:
        changed = False
        for k in list(authoritative):
            for n in jobs.get(k, {}).get("needs", []):
                if n in jobs and n not in authoritative:
                    authoritative.add(n)
                    changed = True
    file_authoritative = bool(authoritative)

    # PASS 2 — comment blocks. A contiguous run of comment lines is ONE block, so
    # the escape hatch may sit on any line of the block carrying the claim, which
    # is where a human would write it.
    def flush(block, scope, authoritative_scope):
        if not block:
            return
        hatched = any(HATCH.search(t) for _, t in block)
        malformed = (not hatched) and any(HATCH_BAD.search(t) for _, t in block)
        for lineno, text in block:
            if not claims(text):
                continue
            if hatched:
                emit("HATCH", rel, scope, lineno, text)
            elif malformed:
                emit("CLAIM", rel, scope, lineno,
                     "MALFORMED spec-authority annotation (a bare token is a silencer): " + text)
            elif DENIAL.search(text):
                emit("DENIAL", rel, scope, lineno, text)
            elif authoritative_scope:
                emit("RESOLVED", rel, scope, lineno, text)
            else:
                emit("CLAIM", rel, scope, lineno, text)

    block, in_jobs, cur = [], False, None
    for i, raw in enumerate(lines, start=1):
        m = COMMENT_RE.match(raw)
        if m:
            block.append((i, m.group(1)))
            continue
        scope = ("job:" + cur) if (in_jobs and cur) else "header"
        auth = (cur in authoritative) if (in_jobs and cur) else file_authoritative
        flush(block, scope, auth)
        block = []
        if JOBS_RE.match(raw):
            in_jobs, cur = True, None
            continue
        if in_jobs and TOP_RE.match(raw):
            in_jobs, cur = False, None
            continue
        if in_jobs:
            mj = JOB_RE.match(raw)
            if mj:
                cur = mj.group(1)
    scope = ("job:" + cur) if (in_jobs and cur) else "header"
    auth = (cur in authoritative) if (in_jobs and cur) else file_authoritative
    flush(block, scope, auth)

# ── the doctrine card ────────────────────────────────────────────────────────
# A line here is a claim only when it asserts authority AND names a context the
# spec explicitly holds OUT of the required set. Any looser and every sentence
# in a card about merge gates is a hit.
if os.path.isfile(docs_path):
    rel = os.path.basename(docs_path)
    prev_hatch = False
    text_lines = open(docs_path, encoding="utf-8", errors="replace").read().splitlines()
    for i, text in enumerate(text_lines, start=1):
        named = [c for c in excluded if c and c in text]
        hatched = bool(HATCH.search(text)) or prev_hatch
        prev_hatch = bool(HATCH.search(text))
        if not named or not claims(text):
            continue
        kind = "HATCH" if hatched else ("DENIAL" if DENIAL.search(text) else "CLAIM")
        emit(kind, rel, "denied-context:" + named[0], i, text)
else:
    sys.stderr.write("note: %s absent — the doctrine card contributed no rows\n" % docs_path)

sys.stdout.write("".join(r + "\n" for r in rows))
' "$spec" "$workflows" "$docs"
}

count_kind() {
  awk -F'\t' -v k="$1" '$1 == k { n++ } END { print n + 0 }'
}

# ── THE GATE ─────────────────────────────────────────────────────────────────
run_gate() {
  local rows n resolved denial hatch
  rows="$(scan_subject "$SPEC_PATH" "$WORKFLOWS_DIR" "$DOCS_PATH")"

  n="$(printf '%s\n' "$rows" | count_kind CLAIM)"
  resolved="$(printf '%s\n' "$rows" | count_kind RESOLVED)"
  denial="$(printf '%s\n' "$rows" | count_kind DENIAL)"
  hatch="$(printf '%s\n' "$rows" | count_kind HATCH)"

  if [ "$LIST_ROWS" = "1" ]; then
    printf '%s\n' "$rows" | sed '/^$/d'
    echo "----"
  fi

  echo "merge-authority claims: ${n} UNRESOLVED (committed baseline ${MERGE_AUTHORITY_CLAIM_BASELINE}), ${resolved} resolved by a required scope, ${denial} denial prose, ${hatch} annotated advisory-ok"

  if [ "$n" -gt "$MERGE_AUTHORITY_CLAIM_BASELINE" ]; then
    printf '%s\n' "$rows" | awk -F'\t' '$1 == "CLAIM"' >&2
    echo "FAIL: unresolved merge-authority claims rose above the committed baseline ($n > $MERGE_AUTHORITY_CLAIM_BASELINE)." >&2
    echo "      Either the committed spec must back the claim, or the claim must be REWRITTEN to say what is actually true." >&2
    echo "      Never narrow the vocabulary, and never delete the sentence silently — replace it with the true statement." >&2
    return 1
  fi
  if [ "$n" -lt "$MERGE_AUTHORITY_CLAIM_BASELINE" ]; then
    echo "note: now ${n}, below the committed baseline of ${MERGE_AUTHORITY_CLAIM_BASELINE} — lower MERGE_AUTHORITY_CLAIM_BASELINE to ratchet."
  fi
  echo "ok: no merge-authority claim outside the spec's required set beyond the committed baseline"
  return 0
}

# ── THE MUTATION HARNESS ─────────────────────────────────────────────────────
# Every case below runs the REAL scan_subject defined in THIS file, over a
# fixture tree. Disarm the vocabulary, the spec read, the needs closure or the
# step-body pass and these go red — which is the whole claim, and it is proven
# by disarming a RENAMED COPY of this file and watching that COPY's --selftest
# fail, never the pristine original. (required-checks-verify.sh's probe re-execs
# an absolute "$REPO_ROOT/scripts/..." path, so a fully disarmed copy of THAT
# file still prints SELFTEST OK — cgsiw-bl-verify-probe-reexec-vacuity. Nothing
# here re-execs anything: scan_subject is a function of the invoked file.)
st_pass=0
st_fail=0

st_assert() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    st_pass=$((st_pass + 1))
  else
    st_fail=$((st_fail + 1))
    echo "FAIL - $label: wanted '$want', got '$got'" >&2
  fi
}

st_count() {
  local kind="$1" dir="$2"
  scan_subject "$dir/spec.json" "$dir/workflows" "$dir/merge-gates.md" | count_kind "$kind"
}

st_fixture() {
  local name="$1"
  local d="$ST_TMP/$name"
  mkdir -p "$d/workflows"
  cat > "$d/spec.json" <<'JSON'
{
  "protection": { "required_status_checks": { "checks": [ { "context": "Widget gate" } ] } },
  "exclusions": [ { "context": "Doc budgets + anchors", "reason": "S4 PATHS-FILTERED" } ]
}
JSON
  : > "$d/merge-gates.md"
  printf '%s' "$d"
}

selftest() {
  ST_TMP="$(mktemp -d)"
  trap 'rm -rf "$ST_TMP"' RETURN
  local d tok

  # 1. A file header claiming authority in a workflow the spec does not require.
  d="$(st_fixture denied-header)"
  cat > "$d/workflows/denied.yml" <<'YML'
# widget-lint.yml — the lint ratchet. (blocking)
jobs:
  lint:
    name: Widget lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "a denied file header is an unresolved claim" "1" "$(st_count CLAIM "$d")"

  # 2. The same prose in a file that DOES render a required context.
  d="$(st_fixture required-header)"
  cat > "$d/workflows/required.yml" <<'YML'
# widget.yml — the aggregator. (blocking)
jobs:
  aggregate:
    name: Widget gate
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "a required scope resolves the same prose" "0" "$(st_count CLAIM "$d")"
  st_assert "a required scope records it as RESOLVED" "1" "$(st_count RESOLVED "$d")"

  # 3. THE BLIND SPOT. A step-body comment — the position blocking_authority_check
  #    drops on purpose — inside a job the spec denies.
  d="$(st_fixture step-body)"
  cat > "$d/workflows/stepbody.yml" <<'YML'
jobs:
  aggregate:
    name: Widget gate
    runs-on: ubuntu-latest
    steps:
      - run: true
  loose:
    name: Widget extras
    runs-on: ubuntu-latest
    steps:
      - run: true
      # this step BLOCKING the merge whenever the extras drift
      - run: true
YML
  st_assert "a step-body comment in a denied job is seen" "1" "$(st_count CLAIM "$d")"

  # 4. THE NEEDS CLOSURE. The same comment inside a job the required aggregator
  #    needs is resolved, because a red there really does stop the merge.
  d="$(st_fixture needs-closure)"
  cat > "$d/workflows/closure.yml" <<'YML'
jobs:
  ratchet:
    name: Widget path-escape ratchet
    runs-on: ubuntu-latest
    steps:
      - run: true
      # this step BLOCKING the merge whenever the paths drift
      - run: true
  aggregate:
    name: Widget gate
    needs: [ratchet]
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "a step inside the required needs-closure is resolved" "0" "$(st_count CLAIM "$d")"
  st_assert "the needs-closure hit is recorded as RESOLVED" "1" "$(st_count RESOLVED "$d")"

  # 5. THE WIDENED VOCABULARY, one fixture per token this guard adds beyond
  #    blocking_authority_check's. Neuter any one and exactly one goes to 0.
  local i=0
  for tok in "this job is required before merge" \
             "the extras gate must pass before a merge" \
             "it enforces the extras contract before merge" \
             "a red here stops the merge" \
             "until it passes you cannot merge"; do
    i=$((i + 1))
    d="$(st_fixture "vocab-$i")"
    {
      echo "# widget-lint.yml — $tok"
      echo "jobs:"
      echo "  lint:"
      echo "    name: Widget lint"
      echo "    runs-on: ubuntu-latest"
      echo "    steps:"
      echo "      - run: true"
    } > "$d/workflows/denied.yml"
    st_assert "vocabulary sees: $tok" "1" "$(st_count CLAIM "$d")"
  done

  # 5b. AND THE OTHER DIRECTION: a wide token used DESCRIPTIVELY, with no merge
  #     object anywhere in the line, is not a claim. Drop the conjunction and
  #     this goes to 1 while the baseline explodes — measured at 269 rows on
  #     main before the two-tier vocabulary landed.
  d="$(st_fixture vocab-descriptive)"
  cat > "$d/workflows/denied.yml" <<'YML'
# widget-lint.yml — the drift gate for the widget catalog. It enforces the
# byte budget and nothing else.
jobs:
  lint:
    name: Widget lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "a descriptive 'gate'/'enforces' with no merge object is not a claim" "0" "$(st_count CLAIM "$d")"

  # 6. DENIAL PROSE IS THE CURE, NOT THE DISEASE.
  d="$(st_fixture denial)"
  cat > "$d/workflows/denial.yml" <<'YML'
# widget-lint.yml — this name is NEVER a merge gate.
jobs:
  lint:
    name: Widget lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "denial prose does not red" "0" "$(st_count CLAIM "$d")"
  st_assert "denial prose is recorded as DENIAL" "1" "$(st_count DENIAL "$d")"

  # 7. THE ESCAPE HATCH, both directions.
  d="$(st_fixture hatch)"
  cat > "$d/workflows/hatch.yml" <<'YML'
# widget-lint.yml — the lint ratchet. (blocking)
# spec-authority: advisory-ok — reads as blocking, held out by S4 while paths-filtered
jobs:
  lint:
    name: Widget lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "a reasoned hatch resolves the claim" "0" "$(st_count CLAIM "$d")"
  st_assert "the reasoned hatch is recorded" "1" "$(st_count HATCH "$d")"

  d="$(st_fixture hatch-bare)"
  cat > "$d/workflows/hatch.yml" <<'YML'
# widget-lint.yml — the lint ratchet. (blocking)
# spec-authority:
jobs:
  lint:
    name: Widget lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  st_assert "a bare hatch token is a silencer and still reds" "1" "$(st_count CLAIM "$d")"

  # 8. THE DOCTRINE CARD. A line asserting authority over an EXCLUDED context.
  d="$(st_fixture docs)"
  cat > "$d/workflows/required.yml" <<'YML'
jobs:
  aggregate:
    name: Widget gate
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  cat > "$d/merge-gates.md" <<'MD'
- `Doc budgets + anchors` is a required gate and blocks the merge.
- `Widget gate` blocks the merge.
- `Doc budgets + anchors` is NEVER a merge gate; it is paths-filtered.
MD
  st_assert "a doc line claiming authority over an excluded context reds" "1" "$(st_count CLAIM "$d")"
  st_assert "the doc denial line does not" "1" "$(st_count DENIAL "$d")"

  # 9. VACUITY REFUSALS. A missing spec, an empty required set and an empty
  #    workflows dir must all FAIL — never pass having scanned nothing.
  d="$(st_fixture vacuous-no-spec)"
  rm -f "$d/spec.json"
  if scan_subject "$d/spec.json" "$d/workflows" "$d/merge-gates.md" >/dev/null 2>&1; then
    st_assert "a missing spec refuses to scan" "refused" "passed"
  else
    st_assert "a missing spec refuses to scan" "refused" "refused"
  fi

  d="$(st_fixture vacuous-empty-required)"
  cat > "$d/spec.json" <<'JSON'
{ "protection": { "required_status_checks": { "checks": [] } }, "exclusions": [] }
JSON
  if scan_subject "$d/spec.json" "$d/workflows" "$d/merge-gates.md" >/dev/null 2>&1; then
    st_assert "an empty required set refuses to scan" "refused" "passed"
  else
    st_assert "an empty required set refuses to scan" "refused" "refused"
  fi

  d="$(st_fixture vacuous-empty-dir)"
  if scan_subject "$d/spec.json" "$d/workflows" "$d/merge-gates.md" >/dev/null 2>&1; then
    st_assert "an empty workflows dir refuses to scan" "refused" "passed"
  else
    st_assert "an empty workflows dir refuses to scan" "refused" "refused"
  fi

  echo "----"
  echo "$st_pass passed, $st_fail failed"
  [ "$st_fail" -eq 0 ] || return 1
  echo "SELFTEST OK — the scan exercised is scan_subject() as defined in ${BASH_SOURCE[0]}"
  return 0
}

mode="gate"
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) mode="selftest" ;;
    --list) LIST_ROWS=1 ;;
    --print-baseline) mode="baseline" ;;
    --spec) shift; SPEC_PATH="${1:-}" ;;
    --workflows) shift; WORKFLOWS_DIR="${1:-}" ;;
    --docs) shift; DOCS_PATH="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "merge-authority-claim-check.sh: unknown flag '$1' — refusing to run, because a guard that silently accepts a mistyped flag is a guard that silently does nothing" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

case "$mode" in
  selftest) selftest ;;
  baseline) scan_subject "$SPEC_PATH" "$WORKFLOWS_DIR" "$DOCS_PATH" | count_kind CLAIM ;;
  *) run_gate ;;
esac
