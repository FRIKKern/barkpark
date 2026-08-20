#!/usr/bin/env python3
"""Did this commit SHIP code, or is it a charter / wave-log / docs-only PR?

A done-audit over merged `Task:` trailers has to tell a real fix from a PR that
only wrote a charter or a ledger row. This module answers that for a list of
SHAs.

THE FAILURE DIRECTION IS THE DESIGN, NOT AN ACCIDENT — READ THIS BEFORE TUNING.
An unknown or newly-invented path with no code extension reads DOC, so the task
stays open and a human looks at it. That is deliberate: for a done-audit a false
"still open" costs one human glance, while a false "done" closes work that was
never shipped. Do NOT "improve precision" by making unknown paths read SHIP —
that inverts the asymmetry this module exists to provide. If you need the other
direction, write a different function and name it for what it does.

WHY NOT CLASSIFY BY DIRECTORY PREFIX. Measured over 400 commits on origin/main,
a two-directory inert-prefix rule disagreed with this one 6 times and was wrong
in all 6:

  * `.claude/workflows/` holds BOTH `*.workflow.js` (executable code — real
    bugfixes land there, e.g. f324eb3ae) and `*-charter.md` (documents). A
    prefix conflates them and calls a shipped fix doc-only.
  * An inert list naming two directories makes every doc OUTSIDE it read as
    SHIPPING — `docs/**`, `README.md`, `.gitignore`. That is the false-done
    shape, and it was 5 of the 6.

THE LEDGER IS THE ONE PLACE A CODE EXTENSION DOES NOT MEAN CODE.
`tooling/grip/ledger/**` is an evidence store: investigations park probe scripts
there as artifacts, never as build inputs. Commit 570046c12 carries four `.py`
probes there and ships no code at all. `ALWAYS_INERT` is what gets that right,
it is load-bearing, and `--selftest` mutation-proves it: with the rule disabled
the 570046c12 fixture MUST flip to SHIP. If you delete the rule as redundant,
that arm reds.

AN INSTRUMENT THAT CAN DISAGREE WITH ITSELF IS ONE YOU CAN CATCH.
`--selftest` deliberately keeps arms that overlap: `CASES` asserts the ledger
commit reads DOC, and the MUTATION ARM asserts that the same fixture reads SHIP
once `ALWAYS_INERT` is disabled. Neither alone proves much — together they
cannot both hold unless the rule is real AND the fixture still contains code
extensions. Redundant arms are not waste here; they are how a guard that has
quietly gone vacuous announces itself instead of passing.

That is not a theory. Two measurement passes over the task board were WRONG
before one was right, and the second was exposed by exactly this: a shape
classifier reported zero EMPTY rows while empty rows printed in its own output.
A single-armed instrument would have reported a confident, wrong number.

USAGE
    git log --format=%H origin/main -50 | python3 tooling/ships/ships.py
    python3 tooling/ships/ships.py --selftest

SHAs arrive on stdin, one per line. All of them are resolved in ONE `git log`
process — a per-SHA `git show` costs one process each, which is what made this
too slow to run over a whole backlog.
"""

import os
import subprocess
import sys

# Extensions that mean "this is code or config the build/test gates act on".
CODE_EXTENSIONS = frozenset({
    ".go", ".ex", ".exs", ".heex", ".eex",
    ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx",
    ".sh", ".bash", ".zsh",
    ".yml", ".yaml", ".toml",
    ".css", ".scss", ".html",
    ".sql", ".py", ".rb",
    ".mod", ".sum", ".lock",
})

# Trees that are evidence stores, inert WHATEVER the file extension. See the
# module doc: probe scripts live here as artifacts, never as build inputs.
ALWAYS_INERT = ("tooling/grip/ledger/", ".barkpark/")

# `.json` is usually a real input (fixtures, manifests, lockfiles) but is a
# wave artifact under the workflows tree.
INERT_JSON_PREFIX = ".claude/workflows/"


def is_code(path, apply_always_inert=True):
    """True when `path` is a build input rather than a document or artifact.

    `apply_always_inert` exists so `--selftest` can disable the ledger rule and
    prove it changes a real verdict. Production callers leave it True.
    """
    if apply_always_inert and path.startswith(ALWAYS_INERT):
        return False
    ext = os.path.splitext(path)[1]
    if ext == ".json":
        return not path.startswith(INERT_JSON_PREFIX)
    return ext in CODE_EXTENSIONS


def classify(paths, apply_always_inert=True):
    """("SHIP"|"DOC", [code paths]) for one commit's file list."""
    code = [p for p in paths if is_code(p, apply_always_inert)]
    return ("SHIP" if code else "DOC"), code


def resolve(sha, keys):
    """Map an input SHA onto the full SHA `git log` reported.

    Inputs are routinely ABBREVIATED (a trailer or a PR body carries 9 chars)
    while `git log --format=%H` always prints 40. A plain dict lookup misses
    every abbreviated input and yields an empty file list, which classifies as
    DOC — silently, for everything. That is a live-wiring bug a hermetic
    fixture cannot see, so it is resolved here and unit-checked below.
    """
    if sha in keys:
        return sha
    hits = [k for k in keys if k.startswith(sha)]
    return hits[0] if len(hits) == 1 else None


def files_by_sha(shas, repo=None):
    """{sha: [paths]} for every sha, in ONE git process."""
    if not shas:
        return {}
    cmd = ["git"]
    if repo:
        cmd += ["-C", repo]
    cmd += ["log", "--no-walk=unsorted", "--format=C %H", "--name-only"] + list(shas)
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout

    result, current = {}, None
    for line in out.splitlines():
        if line.startswith("C "):
            current = line[2:].strip()
            result[current] = []
        elif line.strip() and current:
            result[current].append(line.strip())
    return result


