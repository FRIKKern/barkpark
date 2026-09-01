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
# THE WAIVER IS A COMMENT, NOT A SUBSTRING (hardened 2026-08-18, wave
# ci-gate-script-integrity). The marker used to be tested as a raw substring of
# the line, so ANY occurrence — inside a string literal, inside a sigil, buried
# mid-prose in an unrelated comment, or bare with no reason at all — laundered a
# brand-new unjustified fail-open read to green. It is now accepted ONLY when it
# opens a comment in CODE position (the `#` is outside every string/charlist/
# sigil on the line, per `comment_start` below) AND carries a reason with at
# least 3 word characters. Nine planted shapes lock that in — see --selftest.
#
# BLAST RADIUS, STATED HONESTLY: this gate runs in doc-gates.yml, which
# publishes the ADVISORY "Doc budgets + anchors" context. That is NOT one of
# main's required contexts, so a tenant-scope RED does not block a merge today.
# This hardening makes an advisory security guard honest; it does not make it
# blocking.
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
# Any other argument is a usage error and exits 2 (a typo'd flag must never be
# mistaken for a clean check).
set -euo pipefail

usage() {
  echo "usage: scripts/tenant-scope-check.sh [--baseline|--selftest]" >&2
}

case "${1:-}" in
  ""|--baseline|--selftest) ;;
  *)
    echo "tenant-scope-check: unknown argument: $1" >&2
    usage
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "tenant-scope-check: too many arguments" >&2
  usage
  exit 2
fi

# Absolute path to THIS script. --selftest re-invokes the REAL gate 14 times as
# a bare command word, and a bare invocation is a COMMAND, not a path: run as
# `cd scripts && bash tenant-scope-check.sh --selftest`, the invoked name carries
# no slash, so every re-invocation died with "command not found" (rc 127) — a
# FALSE RED on a legitimate invocation, and one that reads like a broken gate
# rather than a broken call. Resolve it once, absolutely, and use that.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$(dirname "$SELF")")"
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
  bash "$SELF" --baseline >/dev/null

  fail_selftest() { echo "tenant-scope-check --selftest: FAILED — $*"; exit 1; }

  # (0) clean tree passes
  bash "$SELF" >/dev/null 2>&1 || fail_selftest "clean baselined tree did not pass"

  # (a) plant a NEW unjustified fail-open read → must RED
  cat > "$TMP/lib/barkpark/content/leak.ex" <<'EX'
defmodule Demo.Leak do
  def read(q) do
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX
  if bash "$SELF" >/dev/null 2>&1; then
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
  bash "$SELF" >/dev/null 2>&1 || fail_selftest "a justified (# global-read:) read did NOT pass"

  # (c) plant a NEW by-PK Repo.get(Document,…) → must RED
  cat > "$TMP/lib/barkpark/content/leak.ex" <<'EX'
defmodule Demo.Leak do
  def read(id) do
    Repo.get(Document, id)
  end
end
EX
  if bash "$SELF" >/dev/null 2>&1; then
    fail_selftest "a NEW by-PK Repo.get(Document, id) did NOT red the gate"
  fi
  rm -f "$TMP/lib/barkpark/content/leak.ex"
  bash "$SELF" >/dev/null 2>&1 || fail_selftest "tree did not return to green after removing the planted leak"

  # --- the waiver is a COMMENT, not a substring -------------------------------
  # Each probe plants ONE file holding a live, unbaselined fail-open read plus a
  # `# global-read:` occurrence in some position, and asserts the verdict. `red`
  # means the gate must refuse to launder the read; `green` means the waiver is
  # a real, reviewed one and must keep working (the false-red control).
  PROBE="$TMP/lib/barkpark/content/probe.ex"
  probe() {  # probe <red|green> <label>   (file body on stdin)
    local want="$1" label="$2" got
    cat > "$PROBE"
    if bash "$SELF" >/dev/null 2>&1; then got=green; else got=red; fi
    [ "$got" = "$want" ] || fail_selftest "$label: expected $want, got $got"
    rm -f "$PROBE"
  }

  # SPOOF 1 — a string literal on the line above is not a comment.
  probe red "spoof/string-literal-above" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    msg = "# global-read: spoofed from a string literal"
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX

  # SPOOF 2 — the marker inside a string on the SAME line is not a comment.
  probe red "spoof/string-literal-same-line" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    q |> Scope.scope_to_workspace_or_global(nil, nil) |> tag("# global-read: inline")
  end
