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

# --selftest — the DURABLE tripwire (distrust vacuous green). Proves the gate
# REDs on each planted fail-open shape and greens on the fail-closed forms,
# planting NOTHING in the real tree (a temp dir, cleaned on exit). It drives the
# REAL scanner via NIL_POLARITY_SELFTEST so a future edit that weakens the
# lexer/patterns is caught here, not just in prose.
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
    if ! printf '%s' "$out" | grep -q 'planted_field.ex:2'; then
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

    echo "nil-polarity-check --selftest: PASS — REDs on nil=>true clause, catch-all, and redacted_result nil seam; passes fail-closed forms + doctrine comments."
    exit 0
fi

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]

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

if not failures:
    print(f"nil-polarity-check: PASS — {scanned} Elixir file(s) scanned, "
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
