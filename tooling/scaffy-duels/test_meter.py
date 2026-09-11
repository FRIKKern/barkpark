#!/usr/bin/env python3
"""test_meter.py — the detector for meter.py's three remaining fail-opens (PDS wave 49).

Run: `python3 tooling/scaffy-duels/test_meter.py` (no dependencies, ~2s).

Each test MUTATES a disposable copy of the tree and asserts the exit code. That is
the whole point: every one of these three holes was a green banner over an arm that
did not run, and no amount of reading the source found them — only running a
mutation did. Each test here is RED against meter.py as it stood before 2026-09-11.

  MUT_E   add a 35th envelope, bump BOTH population markers, leave METER.md §3
          untouched -> used to be rc=0, because §3's dollars were hand-computed
          literals with no re-taker.
  C2      bump both population markers in a tree with no results/ -> used to be
          rc=0, UNDER a banner claiming "the population assertion fires".
  TWIN    delete tally_wf.py -> used to be rc=0 with "parity unasserted", making an
          in-repo deletion indistinguishable from a legitimate copy-away.

A control runs first: the unmutated copy must GREEN, or every red below is vacuous.
"""
import json
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def _tree(d, corpus=True, twin=True, git=True):
    """A disposable copy of the instrument and its data."""
    root = os.path.join(d, "scaffy-duels")
    os.makedirs(root)
    shutil.copy(os.path.join(HERE, "meter.py"), root)
    shutil.copy(os.path.join(HERE, "METER.md"), root)
    if twin:
        shutil.copy(os.path.join(HERE, "tally_wf.py"), root)
    if corpus:
        shutil.copytree(os.path.join(HERE, "results"), os.path.join(root, "results"))
    if git:
        os.makedirs(os.path.join(d, ".git"))
    return root


def _pop(root, n):
    """Bump BOTH published population figures — the marker and the §2 prose."""
    p = os.path.join(root, "METER.md")
    s = open(p).read()
    s = re.sub(r"(<!--\s*meter:population\s+)\d+(\s*-->)", rf"\g<1>{n}\g<2>", s)
    s = re.sub(r"on(\s+)\d+/\d+\*\*", rf"on\g<1>{n}/{n}**", s)
    open(p, "w").write(s)


def _run(root, *argv):
    r = subprocess.run(
        [sys.executable, os.path.join(root, "meter.py"), *argv],
        capture_output=True, text=True,
    )
    return r.returncode, r.stdout + r.stderr


def check(name, cond, detail):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: {detail}")
        FAILS.append(name)


def test_control_greens():
    """If the untouched copy does not pass, every mutation below proves nothing."""
    with tempfile.TemporaryDirectory() as d:
        root = _tree(d)
        rc_v, out_v = _run(root, "verify", os.path.join(root, "results"))
        rc_s, out_s = _run(root, "--self-test")
        check("control: verify greens on a faithful copy", rc_v == 0, f"rc={rc_v}\n{out_v}")
        check("control: --self-test greens on a faithful copy", rc_s == 0, f"rc={rc_s}\n{out_s}")
        check(
            "control: the §3 re-take actually ran",
            "§3 re-taken" in out_v,
            f"verify printed no §3 line:\n{out_v}",
        )


def test_shares_verb_exists_and_emits():
    with tempfile.TemporaryDirectory() as d:
        root = _tree(d)
        rc, out = _run(root, "shares")
        check("shares: the verb exists and exits 0", rc == 0, f"rc={rc}\n{out}")
        for want in ("corpus total", "median envelope cost", "by dollars", "cache writes"):
            check(f"shares: emits {want!r}", want in out, out)


def test_mut_e_grown_corpus_reds_section_3():
    """MUT_E: the dollars must move when the corpus does, markers or no markers."""
    with tempfile.TemporaryDirectory() as d:
        root = _tree(d)
        results = os.path.join(root, "results")
        seed = sorted(glob.glob(os.path.join(results, "*.agent.json")))[0]
        json.dump(json.load(open(seed)), open(os.path.join(results, "zz-mut-e.agent.json"), "w"))
        _pop(root, 35)  # the doc TOUCH the old marker forced — §3 left alone
        rc, out = _run(root, "verify", results)
        check(
            "MUT_E: a 35th envelope reds verify even with both markers bumped",
            rc != 0,
            f"rc={rc} — §3's dollars are still frozen literals\n{out}",
        )
        check(
            "MUT_E: the failure names §3, not only the population",
            "§3" in out,
            out,
        )


def test_corpus_absent_refuses_instead_of_claiming():
    """C2 in a corpus-less tree: used to green under a banner naming the arm."""
    with tempfile.TemporaryDirectory() as d:
        root = _tree(d, corpus=False)
        _pop(root, 33)  # C2: a population mutation only the corpus walk can catch
        rc, out = _run(root, "--self-test")
        check(
            "C2/corpus-absent: --self-test refuses in a checkout with no results/",
            rc != 0,
            f"rc={rc} — the corpus-absent fail-open is open\n{out}",
        )
        check(
            "C2/corpus-absent: the banner no longer claims the population assertion fired",
            "the population assertion fires" not in out,
            f"banner named an arm that did not run:\n{out}",
        )
        check(
            "C2/corpus-absent: 'self-test OK' is not printed",
            "self-test OK" not in out,
            out,
        )


def test_twin_absent_refuses_in_checkout():
    with tempfile.TemporaryDirectory() as d:
        root = _tree(d, twin=False)
        rc, out = _run(root, "--self-test")
        check(
            "TWIN: a deleted tally_wf.py reds inside a checkout",
            rc != 0,
            f"rc={rc} — in-repo deletion still indistinguishable from copy-away\n{out}",
        )
        check("TWIN: 'self-test OK' is not printed", "self-test OK" not in out, out)


def test_twin_absent_degrades_banner_outside_checkout():
    """Copy-away stays supported — but the banner must name the arm as NOT RUN."""
    with tempfile.TemporaryDirectory() as d:
        root = _tree(d, twin=False, git=False)
        rc, out = _run(root, "--self-test")
        check("TWIN/copy-away: still exits 0", rc == 0, f"rc={rc}\n{out}")
        check(
            "TWIN/copy-away: the banner says the mirror arm did NOT run",
            "did NOT run" in out,
            f"banner covers an arm that did not run:\n{out}",
        )
        check(
            "TWIN/copy-away: the banner does not claim the mirror is identical",
            "mirror identical" not in out,
            out,
        )


if __name__ == "__main__":
    for t in (
        test_control_greens,
        test_shares_verb_exists_and_emits,
        test_mut_e_grown_corpus_reds_section_3,
        test_corpus_absent_refuses_instead_of_claiming,
        test_twin_absent_refuses_in_checkout,
        test_twin_absent_degrades_banner_outside_checkout,
    ):
        print(f"{t.__name__}:")
        t()
    print()
    if FAILS:
        print(f"test_meter.py: {len(FAILS)} FAILED — {', '.join(FAILS)}", file=sys.stderr)
        sys.exit(1)
    print("test_meter.py: all checks passed")