end
EX

  # SPOOF 3 — a sigil string is not a comment either.
  probe red "spoof/sigil" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    _x = ~s{# global-read: sigil string}
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX

  # SPOOF 4 — a BARE marker states no reviewed reason at all.
  probe red "spoof/bare-marker" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    # global-read:
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX

  # SPOOF 5 — the marker buried mid-prose in an unrelated comment.
  probe red "spoof/buried-in-prose" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    # TODO see ticket about # global-read: policy someday
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX

  # --- four shapes that ALREADY red correctly and must keep reding ------------
  # RED 1 — marker on the line BELOW the read.
  probe red "red/marker-below-the-read" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    q |> Scope.scope_to_workspace_or_global(nil, nil)
    # global-read: too late, this sits below the read
  end
end
EX

  # RED 2 — marker in a DIFFERENT function.
  probe red "red/marker-in-another-function" <<'EX'
defmodule Demo.Probe do
  def other do
    # global-read: justifies this other function, not the read below
    :ok
  end

  def read(q) do
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX

  # RED 3 — marker inside an @moduledoc heredoc, read after the closing quotes.
  probe red "red/marker-in-moduledoc-heredoc" <<'EX'
defmodule Demo.Probe do
  @moduledoc """
  Posture prose.
  # global-read: documented, but documentation is not a waiver
  """
  def read(q), do: q |> Scope.scope_to_workspace_or_global(nil, nil)
end
EX

  # RED 4 — marker as the last content line of a NON-doc heredoc.
  probe red "red/marker-last-line-of-plain-heredoc" <<'EX'
defmodule Demo.Probe do
  def read(q) do
    _blurb = """
    prose
    # global-read: last content line of a plain heredoc
    """
    q |> Scope.scope_to_workspace_or_global(nil, nil)
  end
end
EX

  # --- FALSE-RED CONTROL ------------------------------------------------------
  # The 15 `# global-read:` markers live in api/lib on 2026-08-18, verbatim, each
  # directly above a read of the kind it actually guards. If the hardened
  # predicate ever invalidates a reviewed waiver, this probe REDs and the gate's
  # own self-test says so before a false red reaches anyone.
  probe green "control/15-live-marker-forms" <<'EX'
defmodule Demo.Probe do
  def a(task_id) do
        # global-read: by-PK read for the renewal-family lock key
        case Repo.get(Document, task_id) do
            # global-read: in-lock re-read of the same PK row (see above)
            _doc = Repo.get!(Document, task_id)
        end
  end

  def b(doc_id) do
        # global-read: in-lock by-PK re-read of a candidate row the sweeper's own cross-tenant scan selected — internal Oban worker, tenancy resolved by the candidate query, same posture as the reap re-read above.
        case Repo.get(Document, doc_id) do
        end
  end

  def c(task_id) do
        # global-read: task-close by-PK — task_id IS the Document PK; tenancy is resolved by the caller's CAS claim (worker+epoch) inside this per-task advisory-locked txn, not a workspace_id thread (internal-worker posture).
        case Repo.get(Document, task_id) do
        end
  end

  def d(task_id) do
        # global-read: by-PK re-read inside the stage-family advisory lock — same posture as pulse.ex/stamp.ex; caller authorization is enforced at the API seam.
        case Repo.get(Document, task_id) do
        end
  end

  def e(task_id) do
        # global-read: by-PK re-read inside the close-family advisory lock
        case Repo.get(Document, task_id) do
        end
  end

  def f(doc) do
        # global-read: by-PK re-read inside the listener-beat advisory lock — same posture as pulse.ex/stamp.ex/ttl_sweeper; the caller already resolved the row under its own scope.
        case Repo.get(Document, doc.id) do
        end
  end

  # global-read: FLAT-POSTURE admin console — this LiveView is admin/ops-gated
  def g(q, ws, proj), do: q |> Scope.scope_to_workspace_or_global(ws, proj)

  # global-read: FLAT-POSTURE admin console (see load_books/0) — single-row twin
  def h(q, ws, proj), do: q |> Scope.scope_to_workspace_or_global(ws, proj)

  def i(q, workspace_id, project_id) do
        q
        # global-read: related-read mirrors docs_with_tag/backlinks — route callers always thread a real workspace via scope_opts; nil workspace is the documented single-tenant/direct-caller bridge.
        |> Scope.scope_to_workspace_or_global(workspace_id, project_id)
  end

  def j(q, workspace_id, project_id) do
    q
    # global-read: D45 tag-count distribution is deliberate instance-wide admin telemetry — the daily TagDistribution worker reads across all tenants (workspace_id nil → global); fail-open by design, NOT a per-request tenant read. (marker MUST stay the line directly above the call — tenant-scope-check.sh only reads the immediately-preceding line.)
    |> scope_to_workspace_or_global(workspace_id, project_id)
  end

  def k(q, workspace_id, project_id) do
    q
    # global-read: registered type:tag vocabulary is deliberately workspace-OR-global (charter D3 — global codelist tags are shared; the E3 publish gate must accept both), so the fail-open _including_global family is the intended read here.
    |> Scope.scope_to_workspace_including_global(workspace_id, project_id)
  end

  def l(q, workspace_id, project_id) do
    q
    # global-read: registered type:tag vocabulary is deliberately workspace-OR-global (charter D3 — global codelist tags are shared; the E3 publish gate must accept both), so the fail-open _including_global family is the intended read here.
    |> Scope.scope_to_workspace_including_global(workspace_id, project_id)
  end

  def m(q) do
      q
      # global-read: the dedup wall deliberately reads workspace-OR-global — global/nil-workspace docs are the shared Default back-compat corpus (proven benign-shared by the content-plane object-authz wave, governed by the pdf-bl-anon ruling), so a scoped publish dedups against its own rows PLUS the shared surface and a flat/Default publish dedups against that shared corpus; a fail-closed scope_to_workspace/3 would silently stop matching the shared global duplicates. This closes the cross-tenant leak (workspace-A no longer sees workspace-B's PRIVATE rows) while keeping the intended shared-corpus comparison.
      |> Scope.scope_to_workspace_or_global(
        nil
      )
  end
end
EX

  # A trailing same-line waiver — the shape the raw-substring check existed to
  # support (it survives `#{}` interpolation) — must still work.
  probe green "control/inline-trailing-waiver" <<'EX'
defmodule Demo.Probe do
  def read(q, ws) do
    q |> Scope.scope_to_workspace_or_global(ws, nil) # global-read: deliberate flat-posture read
  end
end
EX

  # --- a scan root that scans NOTHING is a broken gate, not a clean tree ------
  MISSING="$TMP/does-not-exist"
  if TENANT_SCOPE_LIB="$MISSING" bash "$SELF" >/dev/null 2>&1; then
    fail_selftest "a MISSING scan root did NOT red the gate"
  fi
  missing_out="$(TENANT_SCOPE_LIB="$MISSING" bash "$SELF" 2>&1 || true)"
  case "$missing_out" in
    *"scan root missing"*) ;;
    *) fail_selftest "the missing-scan-root failure did not name the missing root" ;;
  esac
  mkdir -p "$TMP/empty-root"
  if TENANT_SCOPE_LIB="$TMP/empty-root" bash "$SELF" >/dev/null 2>&1; then
    fail_selftest "an EMPTY scan root (no *.ex files) did NOT red the gate"
  fi

  # --- argument dispatch ------------------------------------------------------
  bash "$SELF" --baseline >/dev/null 2>&1 || fail_selftest "--baseline stopped dispatching"
  bash "$SELF" >/dev/null 2>&1 || fail_selftest "the bare check stopped dispatching"
  set +e
  bash "$SELF" --zzz-nonsense >/dev/null 2>&1
  unknown_rc=$?
  set -e
  [ "$unknown_rc" = "2" ] || fail_selftest "an unknown argument exited $unknown_rc, expected 2"

  echo "tenant-scope-check --selftest: PASS — gate reds on new fail-open + by-PK reads and on all 5 marker spoofs + 4 out-of-position markers + a missing/empty scan root; passes when genuinely justified (15 live marker forms + inline waiver); unknown args exit 2."
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
#
# It is a COMMENT, not a substring. `JUSTIFY_RE` must match at the start of a
# comment that begins in CODE position — i.e. the `#` is not inside a string,
# charlist or sigil (see `comment_start`) — and the reason must carry real
# content. That kills five spoofs that each used to launder a live unjustified
# fail-open read to green: a string literal on the line above, a string on the
# same line, a sigil, a BARE marker with no reason, and the marker buried
# mid-prose in an unrelated comment.
JUSTIFY_RE = re.compile(r"^#\s*global-read:\s*(.*)$")
# A reason must be a real one: >= 3 word characters, so `# global-read:`,
# `# global-read: "` and `# global-read: ---` are all rejected.
MIN_REASON_WORD_CHARS = 3

