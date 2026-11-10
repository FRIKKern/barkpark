#!/usr/bin/env python3
"""unused-export-check.py — a change may not add a public function nothing uses.

RULE (task-00460cb8804b1b94). For every public function this change ADDS

  * Elixir `def name` in api/lib or cloud/lib, and
  * Go top-level `func Name(` in internal/ or cmd/,

the name must be used somewhere in the tracked tree. A use is any line that
holds the name as a whole word, except: the function's own `def`/`func` head,
its `@spec`, and comment lines. If there is none, this reds.

A TEST COUNTS AS A USE, and that is a measured choice. With tests not counted,
1 of the last 19 merged changes on main (2026-11-10) would have gone red: a
pure module landed with its tests one change before its caller. So this
catches a function nothing touches at all, not one that only tests touch.

It reads the change, not the whole tree: `--base REV` names what the change is
measured against (CI: HEAD^1, the base of the pull request's merge commit).
Functions already on the base are never judged, so there is no baseline of
old findings. It is a text check: one `git diff`, then a `git grep` per added
name. No compile.

NOT JUDGED, on purpose, to keep false reds low
  * Elixir functions under `@impl` (callbacks are called by the framework).
  * Names like `__x__` and names holding `for_test` (test hooks).
  * Go methods, private functions, macros, TypeScript and JavaScript.
  * A name that is used only by a caller with the same name elsewhere still
    counts as used: this is a word match, not a call graph.

A function meant to be called from outside the repo (an operator console, a
later pull request) gets a row in scripts/.unused-export-allow:

  <path> <name> :: <reason>

USAGE
  python3 scripts/unused-export-check.py --base REV
  python3 scripts/unused-export-check.py --selftest

EXIT CODES  0 clean · 1 an added function is unused · 2 cannot measure (not a pass)
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ALLOW = "scripts/.unused-export-allow"
EX_DIRS = ("api/lib/", "cloud/lib/")
GO_DIRS = ("internal/", "cmd/")
TEST_DIRS = {"test", "tests", "__tests__", "testdata", "e2e", "fixtures"}
TEST_NAME = re.compile(r"(_test|\.test|\.spec)\.[A-Za-z0-9]+$")
EX_DEF = re.compile(r"^\s*def\s+([a-z_][A-Za-z0-9_]*)[?!]?")
GO_DEF = re.compile(r"^func\s+([A-Z][A-Za-z0-9_]*)\s*[(\[]")
COMMENT = re.compile(r"^\s*(#|//)")


class Refusal(Exception):
    """The check could not measure. Exit 2, never a pass."""


def is_test(path):
    parts = path.split("/")
    return bool(TEST_DIRS.intersection(parts[:-1])) or bool(TEST_NAME.search(parts[-1]))


def git(root, *args, ok=(0,)):
    p = subprocess.run(["git", "-C", root, *args], capture_output=True)
    if p.returncode not in ok:
        raise Refusal("git %s: %s" % (" ".join(args[:3]), p.stderr.decode().strip()))
    return p.stdout.decode("utf-8", "replace")


def def_re(path):
    if path.endswith(".ex") and path.startswith(EX_DIRS):
        return EX_DEF
    if path.endswith(".go") and path.startswith(GO_DIRS):
        return GO_DEF
    return None


def skipped_name(name):
    return (name.startswith("__") and name.endswith("__")) or "for_test" in name


def under_impl(lines, i):
    """True when the def head at lines[i] sits under an `@impl` attribute."""
    for prev in reversed(lines[max(0, i - 40):i]):
        s = prev.strip()
        if s.startswith("@impl"):
            return True
        if s == "end" or s.startswith(("def ", "defp ", "defmacro ")):
            return False
    return False


def added_functions(root, base):
    """-> {(path, name)} for public functions on lines this change adds."""
    diff = git(root, "diff", "-U0", "-M", "--no-color", base, "--", "*.ex", "*.go")
    found, path, rx = set(), None, None
    for line in diff.split("\n"):
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            rx = def_re(path) if path and not is_test(path) else None
        elif rx and line.startswith("+") and not line.startswith("+++"):
            m = rx.match(line[1:])
            if m and not skipped_name(m.group(1)):
                found.add((path, m.group(1)))
    out = set()
    for path, name in found:
        if base_has(root, base, path, name):
            continue  # a moved or edited clause of a function the base already had
        if path.endswith(".ex"):
            try:
                with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
                    lines = f.read().split("\n")
            except FileNotFoundError:
                continue
            heads = [i for i, l in enumerate(lines) if (EX_DEF.match(l) or [None, None])[1] == name]
            if heads and any(under_impl(lines, i) for i in heads):
                continue
        out.add((path, name))
    return out


def base_has(root, base, path, name):
    p = subprocess.run(["git", "-C", root, "cat-file", "blob", "%s:%s" % (base, path)],
                       capture_output=True)
    if p.returncode != 0:
        return False
    rx = def_re(path)
    for line in p.stdout.decode("utf-8", "replace").split("\n"):
        m = rx.match(line)
        if m and m.group(1) == name:
            return True
    return False


def read_allow(root):
    try:
        with open(os.path.join(root, ALLOW), encoding="utf-8") as f:
            rows = f.read().splitlines()
    except FileNotFoundError:
        raise Refusal("allow list not found at %s" % ALLOW)
    allow = set()
    for i, row in enumerate(rows, 1):
        row = row.strip()
        if not row or row.startswith("#"):
            continue
        head, sep, reason = row.partition(" :: ")
        parts = head.split()
        if not sep or len(parts) != 2 or not reason.strip():
            raise Refusal("%s:%d: want `<path> <name> :: <reason>`" % (ALLOW, i))
        allow.add((parts[0], parts[1]))
    return allow


SAME_LANG = {".ex": ["*.ex", "*.exs", "*.heex", "*.eex"], ".go": ["*.go"]}


def has_use(root, name, owners, pathspec):
    """True when a line under PATHSPEC uses NAME (see the module doc for what a use is)."""
    out = git(root, "grep", "-n", "-I", "-w", "-F", "--no-color", "-e", name, "--", *pathspec, ok=(0, 1))
    for line in out.split("\n"):
        path, _, rest = line.partition(":")
        _, _, text = rest.partition(":")
        if not text or COMMENT.match(text):
            continue
        if path in owners:
            m = def_re(path).match(text)
            if (m and m.group(1) == name) or text.strip().startswith("@spec " + name):
                continue
        return True
    return False


def used_names(root, cands):
    """-> the set of names from CANDS that have at least one use.

    One single-name  per name: first over files of the same language
    (fast, and where nearly every use is), then over the whole tree only for a
    name still unused. Many  patterns in one whole-tree grep took minutes.
    """
    owners = {}
    for path, name in cands:
        owners.setdefault(name, set()).add(path)
    used = set()
    for name, paths in owners.items():
        exts = {os.path.splitext(p)[1] for p in paths}
        near = [g for e in sorted(exts) for g in SAME_LANG[e]]
        if has_use(root, name, paths, near) or has_use(root, name, paths, ["."]):
            used.add(name)
    return used


def check(root, base, out=sys.stdout):
    git(root, "rev-parse", "--verify", "--quiet", base + "^{commit}")
    allow = read_allow(root)
    cands = added_functions(root, base)
    used = used_names(root, cands)
    bad = sorted((p, n) for p, n in cands if n not in used and (p, n) not in allow)
    if bad:
        print("FAIL: %d added public function(s) that nothing uses." % len(bad), file=out)
        for path, name in bad:
            print("  %s  %s" % (path, name), file=out)
        print("No line in the tree holds the name, apart from its own definition.\n"
              "Fix: call it, make it private, or delete it. If it is called from outside\n"
              "the repo, add `<path> <name> :: <reason>` to %s." % ALLOW, file=out)
        return 1
    print("ok: %d added public function(s), all used (%d allow rows)" % (len(cands), len(allow)), file=out)
    return 0


# ---------------------------------------------------------------- selftest ---
def selftest():
    import io
    fails = []

    def write(d, files):
        for rel, text in files.items():
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)

    def commit(d):
        git(d, "add", "-A")
        git(d, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", "c")

    def run(d, base="HEAD"):
        git(d, "add", "-A")
        buf = io.StringIO()
        try:
            return check(d, base, buf), buf.getvalue()
        except Refusal as e:
            return 2, str(e)

    def arm(name, got, want_rc, want_text=""):
        rc, text = got
        ok = rc == want_rc and want_text in text
        print("%s  %s" % ("PASS" if ok else "FAIL", name))
        if not ok:
            fails.append(name)
            print("      wanted rc=%d containing %r, got rc=%d:\n%s" % (want_rc, want_text, rc, text))

    mod = "defmodule A do\n  def old_dead(x), do: x\n%send\n"
    d = tempfile.mkdtemp(prefix="uec-selftest-")
    git(d, "init", "-q")
    write(d, {ALLOW: "# none\n", "api/lib/a.ex": mod % "", "api/lib/b.ex": "defmodule B do\nend\n"})
    commit(d)
    arm("no added functions is green", run(d), 0, "ok: 0 added")
    arm("old unused functions on the base are not judged", run(d), 0, "ok:")

    write(d, {"api/lib/a.ex": mod % "  @spec lonely(term) :: term\n  def lonely(x), do: x\n"})
    arm("added unused function fails", run(d), 1, "api/lib/a.ex  lonely")

    write(d, {"api/test/a_test.exs": "A.lonely(1)\n"})
    arm("a use in a test counts", run(d), 0, "ok: 1 added")
    os.remove(os.path.join(d, "api/test/a_test.exs"))
    write(d, {"api/lib/b.ex": "defmodule B do\n  # A.lonely(1) one day\nend\n"})
    arm("a use only in a comment does not count", run(d), 1, "lonely")

    write(d, {"api/lib/b.ex": "defmodule B do\n  def go, do: A.lonely(1)\n  def run, do: go()\nend\n"})
    arm("a caller in another file clears it", run(d), 1, "api/lib/b.ex  run")
    arm("the cleared name is not reported", (1 if "lonely" in run(d)[1] else 0, ""), 0)
    write(d, {"api/lib/b.ex": "defmodule B do\n  def go, do: A.lonely(1)\nend\n",
              "docs/runbook.md": "run `B.go()` in the console\n"})
    arm("a use in a doc counts", run(d), 0, "ok: 2 added")

    write(d, {"api/lib/b.ex": "defmodule B do\n  def go?, do: true\n  def fix_for_test, do: 1\n"
                              "  def __hook__, do: 1\n  defp priv, do: 1\nend\n",
              "docs/runbook.md": "x\n", "api/lib/a.ex": mod % ""})
    arm("a name with ? is matched whole", run(d), 1, "api/lib/b.ex  go")
    arm("test hooks and private functions are not judged",
        (1 if re.search(r"b\.ex  (fix_for_test|__hook__|priv)", run(d)[1]) else 0, ""), 0)

    write(d, {"api/lib/b.ex": "defmodule B do\n  @impl true\n  def handle_rare_thing(s), do: s\nend\n"})
    arm("an @impl callback is not judged", run(d), 0, "ok: 0 added")

    write(d, {"api/lib/b.ex": "defmodule B do\n  def console_only, do: 1\nend\n",
              ALLOW: "api/lib/b.ex console_only :: run by hand from the release console\n"})
    arm("an allow row with a reason clears it", run(d), 0, "1 allow rows")
    write(d, {ALLOW: "api/lib/b.ex console_only\n"})
    arm("an allow row with no reason refuses", run(d), 2, "<path> <name> :: <reason>")
    write(d, {ALLOW: ""})

    write(d, {"api/lib/b.ex": "defmodule B do\nend\n", "lib/elsewhere.ex": "defmodule C do\n  def nobody, do: 1\nend\n",
              "internal/x/x.go": "package x\n\nfunc Orphan() int { return 1 }\n\nfunc helper() int { return 2 }\n"
                                 "\nfunc (t T) Method() {}\n"})
    arm("added unused Go function fails", run(d), 1, "internal/x/x.go  Orphan")
    arm("Go methods, private funcs and other dirs are not judged",
        (1 if re.search(r"  (helper|Method|nobody)\b", run(d)[1]) else 0, ""), 0)
    write(d, {"internal/y/y.go": "package y\n\nvar _ = x.Orphan()\n"})
    arm("a Go caller clears it", run(d), 0, "ok: 1 added")

    commit(d)
    write(d, {"api/lib/a.ex": "defmodule A do\n  def old_dead(x), do: x\n  def old_dead(x, y), do: {x, y}\nend\n"})
    arm("a new clause of a function the base had is not judged", run(d), 0, "ok: 0 added")
    arm("an unknown base refuses", run(d, "no-such-rev"), 2, "rev-parse")
    os.remove(os.path.join(d, ALLOW))
    arm("a missing allow list refuses", run(d), 2, "allow list not found")

    print("selftest: %d arm(s) failed" % len(fails) if fails else "selftest: all arms passed")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="rev this change is measured against (CI: HEAD^1)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    try:
        if not a.base:
            raise Refusal("--base REV is required: this check reads a change")
        root = git(".", "rev-parse", "--show-toplevel").strip()
        return check(root, a.base)
    except Refusal as e:
        print("REFUSE: %s\n        (exit 2 = cannot measure, NOT a pass.)" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
