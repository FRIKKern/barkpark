#!/usr/bin/env bash
# tenant-scope-check.sh — the fail-OPEN tenant-read baseline gate (barkpark-w9dg
# scar class: the FIXED public-paper cross-workspace leak).
#
# Tenant isolation on the document/graph read spine is scope-by-construction via
# `Barkpark.Content.Scope` — EXCEPT two convention-enforced seams the w9dg
# incident already proved can ship a cross-tenant leak with a green board:
#
#   1. the fail-OPEN scope family — `scope_to_workspace_or_global/3`,
#      `scope_to_workspace_including_global/3`, `scope_to_workspace_global/1` —
#      whose nil-workspace branch returns the query UNTOUCHED (all tenants). A
#      NEW read that reaches for `_or_global` and forgets to thread a real
#      workspace silently widens to every tenant (`scope_to_workspace/3` is the
#      fail-CLOSED sibling — `where: false` on nil — but it is NOT the default on
#      the read spine). See api/lib/barkpark/content/scope.ex.
#   2. by-PK `Repo.get(Document, id)` — no tenant clause. Tenant safety lives at
#      the CALL SITE (the HTTP path resolves via the scoped `find_task_by_doc_id`
#      pre-flight first), not in the query. A NEW caller that hands a raw doc_id
#      to one of these crosses tenants. See api/lib/barkpark/tasks/*.ex.
#
# Both are SAFE TODAY (every live caller threads scope; the w9dg scar is
# test-locked). This gate is DEFENSE-IN-DEPTH: it BASELINES every current
# occurrence (scripts/tenant-scope-baseline.txt) and REDS on a NEW one — the
# next w9dg-shaped read — unless the author marks it with an explicit, reviewed
# `# global-read: <reason>` justification on the matched line or the line
# directly above (the deliberate cross-tenant / flat-posture opt-in, greppable
# forever). It does NOT re-litigate the ratified `_or_global` opt-in; it just
# makes GROWING the fail-open surface a conscious, reviewed act.
#
# Modeled on scripts/studio-literal-check.sh (Python scanner + allowlist + a
# per-line annotation escape hatch). bash 3.2 compatible.
#
# Usage:
#   scripts/tenant-scope-check.sh              # check (CI + merge gate)
#   scripts/tenant-scope-check.sh --baseline   # regenerate the baseline manifest
#   scripts/tenant-scope-check.sh --selftest   # tripwire: prove the gate REDs on a
#                                              # planted read (temp dir; plants nothing
#                                              # in the tree)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# LIB / BASELINE are overridable (the --selftest tripwire points them at a temp
# tree so it can prove the scanner reds without planting in the real source).
LIB="${TENANT_SCOPE_LIB:-$ROOT/api/lib}"
BASELINE="${TENANT_SCOPE_BASELINE:-$ROOT/scripts/tenant-scope-baseline.txt}"