# ---------------------------------------------------------------------------
# SELFTEST
#
# Fixtures are HERMETIC — real file lists captured from real commits, pinned
# here as data. They deliberately do NOT shell out to git: a shallow CI clone
# would not have these SHAs, and a selftest that silently finds nothing to
# check is worse than no selftest.
# ---------------------------------------------------------------------------

# 570046c12 — a ci-gate-script-integrity investigation. It carries FOUR .py
# probe scripts, and ships no code whatever. This is the fixture that pins
# ALWAYS_INERT; an extension-only rule calls it SHIP.
LEDGER_COMMIT_570046C12 = [
    ".claude/workflows/ci-gate-script-integrity-charter.md",
    "tooling/grip/ledger/blocking-shaped-classifier-v1-2026-08-19.py.txt",
    "tooling/grip/ledger/blocking-shaped-definition-v1-2026-08-19.md",
    "tooling/grip/ledger/cgsi-file-header-prose-rule-2026-08-19.py",
    "tooling/grip/ledger/cgsi-name-anchored-window-2026-08-19.py",
    "tooling/grip/ledger/cgsi-structural-evidence-scan-2026-08-19.py",
    "tooling/grip/ledger/cgsi-subject-set-derive-2026-08-19.py",
    "tooling/grip/ledger/cgsi-unswept-out-of-fence-harnesses-2026-08-19.md",
    "tooling/grip/ledger/cgsi-v1-crown-subject-set-adjudication-2026-08-19.md",
    "tooling/grip/ledger/v1-root-md-glob-semantics-2026-08-19.md",
]

# f324eb3ae — a one-file fix to the epic-cycle workflow SCRIPT. Code, living
# under a directory a prefix rule treats as documents.
WORKFLOW_FIX_F324EB3AE = [".claude/workflows/bp-epic-cycle.workflow.js"]

CASES = [
    ("570046c12 ledger probes",  LEDGER_COMMIT_570046C12,      "DOC"),
    ("f324eb3ae workflow.js fix", WORKFLOW_FIX_F324EB3AE,      "SHIP"),
    ("charter only",             [".claude/workflows/bp-security-remainder-charter.md"], "DOC"),
    ("docs only",                ["docs/PHILOSOPHY.md", "README.md"], "DOC"),
    ("census + go",              ["cloud/test/barkpark_cloud/payload_key_set_census_test.exs",
                                  "internal/cloudclient/client.go"], "SHIP"),
    ("workflow wave artifact",   [".claude/workflows/felix-audit-wave-paper.json"], "DOC"),
    ("real json fixture",        ["api/test/support/fixtures/onix.json"], "SHIP"),
]


def selftest():
    failures = []

    for name, paths, want in CASES:
        got, _ = classify(paths)
        if got != want:
            failures.append(f"{name}: want {want}, got {got}")

    # MUTATION ARM. ALWAYS_INERT must be load-bearing: with it disabled, the
    # ledger commit's four .py probes make it read SHIP. If this arm does NOT
    # flip, the rule is dead weight OR the fixture stopped containing code
    # extensions — either way the guard above is no longer proving anything.
    mutated, code = classify(LEDGER_COMMIT_570046C12, apply_always_inert=False)
    if mutated != "SHIP":
        failures.append(
            "MUTATION ARM DID NOT FIRE: disabling ALWAYS_INERT left 570046c12 "
            f"reading {mutated}. The rule is no longer load-bearing, or the "
            "fixture lost its .py probes — do not delete the rule on the "
            "strength of this passing."
        )
    elif not any(p.endswith(".py") for p in code):
        failures.append("MUTATION ARM fired for the wrong reason: no .py probe in the flipped set")

    # WIRING ARM. `resolve` is the seam a hermetic fixture cannot reach with
    # real git, so its logic is checked directly: abbreviated in, full out;
    # ambiguous and unknown prefixes refuse rather than guess.
    full = "570046c1234567890abcdef01234567890abcdef"
    other = "570046c9999999999999999999999999999999ff"
    if resolve("570046c12", [full]) != full:
        failures.append("resolve() failed to match an abbreviated sha")
    if resolve(full, [full]) != full:
        failures.append("resolve() failed to match an exact sha")
    if resolve("570046c", [full, other]) is not None:
        failures.append("resolve() guessed on an AMBIGUOUS prefix instead of refusing")
    if resolve("deadbeef", [full]) is not None:
        failures.append("resolve() invented a match for an unknown sha")

    # DIRECTION ARM. An unfamiliar extension must read DOC, never SHIP — the
    # asymmetry the module doc commits to.
    got, _ = classify(["some/new/tree/thing.qqq"])
    if got != "DOC":
        failures.append(f"unknown extension read {got}; the safe direction is DOC")

    for f in failures:
        print(f"FAIL  {f}")
    total = len(CASES) + 6
    print(f"{total - len(failures)}/{total} checks passed")
    return 1 if failures else 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    shas = [l.strip() for l in sys.stdin if l.strip()]
    by_sha = files_by_sha(shas)
    keys = list(by_sha)
    exit_code = 0
    for sha in shas:
        full = resolve(sha, keys)
        if full is None:
            # Never classify a commit we failed to resolve — an unresolved SHA
            # that prints DOC is indistinguishable from a real doc-only commit.
            print(f"{sha[:9]} ????    -    UNRESOLVED — not classified")
            exit_code = 1
            continue
        paths = by_sha[full]
        verdict, code = classify(paths)
        first = code[0] if code else (paths[0] if paths else "(no files)")
        print(f"{sha[:9]} {verdict:4s} {len(code)}/{len(paths)} {first}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