# Sigil delimiters that come in pairs (~s{...}, ~w[...], …).
SIGIL_PAIRS = {"(": ")", "[": "]", "{": "}", "<": ">"}


def comment_start(line):
    """Index of the `#` that opens a real comment on `line`, or -1.

    Single-line Elixir scanner: skips `?#` char literals, "…" strings, '…'
    charlists, ~x{…} sigils and heredoc openers, and re-enters code position
    inside `#{}` interpolation. Deliberately line-local — the gate only ever
    asks about the matched line and the one directly above it.
    """
    n = len(line)
    stack = []  # entries: ("str", closing_delim, interpolates) | ("code", "}", False)
    i = 0
    while i < n:
        c = line[i]
        top = stack[-1] if stack else None
        if top is not None and top[0] == "str":
            _, close, interp = top
            if c == "\\":
                i += 2
                continue
            if interp and c == "#" and line[i + 1:i + 2] == "{":
                stack.append(("code", "}", False))
                i += 2
                continue
            if line.startswith(close, i):
                stack.pop()
                i += len(close)
                continue
            i += 1
            continue
        # --- code position ---
        if c == "?" and i + 1 < n:
            # char literal: ?a, ?#, ?\n — never opens a comment
            i += 3 if line[i + 1] == "\\" else 2
            continue
        if c == "#":
            return i
        if c == "~" and i + 1 < n and line[i + 1].isalpha():
            j = i + 1
            while j < n and line[j].isalpha():
                j += 1
            if j < n:
                op = line[j]
                # ~s interpolates, ~S does not
                interp = line[i + 1:j].islower()
                if op in SIGIL_PAIRS:
                    stack.append(("str", SIGIL_PAIRS[op], interp))
                    i = j + 1
                    continue
                if op in "\"'/|":
                    if line.startswith(op * 3, j):
                        stack.append(("str", op * 3, interp))
                        i = j + 3
                        continue
                    stack.append(("str", op, interp))
                    i = j + 1
                    continue
            i = j
            continue
        if c in "\"'":
            if line.startswith(c * 3, i):
                stack.append(("str", c * 3, True))
                i += 3
                continue
            stack.append(("str", c, True))
            i += 1
            continue
        if top is not None and top[0] == "code":
            if c == "{":
                stack.append(("code", "}", False))
                i += 1
                continue
            if c == "}":
                stack.pop()
                i += 1
                continue
        i += 1
    return -1


