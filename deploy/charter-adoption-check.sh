#!/usr/bin/env bash
# charter-adoption-check.sh — the deploy-reliability charter's ADOPTION CENSUS,
# re-derived from `.github/workflows/` and compared against what the charter
# itself SAYS it is watched by.
#
# WHY THIS EXISTS (D620, task-fcc819ae8323c377). D616's "WHAT IS NOT DONE HERE"
# asserted that the charter "appears in **no** workflow path filter anywhere".
# That sentence was FALSE ON THE DAY IT WAS WRITTEN — `doc-gates.yml` selected
# the charter on BOTH the `pull_request` and `push` arms, twice over (`**/*.md`
# AND `.claude/workflows/**`). A downstream row was filed off it and inherited
# the false premise. The correction is in the charter; THIS is what stops the
# sentence coming back: an adoption claim nobody re-derives rots the moment a
# `paths:` list moves, and a `paths:` list moves for reasons that have nothing
# to do with this charter.
#
# THE PREDICATE, stated once so the verdict is readable:
#
#   OBSERVED   for each file in .github/workflows/*.yml and each of its
#              `pull_request` / `push` arms that CARRIES a `paths:` or
#              `paths-ignore:` filter: the arm is OBSERVED iff GitHub's path
#              filter would select CHARTER_PATH.
#   DECLARED   the `workflow<TAB|space>arm` lines inside the charter's
#              CHARTER-ADOPTION-SET marker block.
#   VERDICT    OBSERVED must equal DECLARED, exactly, both directions.
#
# Arms with NO path filter at all are deliberately NOT in the declared set: they
# match everything, they change for unrelated reasons, and pinning their roster
# would make this guard red on every unrelated workflow addition. They are
# COUNTED and printed, and the guard asserts the count is non-zero — so
# "nothing watches this charter" can never be written truthfully while it holds.
#
# GITHUB'S NEGATION RULE, implemented exactly and NOT inherited. The last
# matching pattern wins. If NO pattern matches, the path is selected only when
# the list contains no positive pattern at all ("only negative patterns" ⇒
# everything else is included). `scripts/lib/dispatch-filter-census.py`'s
# `matches()` falls back to `any(p.startswith("!"))`, which is the rule for a
# negation-ONLY list applied to a MIXED one — on origin/main that mis-selects
# `deploy.yml`'s push arm (`paths:` carries eight positives and one `!api/test/**`,
# and the charter matches none of them). Noted here, not fixed here: that file
# is the gates fence.
#
# REFUSES rather than passing when it cannot see its inputs: a missing charter,
# a missing marker block, a missing workflow directory and an absent PyYAML all
# exit 2. An absence is never caught by inspection.
#
# ARMS
#   (no args)    the gate. exit 0 agreement, 1 drift, 2 cannot-measure.
#   --selftest   7 hermetic cases over mktemp fixtures: the true tree is GREEN,
#                and each of a dropped row, a stale row, a widened filter, a
#                missing marker block, an empty observed set and a mixed-negation
#                list is proven to be SEEN. No network, no token, plants nothing.

set -uo pipefail

# Inputs are resolved INSIDE gate(), not here. The selftest invokes gate() with
# per-case `VAR=... gate` prefixes, and a top-level expansion would have frozen
# the real repo's paths into every fixture case — which is exactly how a
# selftest reports a uniform verdict while measuring one tree seven times.
BEGIN_MARK='CHARTER-ADOPTION-SET BEGIN'
END_MARK='CHARTER-ADOPTION-SET END'

die() { echo "charter-adoption-check: $*" >&2; exit 2; }

