#!/usr/bin/env bash
# nil-polarity-check.sh — the visibility fail-CLOSED gate (ctx-compression W1, s3).
#
# Barkpark's field-visibility chokepoints treat a nil/caller-less principal as the
# MOST RESTRICTIVE anonymous one — never a full-content bypass. This was the WS-B
# leak class: a `nil` caller that fell through to `do: true` (or forwarded the raw
# snapshot verbatim) dumped private fields into a filter/order clause or an SSE
# stream. ctx-s3 flipped both nil clauses (`Envelope.field_readable?/3`) and the
# `:244` catch-all to fail closed, and REMOVED the fail-open nil clause of
# `ListenController.redacted_result/4`. This gate keeps it that way: it FAILS when
# a nil/caller-less clause of either predicate reappears in a FAIL-OPEN shape.
#
# It is the visibility-scoped twin of scripts/go-literal-check.sh — Credo does not
# exist in this repo, so a bash+python static grep gate is the fence. Wired into
# doc-gates.yml right after its own --selftest so it can't rot.
#
# FORBIDDEN shapes (production .ex only — test files carry nil as DATA and are out
# of scope by construction):
#   1. `field_readable?(…, nil), do: true`  — the fail-OPEN nil caller clause.
#      The fail-closed form `…, do: false` passes by construction.
#   2. `def field_readable?(…, _…), do: true` where the LAST arg is a bare
#      `_ctx`/`_` catch-all — the fail-OPEN catch-all (the `:244` clause). The
#      fail-closed `do: false` form passes.
#   3. `def redacted_result(…nil…)` — ANY nil-caller clause of the SSE redaction
#      seam; ctx-s3 removed it entirely (a nil caller has no request-path origin
#      and forwarding the frozen snapshot is a fail-OPEN leak).
#
# It strips Elixir `#` comments string-safely, so a doctrine comment that MENTIONS
# `field_readable?` or `nil` never trips it; only real code clauses do.
# Usage: scripts/nil-polarity-check.sh   (check; CI + merge gate)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The tree the scan walks. Normally the repo root; the --selftest corpus arm
# points it at a scratch tree so the REAL corpus path can be made to LOSE.
SCAN_ROOT="${NIL_POLARITY_ROOT:-$ROOT}"

# CORPUS FLOOR — the denominator is ADJUDICATED, not printed (honest-gates).
# `scanned` is derived from the same os.walk that produces the verdict, so a
# corpus that vanished reports "PASS — 0 file(s) scanned" and exits 0: the one
# signal that the protected tree is gone is prose, read by nothing.
#
# Two independent adjudications, both applied below:
#   1. A HARD MINIMUM. Derivation: origin/main 964935f5e carries 872 *.ex files
#      under api/lib, and that count has only ever grown. 200 is ~23% of it —
#      an order of magnitude above "the walk found a stub" and far below any
#      plausible real tree, so it can only fire on a corpus that is gone or
#      catastrophically truncated, never on ordinary churn. Override for a
#      deliberate re-baseline with NIL_POLARITY_FLOOR.
#   2. AN INDEPENDENT COUNT. `find` walks the same tree with a different
#      implementation and the scanned count must EQUAL it — so a walk that
#      silently skips a subtree (a permission error swallowed, a filter typo)
#      is caught even while the total stays above the floor. A floor alone
#      cannot see that; equality alone cannot see an empty tree. Both, or the
#      denominator is still derived from the property it is supposed to prove.
CORPUS_FLOOR="${NIL_POLARITY_FLOOR:-200}"

# --selftest — the DURABLE tripwire (distrust vacuous green). Proves the gate
# REDs on each planted fail-open shape and greens on the fail-closed forms,
# planting NOTHING in the real tree (a temp dir, cleaned on exit). It drives the
# REAL scanner via NIL_POLARITY_SELFTEST so a future edit that weakens the
# lexer/patterns is caught here, not just in prose.
#
# Refuse an argument this gate does not understand first. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
    echo "nil-polarity-check: unknown argument '$1' (expected nothing or --selftest)" >&2
    exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # 1) A planted fail-OPEN nil `field_readable?` clause MUST fail, naming file:line.
    cat >"$tmp/planted_field.ex" <<'EX'