def justified(line):
    """True when `line` carries a well-formed reviewed `# global-read: <reason>`
    waiver: a code-position comment that OPENS with the marker and states a
    reason of at least MIN_REASON_WORD_CHARS word characters."""
    idx = comment_start(line)
    if idx < 0:
        return False
    m = JUSTIFY_RE.match(line[idx:].rstrip())
    if not m:
        return False
    return len(re.findall(r"\w", m.group(1))) >= MIN_REASON_WORD_CHARS

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
        if justified(rawline) or justified(above):
            continue
        hits.append((i, kind, normalize(rawline)))
    return hits

# A scan root that does not exist (moved tree, typo'd TENANT_SCOPE_LIB override)
# used to scan NOTHING and report "PASS — 0 baselined fail-open tenant read(s)":
# a security gate certifying green forever. It is a hard failure now, in BOTH
# modes — a baseline regenerated from an empty scan is just as laundering.
if not os.path.isdir(lib):
    print("tenant-scope-check: FAILED — scan root missing: %s\n"
          "  The gate scanned nothing. Point TENANT_SCOPE_LIB at the Elixir\n"
          "  source root (default api/lib) — an absent root is a broken gate,\n"
          "  not a clean tree." % lib)
    sys.exit(1)

# Walk api/lib/**/*.ex, collect non-exempt occurrences.
ex_files = 0
occurrences = []  # (rel, kind, norm, lineno)
for dirpath, _dirs, files in os.walk(lib):
    for fn in sorted(files):
        if not fn.endswith(".ex"):
            continue
        ex_files += 1
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, lib)
        if rel in SKIP_FILES:
            continue
        for lineno, kind, norm in scan(path, rel):
            occurrences.append((rel, kind, norm, lineno))

if ex_files == 0:
    print("tenant-scope-check: FAILED — scan root holds no *.ex files: %s\n"
          "  The gate scanned nothing. An empty scan root is a broken gate, not\n"
          "  a clean tree." % lib)
    sys.exit(1)

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
    # NAME the vanished entries. An unnamed count is not actionable: a baselined
    # occurrence that is gone leaves a FREE SLOT, and the counter arithmetic
    # (extra = current - baselined) silently absorbs the next read that matches
    # that triple. Between 2026-07-11 and 2026-09-01 this NOTE reported "1
    # occurrence no longer present" on every run and nobody re-anchored, because
    # finding WHICH one meant hand-diffing a fresh scan against the manifest.
    # The gate knows the answer; printing it turns a seven-week research task
    # into a one-line edit. It stays a NOTE, not a failure — a shrinking
    # fail-open surface is a GOOD change and must not red the branch that made
    # it. Delete the named lines by hand; do NOT regenerate, or unreviewed drift
    # elsewhere in the manifest is absorbed along with them.
    msg += ("\n  NOTE: %d baselined occurrence(s) no longer present — the fail-open "
            "surface shrank.\n  Each is a FREE SLOT that will absorb the next matching "
            "read. Delete these lines\n  from %s (by hand — do not regenerate):"
            % (len(removed), os.path.relpath(baseline_path, os.path.dirname(lib))))
    for rel, kind, norm in sorted(removed):
        msg += "\n    %s\t%s\t%s" % (rel, kind, norm)
print(msg)
sys.exit(0)
PY