gate() {
  local CHARTER WFDIR SUBJECT
  CHARTER="${CHARTER_ADOPTION_CHARTER:-.claude/workflows/bp-deploy-reliability-charter.md}"
  WFDIR="${CHARTER_ADOPTION_WORKFLOWS:-.github/workflows}"
  # The path the filters are evaluated AGAINST. Defaults to the charter's own
  # repo-relative path; the selftest overrides it so a fixture charter stands in.
  SUBJECT="${CHARTER_ADOPTION_SUBJECT:-.claude/workflows/bp-deploy-reliability-charter.md}"

  [ -f "$CHARTER" ] || die "REFUSE — charter not found: $CHARTER (cannot certify an adoption claim it cannot read)"
  [ -d "$WFDIR" ]   || die "REFUSE — workflow directory not found: $WFDIR"
  python3 -c 'import yaml' 2>/dev/null || die "REFUSE — python3 + PyYAML required (pip install pyyaml). A guard that cannot parse the filters must not certify them."

  CHARTER="$CHARTER" WFDIR="$WFDIR" SUBJECT="$SUBJECT" \
  BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" python3 - <<'PY'
import glob, os, re, sys
import yaml

CHARTER = os.environ["CHARTER"]
WFDIR   = os.environ["WFDIR"]
SUBJECT = os.environ["SUBJECT"]
BEGIN   = os.environ["BEGIN_MARK"]
END     = os.environ["END_MARK"]


def rx(pattern):
    """GitHub filter-pattern -> regex. `**` crosses `/`, `*` and `?` do not."""
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern[i:i + 2] == "**":
                out.append(".*"); i += 2; continue
            out.append("[^/]*"); i += 1; continue
        if c == "?":
            out.append("[^/]"); i += 1; continue
        out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")


def selected(path, patterns):
    """GitHub's rule: last matching pattern wins. No match at all -> selected
    only when the list holds NO positive pattern."""
    verdict, hits = None, []
    for p in patterns:
        neg = p.startswith("!")
        body = p[1:] if neg else p
        if rx(body).match(path):
            verdict = not neg
            hits.append(p)
    if verdict is None:
        verdict = not any(not p.startswith("!") for p in patterns)
    return verdict, hits


def observe():
    files = sorted(glob.glob(os.path.join(WFDIR, "*.yml"))) + \
            sorted(glob.glob(os.path.join(WFDIR, "*.yaml")))
    if not files:
        print(f"charter-adoption-check: REFUSE — no workflow files under {WFDIR}", file=sys.stderr)
        sys.exit(2)
    obs, unfiltered, why = {}, [], {}
    for f in files:
        try:
            doc = yaml.safe_load(open(f))
        except yaml.YAMLError as e:
            print(f"charter-adoption-check: REFUSE — {f} is not parseable YAML: {e}", file=sys.stderr)
            sys.exit(2)
        if not isinstance(doc, dict):
            continue
        on = doc.get("on", doc.get(True))   # PyYAML folds a bare `on:` to True
        if on is None:
            continue
        if isinstance(on, str):
            on = {on: None}
        if isinstance(on, list):
            on = {k: None for k in on}
        if not isinstance(on, dict):
            continue
        base = os.path.basename(f)
        for arm in ("pull_request", "push"):
            if arm not in on:
                continue
            cfg = on[arm]
            has_filter = isinstance(cfg, dict) and ("paths" in cfg or "paths-ignore" in cfg)
            if not has_filter:
                unfiltered.append(f"{base} {arm}")
                continue
            ok, hits = True, []
            if "paths" in cfg:
                ok, hits = selected(SUBJECT, cfg["paths"])
            if ok and "paths-ignore" in cfg:
                ignored, _ = selected(SUBJECT, cfg["paths-ignore"])
                ok = not ignored
            if ok:
                key = f"{base} {arm}"
                obs[key] = hits
                why[key] = hits
    return obs, sorted(unfiltered), why


def declare():
    text = open(CHARTER, encoding="utf-8").read()
    b, e = text.find(BEGIN), text.find(END)
    if b < 0 or e < 0 or e < b:
        print(f"charter-adoption-check: REFUSE — {CHARTER} carries no "
              f"`{BEGIN}` … `{END}` block. The declared adoption set IS the "
              f"thing this guard compares against; without it there is nothing "
              f"to disagree with and a silent pass would be the defect.", file=sys.stderr)
        sys.exit(2)
    rows = set()
    for line in text[b:e].splitlines()[1:]:
        s = line.strip().strip("`")
        if not s or s.startswith("#") or s.startswith("```") or s.startswith("<!--"):
            continue
        parts = s.split()
        if len(parts) != 2 or parts[1] not in ("pull_request", "push"):
            print(f"charter-adoption-check: REFUSE — unreadable declared row {s!r} "
                  f"(want `<workflow>.yml <pull_request|push>`)", file=sys.stderr)
            sys.exit(2)
        rows.add(f"{parts[0]} {parts[1]}")
    return rows


obs, unfiltered, why = observe()
dec = declare()
observed = set(obs)

print("CHARTER ADOPTION CENSUS — which workflow path filters select this charter")
print(f"  subject:    {SUBJECT}")
print(f"  charter:    {CHARTER}")
print(f"  workflows:  {WFDIR}")
print(f"  observed:   {len(observed)} path-filtered arm(s) select it")
for k in sorted(observed):
    print(f"                {k}   via {why[k]}")
print(f"  unfiltered: {len(unfiltered)} arm(s) carry no `paths:` at all and match everything")

rc = 0

if not observed and not unfiltered:
    print("NO-WATCHER: not one workflow arm — filtered or unfiltered — would run on a "
          "change to this charter. The adoption claim in the charter cannot be true.")
    rc = 1

undeclared = sorted(observed - dec)
stale      = sorted(dec - observed)

for k in undeclared:
    print(f"UNDECLARED: `{k}` selects the charter (via {why[k]}) and the charter's "
          f"CHARTER-ADOPTION-SET block does not say so. Add the row, or the next "
          f"reader re-derives the D616 premise.")
    rc = 1
for k in stale:
    print(f"STALE: the charter declares `{k}` watches it and no `paths:` filter there "
          f"selects it today. Either the filter was narrowed or the row was never true.")
    rc = 1

if rc == 0:
    print("AGREEMENT: the declared adoption set is exactly the measured one "
          f"({len(observed)} arm(s)), and {len(unfiltered)} unfiltered arm(s) match everything.")
sys.exit(rc)
PY
}

