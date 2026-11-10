#!/usr/bin/env python3
"""file-size-ratchet.py — giant source files may not grow, new ones stay small.

RULE (task-00460cb8804b1b94). A product source file over 2,000 lines is listed
in scripts/.file-size-baseline with its line count. This check reds when

  * a listed file holds MORE lines than its baseline number, or
  * a file that is not listed crosses 2,000 lines.

Shrinking never reds; the check prints the lower number to write into the
baseline. Put new code in a new file instead of a giant one.

NEW FILES (needs --base). A product source file ADDED by this change may hold
at most 500 lines. Files that already exist are not judged by this rule, and a
rename is not an add. Without --base the rule is skipped and the output says so.

WHAT COUNTS AS A PRODUCT SOURCE FILE. A git-tracked file with one of the
extensions in SOURCE_EXT that is not a test (see is_test) and is not named on
an `exempt` row of the baseline. Exempt rows are for generated, vendored or
mirrored files only, one exact path each, each with a reason.

BLAME, with --base REV. CI passes `--base HEAD^1` (on a pull request the
checkout is the merge commit, so HEAD^1 is the base). A file that is over its
number but holds no more lines than it did at REV was not grown by this
change: it is printed as INHERITED and does not red. This keeps one stale
baseline row from redding every open pull request. Without --base the baseline
is absolute.

It reads files only: no compile, no network. About a second on this tree.

USAGE
  python3 scripts/file-size-ratchet.py [--base REV]   # enforce
  python3 scripts/file-size-ratchet.py --selftest     # prove it can fail
  python3 scripts/file-size-ratchet.py --print-baseline   # measured rows

EXIT CODES  0 clean · 1 a file grew or a new file is too long · 2 cannot measure (not a pass)
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

GIANT = 2000
NEW_CAP = 500
BASELINE = "scripts/.file-size-baseline"
SOURCE_EXT = {
    ".ex", ".exs", ".heex", ".go", ".ts", ".tsx", ".js", ".jsx", ".mjs",
    ".cjs", ".py", ".sh", ".css",
}
TEST_DIRS = {"test", "tests", "__tests__", "testdata", "e2e", "fixtures"}
TEST_NAME = re.compile(r"(_test|\.test|\.spec)\.[A-Za-z0-9]+$")


class Refusal(Exception):
    """The check could not measure. Exit 2, never a pass."""


def is_test(path):
    parts = path.split("/")
    return bool(TEST_DIRS.intersection(parts[:-1])) or bool(TEST_NAME.search(parts[-1]))


def is_source(path):
    return os.path.splitext(path)[1] in SOURCE_EXT and not is_test(path)


def count_lines(data):
    n = data.count(b"\n")
    return n + 1 if data and not data.endswith(b"\n") else n


def git(root, *args):
    p = subprocess.run(["git", "-C", root, *args], capture_output=True)
    if p.returncode != 0:
        raise Refusal("git %s: %s" % (" ".join(args), p.stderr.decode().strip()))
    return p.stdout


def tracked_sources(root):
    out = git(root, "ls-files", "-z").decode("utf-8", "surrogateescape")
    return [p for p in out.split("\0") if p and is_source(p)]


def lines_now(root, path):
    try:
        with open(os.path.join(root, path), "rb") as f:
            return count_lines(f.read())
    except (FileNotFoundError, IsADirectoryError):
        return None  # tracked but deleted in the working tree, or a submodule


def lines_at(root, rev, path):
    p = subprocess.run(
        ["git", "-C", root, "cat-file", "blob", "%s:%s" % (rev, path)],
        capture_output=True,
    )
    return count_lines(p.stdout) if p.returncode == 0 else None


def added_sources(root, base):
    """-> product source paths this change adds (in the tree, not at BASE)."""
    out = git(root, "diff", "--name-only", "-z", "-M", "--diff-filter=A", base)
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p and is_source(p)]


def read_baseline(root, rel=BASELINE):
    """-> ({path: count}, {path: reason}). Raises Refusal on any unreadable row."""
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            rows = f.read().splitlines()
    except FileNotFoundError:
        raise Refusal("baseline not found at %s" % rel)
    counts, exempt = {}, {}
    for i, row in enumerate(rows, 1):
        row = row.strip()
        if not row or row.startswith("#"):
            continue
        if row.startswith("exempt "):
            path, sep, reason = row[len("exempt "):].partition(" :: ")
            if not sep or not path.strip() or not reason.strip():
                raise Refusal("%s:%d: want `exempt <path> :: <reason>`" % (rel, i))
            exempt[path.strip()] = reason.strip()
            continue
        num, _, path = row.partition(" ")
        if not num.isdigit() or not path.strip():
            raise Refusal("%s:%d: want `<lines> <path>`" % (rel, i))
        counts[path.strip()] = int(num)
    return counts, exempt


def measure(root, exempt=()):
    """-> {path: lines} for every product source file over GIANT lines."""
    out = {}
    for path in tracked_sources(root):
        if path in exempt:
            continue
        n = lines_now(root, path)
        if n is not None and n > GIANT:
            out[path] = n
    return out


def check(root, base=None, out=sys.stdout):
    counts, exempt = read_baseline(root)
    if base is not None:
        git(root, "rev-parse", "--verify", "--quiet", base + "^{commit}")
    giants = measure(root, exempt)
    bad, notes = [], []
    for path in sorted(giants):
        n, want = giants[path], counts.get(path)
        limit = GIANT if want is None else want
        if n > limit:
            if base is not None:
                was = lines_at(root, base, path)
                if was is not None and was >= n:
                    notes.append("INHERITED %s holds %d (limit %d), %d at %s: not grown by this change"
                                 % (path, n, limit, was, base))
                    continue
            if want is None:
                bad.append("%s holds %d lines and is not in the baseline: a file may not cross %d lines"
                           % (path, n, GIANT))
            else:
                bad.append("%s grew to %d lines, baseline %d (+%d)" % (path, n, want, n - want))
        elif n < limit:
            notes.append("SHRANK %s holds %d, baseline %d: lower its row to %d" % (path, n, want, n))
    for path in sorted(set(counts) - set(giants)):
        notes.append("STALE %s is no longer over %d lines (or is gone): delete its row" % (path, GIANT))
    long_new = []
    if base is None:
        notes.append("new-file cap (%d lines) NOT checked: it needs --base" % NEW_CAP)
    else:
        for path in sorted(added_sources(root, base)):
            n = lines_now(root, path)
            if path not in exempt and n is not None and n > NEW_CAP:
                long_new.append("%s is new and holds %d lines (cap %d)" % (path, n, NEW_CAP))
    for n in notes:
        print("note: " + n, file=out)
    if bad:
        print("FAIL: %d giant file(s) grew. Files over %d lines may not grow." % (len(bad), GIANT), file=out)
        for b in bad:
            print("  " + b, file=out)
        print("Fix: move the new code to a new file. If a file was renamed, rename its row in\n"
              "%s. Raising a number there needs a reason in the pull request." % BASELINE, file=out)
    if long_new:
        print("FAIL: %d new source file(s) over %d lines." % (len(long_new), NEW_CAP), file=out)
        for b in long_new:
            print("  " + b, file=out)
        print("Fix: split the file. A generated or vendored file gets an `exempt` row with a\n"
              "reason in %s." % BASELINE, file=out)
    if bad or long_new:
        return 1
    print("ok: %d files over %d lines, none grew (%d exempt rows)" % (len(giants), GIANT, len(exempt)), file=out)
    return 0


# ---------------------------------------------------------------- selftest ---
def selftest():
    import io
    fails = []

    def body(n):
        return "x\n" * n

    def repo(files, baseline):
        d = tempfile.mkdtemp(prefix="fsr-selftest-")
        git(d, "init", "-q")
        files = dict(files)
        files[BASELINE] = baseline
        write(d, files)
        commit(d)
        return d

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

    def run(d, base=None):
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

    d = repo({"lib/big.ex": body(2500), "lib/small.ex": body(10)}, "2500 lib/big.ex\n")
    arm("clean tree is green", run(d), 0, "ok: 1 files")

    write(d, {"lib/big.ex": body(2501)})
    arm("grown giant file fails", run(d), 1, "lib/big.ex grew to 2501 lines, baseline 2500")
    arm("grown giant file fails against its base too", run(d, "HEAD"), 1, "lib/big.ex grew")

    commit(d)
    arm("growth already on the base is inherited, not blamed", run(d, "HEAD"), 0, "INHERITED lib/big.ex")
    arm("without a base the same growth still fails", run(d), 1, "lib/big.ex grew")

    write(d, {"lib/big.ex": body(2400)})
    arm("shrinking is green and names the lower number", run(d), 0, "lower its row to 2400")

    write(d, {"lib/big.ex": body(2500), "lib/small.ex": body(2001)})
    arm("new file crossing 2000 fails", run(d, "HEAD"), 1, "lib/small.ex holds 2001 lines and is not in the baseline")

    write(d, {"lib/small.ex": body(2000)})
    arm("exactly 2000 lines is not a giant", run(d), 0, "ok:")

    write(d, {"test/big_test.exs": body(9000), "docs/big.md": body(9000)})
    git(d, "add", "-A")
    arm("tests and non-source files are not measured", run(d), 0, "ok: 1 files")

    write(d, {"priv/vendor.js": body(5000)})
    git(d, "add", "-A")
    arm("an unlisted vendored giant fails until exempted", run(d), 1, "priv/vendor.js")
    write(d, {BASELINE: "2500 lib/big.ex\nexempt priv/vendor.js :: vendored upstream build\n"})
    arm("an exempt row with a reason clears it", run(d), 0, "1 exempt rows")
    write(d, {BASELINE: "2500 lib/big.ex\nexempt priv/vendor.js\n"})
    arm("an exempt row with no reason refuses", run(d), 2, "exempt <path> :: <reason>")

    n = repo({"lib/old.ex": body(900)}, "")
    write(n, {"lib/new.ex": body(501), "lib/fine.ex": body(500), "test/new_test.exs": body(900),
              "lib/old.ex": body(950)})
    git(n, "add", "-A")
    arm("new file over 500 lines fails", run(n, "HEAD"), 1, "lib/new.ex is new and holds 501 lines (cap 500)")
    arm("the new-file cap names only the new long file", (0 if "fine.ex" not in run(n, "HEAD")[1]
        and "old.ex" not in run(n, "HEAD")[1] and "new_test" not in run(n, "HEAD")[1] else 1, ""), 0)
    arm("without a base the new-file cap is skipped and says so", run(n), 0, "NOT checked: it needs --base")
    write(n, {BASELINE: "exempt lib/new.ex :: generated by a tool\n"})
    arm("an exempt new file is not capped", run(n, "HEAD"), 0, "ok:")
    write(n, {BASELINE: ""})
    commit(n)
    arm("a long file already on the base is not judged", run(n, "HEAD"), 0, "ok:")
    git(n, "mv", "lib/new.ex", "lib/moved.ex")
    arm("a rename is not an add", run(n, "HEAD"), 0, "ok:")

    write(d, {BASELINE: "2500 lib/big.ex\n9999 lib/gone.ex\nexempt priv/vendor.js :: vendored\n"})
    arm("a stale row is a note, not a red", run(d), 0, "STALE lib/gone.ex")
    write(d, {BASELINE: "lots lib/big.ex\n"})
    arm("an unreadable row refuses", run(d), 2, "want `<lines> <path>`")
    os.remove(os.path.join(d, BASELINE))
    arm("a missing baseline refuses", run(d), 2, "baseline not found")
    write(d, {BASELINE: "2500 lib/big.ex\nexempt priv/vendor.js :: vendored\n"})
    arm("an unknown base refuses", run(d, "no-such-rev"), 2, "rev-parse")

    print("selftest: %d arm(s) failed" % len(fails) if fails else "selftest: all arms passed")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="rev this change is measured against (CI: HEAD^1)")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--print-baseline", action="store_true",
                    help="print `<lines> <path>` for every giant file as measured now")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    try:
        root = git(".", "rev-parse", "--show-toplevel").decode().strip()
        if a.print_baseline:
            try:
                exempt = read_baseline(root)[1]
            except Refusal:
                exempt = {}
            giants = measure(root, exempt)
            for path in sorted(giants, key=lambda p: (-giants[p], p)):
                print("%d %s" % (giants[path], path))
            return 0
        return check(root, a.base)
    except Refusal as e:
        print("REFUSE: %s\n        (exit 2 = cannot measure, NOT a pass.)" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