# --- self-test tripwire ------------------------------------------------------
# Mirrors scripts/go-literal-check.sh --selftest: stand up a synthetic api/lib in
# a temp dir, baseline a clean file, then prove (a) a NEW unjustified fail-open
# read REDs naming file:line, (b) the SAME read with a `# global-read:`
# justification PASSES, (c) a NEW by-PK Repo.get(Document,…) REDs. Guards the gate
# against a future edit that silently weakens the scanner.
if [ "${1:-}" = "--selftest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/lib/barkpark/content"
  CLEAN="$TMP/lib/barkpark/content/reader.ex"
  cat > "$CLEAN" <<'EX'
defmodule Demo.Reader do
  def read(q, ws, proj) do
    q |> Scope.scope_to_workspace_or_global(ws, proj) |> Repo.one()
  end
end
EX
  export TENANT_SCOPE_LIB="$TMP/lib"
  export TENANT_SCOPE_BASELINE="$TMP/baseline.txt"
  "$0" --baseline >/dev/null

  fail_selftest() { echo "tenant-scope-check --selftest: FAILED — $*"; exit 1; }

  # (0) clean tree passes
  "$0" >/dev/null 2>&1 || fail_selftest "clean baselined tree did not pass"

  # (a) plant a NEW unjustified fail-open read → must RED
  cat > "$TMP/lib/barkpark/content/leak.ex" <<'EX'
defmodule Demo.Leak do
  def read(q) do
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX
  if "$0" >/dev/null 2>&1; then
    fail_selftest "a NEW unjustified fail-open read did NOT red the gate"
  fi

  # (b) justify it → must PASS
  cat > "$TMP/lib/barkpark/content/leak.ex" <<'EX'
defmodule Demo.Leak do
  def read(q) do
    # global-read: selftest — deliberate cross-tenant read
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX
  "$0" >/dev/null 2>&1 || fail_selftest "a justified (# global-read:) read did NOT pass"

  # (c) plant a NEW by-PK Repo.get(Document,…) → must RED
  cat > "$TMP/lib/barkpark/content/leak.ex" <<'EX'
defmodule Demo.Leak do
  def read(id) do
    Repo.get(Document, id)
  end
end
EX
  if "$0" >/dev/null 2>&1; then
    fail_selftest "a NEW by-PK Repo.get(Document, id) did NOT red the gate"
  fi

  echo "tenant-scope-check --selftest: PASS — gate reds on new fail-open + by-PK reads, passes when justified."
  exit 0
fi

MODE="check"
if [ "${1:-}" = "--baseline" ]; then
  MODE="baseline"
fi

python3 - "$LIB" "$BASELINE" "$MODE" <<'PY'
import os, re, sys

lib, baseline_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

# The scope.ex module OWNS the definitions (`def`/`@spec`) of the fail-open
# family — it is the one true impl, not a leak site. Skip it wholesale.
SKIP_FILES = {"barkpark/content/scope.ex"}

# A real INVOCATION of the fail-open scope family: the name immediately followed
# by `(`. This deliberately excludes `&fun/3` captures, `only: [fun: 3]` imports,
# `@spec fun(` (scope.ex is skipped anyway), and prose "fun/3" mentions — none of
# which widen a read. Matched on a comment/heredoc-stripped copy.
FAIL_OPEN = re.compile(
    r"\b(scope_to_workspace_or_global|scope_to_workspace_including_global|"
    r"scope_to_workspace_global)\s*\(")

# by-PK Document fetch (no tenant clause): Repo.get / Repo.get! on the Document
# schema, bare or fully-qualified.
BY_PK = re.compile(r"\bRepo\.get!?\(\s*(?:Barkpark\.Content\.)?Document\s*,")

# The reviewed opt-in annotation (on the matched line or the line directly above).
JUSTIFY = "# global-read:"

# Length-preserving blank (keeps line numbers + line indices aligned).
def blank(m):
    return re.sub(r"[^\n]", " ", m.group(0))

# Strip @doc/@moduledoc heredocs (prose mentions of the functions live there) and
# full-line `#` comments. We do NOT cut at an inline `#` — Elixir `#{}`
# interpolation makes that unsafe — so a real call sharing a line with a trailing
# comment is still detected; the JUSTIFY check reads the RAW line, so an inline
# `# global-read:` still exempts.
DOC_HEREDOC = re.compile(r'@(?:module)?doc\s+(?:~[A-Za-z])?"""(?:.*?)"""', re.S)

def normalize(line):
    return re.sub(r"\s+", " ", line.strip())

def scan(path, rel):
    raw = open(path, encoding="utf-8").read()
    raw_lines = raw.split("\n")
    s = DOC_HEREDOC.sub(blank, raw)
    stripped_lines = s.split("\n")
    hits = []  # (lineno, kind, normalized_code)
    for i, sline in enumerate(stripped_lines, 1):
        rawline = raw_lines[i - 1]
        # full-line comment → not code
        if re.match(r"^\s*#", sline):
            continue
        kind = None
        if FAIL_OPEN.search(sline):
            kind = "fail-open-scope"
        elif BY_PK.search(sline):
            kind = "by-pk-document-get"
        if not kind:
            continue
        # reviewed opt-in on this line or the line directly above → exempt
        above = raw_lines[i - 2] if i >= 2 else ""
        if JUSTIFY in rawline or JUSTIFY in above:
            continue
        hits.append((i, kind, normalize(rawline)))
    return hits

# Walk api/lib/**/*.ex, collect non-exempt occurrences.
occurrences = []  # (rel, kind, norm, lineno)
for dirpath, _dirs, files in os.walk(lib):
    for fn in sorted(files):
        if not fn.endswith(".ex"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, lib)
        if rel in SKIP_FILES:
            continue
        for lineno, kind, norm in scan(path, rel):
            occurrences.append((rel, kind, norm, lineno))

# Baseline record key: (rel, kind, norm) — line-number-independent, so moving a
# call within a file does not trip the gate; a genuinely NEW read is a new key.
def key(o):
    return (o[0], o[1], o[2])

if mode == "baseline":
    lines = sorted("%s\t%s\t%s" % key(o) for o in occurrences)
    with open(baseline_path, "w", encoding="utf-8") as f:
        f.write("# tenant-scope-baseline — generated by scripts/tenant-scope-check.sh --baseline\n")
        f.write("# Each line is a BASELINED fail-open tenant read (rel<TAB>kind<TAB>code).\n")
        f.write("# A NEW read absent here must carry a reviewed `# global-read:` justification.\n")
        for ln in lines:
            f.write(ln + "\n")
    print("tenant-scope-check: wrote %d baselined occurrence(s) to %s"
          % (len(lines), os.path.relpath(baseline_path, os.path.dirname(lib))))
    sys.exit(0)

# --- check mode -------------------------------------------------------------
from collections import Counter
try:
    with open(baseline_path, encoding="utf-8") as f:
        base = Counter()
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            parts = ln.rstrip("\n").split("\t")
            if len(parts) == 3:
                base[tuple(parts)] += 1
except FileNotFoundError:
    print("tenant-scope-check: FAILED — baseline missing: %s\n"
          "  Run: scripts/tenant-scope-check.sh --baseline" % baseline_path)
    sys.exit(1)

cur = Counter(key(o) for o in occurrences)
# Map key -> sorted line numbers for reporting new hits.
locs = {}
for rel, kind, norm, lineno in occurrences:
    locs.setdefault((rel, kind, norm), []).append(lineno)

new_hits = []
for k, n in cur.items():
    extra = n - base.get(k, 0)
    if extra > 0:
        # report the last `extra` line numbers as the newly-introduced ones
        for lineno in sorted(locs[k])[-extra:]:
            new_hits.append((k[0], lineno, k[1], k[2]))

removed = [k for k in base if cur.get(k, 0) < base[k]]

if new_hits:
    print("tenant-scope-check: FAILED — NEW fail-open tenant read(s) introduced "
          "without a reviewed `# global-read:` justification.\n")
    for rel, lineno, kind, norm in sorted(new_hits):
        print("  %s:%s  [%s]  %s" % (rel, lineno, kind, norm))
    print("\n  A tenant-scoped read MUST thread a real workspace_id through the "
          "fail-CLOSED\n  Scope.scope_to_workspace/3 (where:false on nil), NOT the "
          "fail-OPEN _or_global\n  family; a by-PK Repo.get(Document, id) must be "
          "pre-filtered by tenant.\n  If this read is DELIBERATELY cross-tenant / "
          "flat-posture (admin, global\n  schema, internal worker resolving tenancy "
          "another way), mark it with an\n  explicit `# global-read: <reason>` "
          "comment on the line or directly above,\n  or (if it is an expected "
          "baseline change) run: scripts/tenant-scope-check.sh --baseline")
    sys.exit(1)

msg = "tenant-scope-check: PASS — %d baselined fail-open tenant read(s), no new unjustified reads." % sum(cur.values())
if removed:
    msg += ("\n  NOTE: %d baselined occurrence(s) no longer present — the fail-open "
            "surface shrank.\n  Consider re-running --baseline to tighten the manifest."
            % len(removed))
print(msg)
sys.exit(0)
PY