# ─── SELFTEST ───────────────────────────────────────────────────────────────
mk_wf() { # mk_wf <dir> <name> <paths-yaml-lines...>
  local d="$1" n="$2"; shift 2
  { echo "name: $n"; echo "on:"; echo "  pull_request:"; echo "    paths:";
    for p in "$@"; do echo "      - \"$p\""; done
    echo "  push:"; echo "    branches: [main]"; echo "    paths:";
    for p in "$@"; do echo "      - \"$p\""; done
    echo "jobs:"; echo "  j:"; echo "    runs-on: ubuntu-latest"; echo "    steps:"; echo "      - run: true"
  } > "$d/$n"
}

mk_charter() { # mk_charter <file> <declared rows...>
  local f="$1"; shift
  { echo "# fixture charter"; echo; echo "<!-- $BEGIN_MARK -->"; echo '```';
    for r in "$@"; do echo "$r"; done
    echo '```'; echo "<!-- $END_MARK -->"
  } > "$f"
}

PASS=0; FAIL=0
expect() { # expect <label> <want-rc> <got-rc> [<must-contain> <output>]
  local label="$1" want="$2" got="$3" needle="${4:-}" out="${5:-}"
  if [ "$got" != "$want" ]; then
    echo "  FAIL $label: want exit $want, got $got"; FAIL=$((FAIL+1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "  FAIL $label: exit $got was right but the output never named '$needle'"
    FAIL=$((FAIL+1)); return
  fi
  echo "  ok   $label"; PASS=$((PASS+1))
}

selftest() {
  python3 -c 'import yaml' 2>/dev/null || die "REFUSE — selftest needs python3 + PyYAML"
  local root; root="$(mktemp -d "${TMPDIR:-/tmp}/charter-adoption-selftest.XXXXXX")" || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$root'" EXIT
  local SUBJ=".claude/workflows/bp-deploy-reliability-charter.md"
  local wf="$root/wf"; mkdir -p "$wf"
  mk_wf "$wf" docs.yml   '**/*.md' '.claude/workflows/**'
  mk_wf "$wf" harness.yml '.claude/workflows/bp-deploy-reliability-charter.md'
  mk_wf "$wf" elsewhere.yml 'api/**'

  echo "charter-adoption-check --selftest"

  # A — the TRUE fixture tree is GREEN. A guard that cannot be quiet is noise.
  mk_charter "$root/ok.md" "docs.yml pull_request" "docs.yml push" "harness.yml pull_request" "harness.yml push"
  out=$(CHARTER_ADOPTION_CHARTER="$root/ok.md" CHARTER_ADOPTION_WORKFLOWS="$wf" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "A true tree is quiet" 0 "$rc" "AGREEMENT" "$out"

  # B — a DROPPED declared row must be seen as UNDECLARED.
  mk_charter "$root/drop.md" "docs.yml pull_request" "docs.yml push" "harness.yml pull_request"
  out=$(CHARTER_ADOPTION_CHARTER="$root/drop.md" CHARTER_ADOPTION_WORKFLOWS="$wf" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "B dropped row REDS as UNDECLARED" 1 "$rc" "UNDECLARED: \`harness.yml push\`" "$out"

  # C — a row the tree no longer supports must be seen as STALE.
  mk_charter "$root/stale.md" "docs.yml pull_request" "docs.yml push" \
             "harness.yml pull_request" "harness.yml push" "ghost.yml push"
  out=$(CHARTER_ADOPTION_CHARTER="$root/stale.md" CHARTER_ADOPTION_WORKFLOWS="$wf" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "C stale row REDS as STALE" 1 "$rc" "STALE: the charter declares \`ghost.yml push\`" "$out"

  # D — a WIDENED filter elsewhere in the tree must red even though the charter
  #     file itself did not change. This is the drift the sentence died of.
  local wf2="$root/wf2"; cp -R "$wf" "$wf2"
  mk_wf "$wf2" elsewhere.yml 'api/**' '.claude/workflows/**'
  out=$(CHARTER_ADOPTION_CHARTER="$root/ok.md" CHARTER_ADOPTION_WORKFLOWS="$wf2" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "D a widened filter REDS on an unchanged charter" 1 "$rc" "UNDECLARED: \`elsewhere.yml pull_request\`" "$out"

  # E — no marker block at all must REFUSE (2), never pass.
  printf '# fixture charter with no marker block\n' > "$root/nomark.md"
  out=$(CHARTER_ADOPTION_CHARTER="$root/nomark.md" CHARTER_ADOPTION_WORKFLOWS="$wf" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "E missing marker block REFUSES" 2 "$rc" "carries no" "$out"

  # F — nothing watches it at all: the sentence's own world, and it must red.
  local wf3="$root/wf3"; mkdir -p "$wf3"
  mk_wf "$wf3" elsewhere.yml 'api/**'
  mk_charter "$root/empty.md"
  out=$(CHARTER_ADOPTION_CHARTER="$root/empty.md" CHARTER_ADOPTION_WORKFLOWS="$wf3" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "F a genuinely unwatched charter REDS as NO-WATCHER" 1 "$rc" "NO-WATCHER" "$out"

  # G — the MIXED-NEGATION discrimination case. A `paths:` list carrying
  #     positives AND one `!` must NOT select a path none of its positives
  #     match. This is the exact cell dispatch-filter-census.py gets wrong.
  local wf4="$root/wf4"; mkdir -p "$wf4"
  mk_wf "$wf4" mixed.yml 'api/**' 'deploy/**' '!api/test/**'
  mk_charter "$root/mixed.md"
  out=$(CHARTER_ADOPTION_CHARTER="$root/mixed.md" CHARTER_ADOPTION_WORKFLOWS="$wf4" \
        CHARTER_ADOPTION_SUBJECT="$SUBJ" gate 2>&1); rc=$?
  expect "G mixed positive+negative list does NOT select a non-match" 1 "$rc" "NO-WATCHER" "$out"

  echo "charter-adoption-check --selftest: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         gate ;;
  -h|--help)  sed -n '2,45p' "$0" ;;
  *)          die "unknown argument: $1 (want --selftest or no argument)" ;;
esac