defmodule Demo do
  def field_readable?(_schema, _field_name, nil), do: true
  def field_readable?(_schema, _field_name, %CallerContext{} = ctx), do: ctx
end
EX
    if out="$(NIL_POLARITY_SELFTEST="$tmp/planted_field.ex" bash "$0" 2>&1)"; then
        echo "nil-polarity-check --selftest: FAIL — planted nil=>true field_readable? NOT caught (gate is blind)."
        echo "$out"; exit 1
    fi
    # NEVER `printf '%s' "$out" | grep -q …` here (honest-gates D37). Under
    # `set -o pipefail`, `grep -q` exits at its FIRST match while printf is
    # still writing; printf dies of SIGPIPE and the pipeline's status is 141,
    # which this `if !` reads as "no match". That is a coin flip on macOS
    # (26/30 red on a clean tree, later 20/20) and a permanent green on Linux,
    # where coreutils buffers the whole payload — the verdict becomes a
    # property of the machine. A herestring feeds grep from a temp file: one
    # process, one exit status, no pipe to break.
    if ! grep -q 'planted_field.ex:2' <<<"$out"; then
        echo "nil-polarity-check --selftest: FAIL — RED did not name the planted file:line."
        echo "$out"; exit 1
    fi

    # 2) A planted fail-OPEN catch-all MUST fail.
    cat >"$tmp/planted_catchall.ex" <<'EX'
defmodule Demo do
  def field_readable?(_schema, _field_name, _ctx), do: true
end
EX
    if NIL_POLARITY_SELFTEST="$tmp/planted_catchall.ex" bash "$0" >/dev/null 2>&1; then
        echo "nil-polarity-check --selftest: FAIL — planted catch-all nil=>true NOT caught."
        exit 1
    fi

    # 3) A planted fail-OPEN redacted_result nil clause MUST fail.
    cat >"$tmp/planted_seam.ex" <<'EX'
defmodule Demo do
  def redacted_result(event, _dataset, nil, _scope), do: event.document
end
EX
    if NIL_POLARITY_SELFTEST="$tmp/planted_seam.ex" bash "$0" >/dev/null 2>&1; then
        echo "nil-polarity-check --selftest: FAIL — planted redacted_result nil clause NOT caught."
        exit 1
    fi

    # 4) The fail-CLOSED forms MUST pass.
    cat >"$tmp/clean.ex" <<'EX'
defmodule Demo do
  # A doctrine comment mentioning field_readable? and nil must NOT trip the gate.
  def field_readable?(_schema, _field_name, nil), do: false
  def field_readable?(_schema, _field_name, :internal), do: true
  def field_readable?(_schema, _field_name, _ctx), do: false
  def redacted_result(event, dataset, %CallerContext{} = ctx, scope), do: {event, dataset, ctx, scope}
end
EX
    if ! NIL_POLARITY_SELFTEST="$tmp/clean.ex" bash "$0" >/dev/null 2>&1; then
        echo "nil-polarity-check --selftest: FAIL — a fail-CLOSED file was wrongly flagged (gate over-triggers)."
        NIL_POLARITY_SELFTEST="$tmp/clean.ex" bash "$0" || true
        exit 1
    fi

    # 5) THE REAL CORPUS PATH, both ways. Arms 1-4 all drive synthetic files
    #    through NIL_POLARITY_SELFTEST, so not one of them touches the ROOTS
    #    walk, the file count, or the floor — the machinery that decides
    #    whether the gate measured anything at all. This arm exercises exactly
    #    that path, and it can LOSE: point ROOT at an empty tree and the gate
    #    MUST refuse; point it at the real tree and it MUST pass.
    mkdir -p "$tmp/emptytree/api/lib"
    if out="$(NIL_POLARITY_ROOT="$tmp/emptytree" bash "$0" 2>&1)"; then
        echo "nil-polarity-check --selftest: FAIL — an EMPTY corpus was reported clean (the file count is not adjudicated)."
        echo "$out"; exit 1
    fi
    if ! grep -q 'REFUSED' <<<"$out"; then
        echo "nil-polarity-check --selftest: FAIL — the empty-corpus exit did not name the refusal."
        echo "$out"; exit 1
    fi
    # ...and the same path must still PASS on the tree this repo actually has,
    # so the refusal above is not simply "the corpus path always reds".
    if ! out="$(NIL_POLARITY_ROOT="$ROOT" bash "$0" 2>&1)"; then
        echo "nil-polarity-check --selftest: FAIL — the REAL corpus path did not pass on this tree."
        echo "$out"; exit 1
    fi
    if ! grep -q 'PASS' <<<"$out"; then
        echo "nil-polarity-check --selftest: FAIL — the real-corpus run exited 0 without a PASS line."
        echo "$out"; exit 1
    fi

    echo "nil-polarity-check --selftest: PASS — REDs on nil=>true clause, catch-all, and redacted_result nil seam; passes fail-closed forms + doctrine comments; REFUSES an empty corpus and passes the real one."
    exit 0
fi

# The INDEPENDENT count: a different walker over the same tree. `-type f -o
# -type l` matches what os.walk puts in its `files` list (regular files plus
# symlinks-to-files), so the two counts are comparable by construction. Empty
# in NIL_POLARITY_SELFTEST mode — that mode scans one named synthetic file and
# has no corpus to adjudicate.
expected_ex=""
if [ -z "${NIL_POLARITY_SELFTEST:-}" ]; then
    # `|| true`: a MISSING api/lib makes `find` exit non-zero, and under
    # `set -euo pipefail` the failed command substitution would kill this
    # script silently with status 1 and NOT ONE LINE of output — a refusal
    # nobody can read is barely better than the false green it replaced. `wc`
    # still emits 0 on the empty stream, so the empty corpus reaches the
    # adjudication below and gets named there.
    expected_ex="$(find "$SCAN_ROOT/api/lib" \( -type f -o -type l \) -name '*.ex' 2>/dev/null | wc -l | tr -d ' ' || true)"
fi

python3 - "$SCAN_ROOT" "$expected_ex" "$CORPUS_FLOOR" <<'PY'
import os, re, sys

root = sys.argv[1]
expected_ex = sys.argv[2]
corpus_floor = int(sys.argv[3])

# NIL_POLARITY_SELFTEST override: scan ONLY that one file (the --selftest tripwire
# points the REAL scanner at a throwaway temp file — same lexer, same patterns).
_selftest = os.environ.get("NIL_POLARITY_SELFTEST")
if _selftest:
    FILES = [_selftest]
    ROOTS = []
else:
    # Production Elixir only. Test trees carry nil as DATA fixtures and are out of
    # scope by construction (they assert the fail-closed behaviour with nil args).
    ROOTS = [os.path.join(root, "api", "lib")]
    FILES = []

# The two fail-OPEN nil clauses this gate forbids re-growing:
#   A. field_readable?(… , nil), do: true      — nil caller returning true
#   B. def field_readable?(…, _<catchall>), do: true  — catch-all returning true
#   C. def redacted_result(… nil …)            — any nil-caller SSE seam clause
FIELD_NIL_TRUE = re.compile(
    r"field_readable\?\s*\([^)]*\bnil\s*\)\s*,\s*do:\s*true")
FIELD_CATCHALL_TRUE = re.compile(
    r"def\s+field_readable\?\s*\([^)]*,\s*_[A-Za-z0-9_]*\s*\)\s*,\s*do:\s*true")
REDACTED_NIL = re.compile(
    r"def\s+redacted_result\s*\([^)]*\bnil\b[^)]*\)")

CHECKS = [
    (FIELD_NIL_TRUE,
     "field_readable? nil-caller clause must FAIL CLOSED (`do: false`), never `do: true`"),
    (FIELD_CATCHALL_TRUE,
     "field_readable? catch-all clause must FAIL CLOSED (`do: false`), never `do: true`"),
    (REDACTED_NIL,
     "redacted_result nil-caller clause reintroduced — it forwards the unredacted snapshot (fail-OPEN); removed by ctx-s3"),
]


def strip_comments_line(line):
    # String-safe `#`-to-EOL strip for one Elixir line: honour "…"/'…' strings and
    # the `?#` char literal, so a `#` inside a string or a doctrine comment cannot
    # hide/forge a match. Heredocs/sigils are irrelevant here — the forbidden
    # shapes are single-line def clauses, never inside a heredoc body.
    out = []
    i, n = 0, len(line)
    quote = ""
    while i < n:
        c = line[i]
        if quote:
            out.append(c)
            if c == "\\" and quote != "'":
                if i + 1 < n:
                    out.append(line[i + 1])
                    i += 2
                    continue
            elif c == quote:
                quote = ""
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "?" and i + 1 < n:  # ?# char literal — keep both, skip specialness
            out.append(c)
            out.append(line[i + 1])
            i += 2
            continue
        if c == "#":
            break  # rest of the line is a comment
        out.append(c)
        i += 1
    return "".join(out)


def scan(path):
    hits = []
    with open(path, encoding="utf-8") as fh:
        for i, raw in enumerate(fh, 1):
            code = strip_comments_line(raw.rstrip("\n"))
            for rx, msg in CHECKS:
                if rx.search(code):
                    hits.append((i, raw.strip(), msg))
    return hits


def ex_files():
    for base in ROOTS:
        for dirpath, _dirs, files in os.walk(base):
            for fn in sorted(files):
                if fn.endswith(".ex"):
                    yield os.path.join(dirpath, fn)
    for f in FILES:
        yield f


failures = []
scanned = 0
for path in ex_files():
    rel = os.path.relpath(path, root)
    scanned += 1
    for ln, text, msg in scan(path):
        failures.append((rel, ln, text, msg))

# ── ADJUDICATE THE DENOMINATOR ───────────────────────────────────────────────
# Before any verdict: prove the scan actually READ the corpus. A gate whose
# only report of its own coverage is a printed number cannot detect that the
# thing it protects went away — "PASS — 0 file(s) scanned" and "PASS — 872
# file(s) scanned" were byte-for-byte the same exit status.
if not _selftest:
    corpus = ROOTS[0]
    if scanned == 0:
        print("nil-polarity-check: REFUSED — the corpus is EMPTY: 0 Elixir "
              f"file(s) found under {corpus}.\n\n"
              "  Nothing was scanned, so nothing was proven. This is NOT a pass:\n"
              "  the fail-OPEN visibility clauses this gate forbids would be\n"
              "  invisible to it. Check out the api/lib tree (or point\n"
              "  NIL_POLARITY_ROOT at a checkout that has it) and re-run.")
        sys.exit(1)
    if scanned < corpus_floor:
        print(f"nil-polarity-check: REFUSED — only {scanned} Elixir file(s) "
              f"scanned under {corpus}, below the corpus floor of "
              f"{corpus_floor}.\n\n"
              "  The tree this gate protects has never been this small. Either\n"
              "  the checkout is truncated or the walk lost a subtree; either\n"
              "  way the coverage is not what a green claims. Re-run on a full\n"
              "  checkout, or re-baseline NIL_POLARITY_FLOOR deliberately.")
        sys.exit(1)
    if expected_ex and int(expected_ex) != scanned:
        print(f"nil-polarity-check: REFUSED — coverage disagreement: the walk "
              f"scanned {scanned} Elixir file(s) but an independent `find` over "
              f"{corpus} counts {int(expected_ex)}.\n\n"
              "  Two walkers over one tree must agree. A gap means the scan\n"
              "  skipped files it was supposed to read, so a clean verdict\n"
              "  would be over files nobody looked at.")
        sys.exit(1)

if not failures:
    print(f"nil-polarity-check: PASS — {scanned} Elixir file(s) scanned "
          f"(floor {corpus_floor}, independent count {expected_ex or 'n/a'}), "
          f"no fail-OPEN nil/catch-all visibility clauses.")
    sys.exit(0)

print("nil-polarity-check: FAILED — a fail-OPEN nil/caller-less visibility clause reappeared.\n")
for rel, ln, text, msg in sorted(failures):
    print(f"  {rel}:{ln}:  {text}")
    print(f"      → {msg}")
print("\n  A nil/caller-less principal is the MOST RESTRICTIVE anonymous one, never a")
print("  full-content bypass. Flip the clause to fail closed (`do: false`), or route")
print("  the trusted internal path through the explicit `:internal` sentinel. See")
print("  Barkpark.Content.Envelope field-visibility docs + the ctx-compression charter.")
sys.exit(1)
PY
