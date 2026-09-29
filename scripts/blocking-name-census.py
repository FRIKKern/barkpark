#!/usr/bin/env python3
"""blocking-name-census.py — every job name that CAN BLOCK A MERGE is named by
the spec, or this reds.

WHAT IT CLOSES. `.github/required-checks.json` is GENERATED from check-run
names that RENDERED on sampled heads, and its own `_readme` concedes
"EXCLUSIONS ARE WHAT THE SAMPLE SAW, never a complete census".
`required-checks-verify.sh`'s census clause inherits the same scope: a green
there means "nothing unaccounted rendered on THIS head". A job whose `if:`
skips it on the sampled heads never renders, so no sample-driven instrument can
see it. This one reads `.github/workflows/` STATICALLY, so a name does not have
to render to be counted.

THE DEFINITION — "blocking-shaped", as this guard uses the word:

    a job is BLOCKING when its rendered name IS a required context, or when it
    sits in the TRANSITIVE `needs:` closure of such a job, walked from the
    required aggregator INWARD along the aggregator's own `needs:` list.

  Why this and not a look-alike rule. A merge on this repo is refused by
  exactly four contexts (`.protection.required_status_checks.checks`). Each is
  an `if: always()` aggregator that decides over `needs.<job>.result`, so a red
  in any job it needs — directly or through a chain — reds a required context.
  Nothing outside that closure can stop a merge, whatever its name says.
  `(blocking)` in a title is prose; the closure is topology. The edge direction
  is load-bearing: `tier-floor-render` declares `needs: changes`, never
  `needs: console-gate` — it is console-gate that needs IT — so only an inward
  walk from the aggregator finds it.

  The closure is an OVER-approximation on purpose. An aggregator could read a
  need and ignore its result, and a `continue-on-error: true` need reports
  success upward; both are still counted. A false red here costs one
  `.exclusions` row; a false green hides a merge stopper nobody can enumerate,
  which is the defect this file exists to close.

  The walker is NOT re-implemented here: `workflow_graphs()` in
  scripts/ci-pr-inventory.py is the one needs walker, and the inventory's
  `feeds-required` column reads the same closure.

WHAT "ACCOUNTED" MEANS. A blocking job is accounted when some context in
required ∪ exclusions is a name that job can render:
  * a static name matches itself byte-for-byte;
  * a matrixed job whose name interpolates no matrix value also matches
    `<name> (<tuple>)`, because that is when GitHub appends the tuple — the
    same rule required-checks-generate.sh applies, read from the SOURCE;
  * a name carrying `${{ … }}` matches either its own uninterpolated template
    (what a skipped leg publishes) or any context the template can expand to;
  * a name that is NOTHING BUT interpolation matches only through a
    `# required-checks: matrix-name-legs <file> <jq-filter>` declaration, leg
    by leg — a `.+` pattern is a takeover, never a match.

THE W56 RECIPE, reproduced rather than retyped. Wave 56 published
`85 55 40 35` at b97663730 ("35 such names exist today"): 85 jobs in 44 files
→ 55 residue (not a required job, not in the closure, not accounted) → 40 in a
workflow triggered on pull_request → 35 with no `continue-on-error`. `--at
b97663730` prints exactly that line; `--at 085cc8719` prints `85 54 39 34`,
because the gofmt exclusion that commit added is the name that left. Those
residue names are the COMPLEMENT of this guard's population — by construction
none of them can block a merge — so the residue is REPORTED, never red here.

EXIT CODES (the house vocabulary, scripts/run-instrument.sh):
  0  measured, every blocking name accounted
  1  measured, at least one blocking name unaccounted (each printed by name)
  2  refused: zero workflow files, an unreadable spec, a required context no
     job produces (a closure walked from nothing is vacuous), a YAML parse
     error, or a legs declaration that cannot be read

Usage:
  scripts/blocking-name-census.py              # the working tree
  scripts/blocking-name-census.py --root DIR   # DIR/.github/{workflows,required-checks.json}
  scripts/blocking-name-census.py --at REV     # a committed tree (git archive)
  scripts/blocking-name-census.py --selftest   # offline mutation matrix
"""
import argparse, glob, importlib.util, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def _inventory():
    spec = importlib.util.spec_from_file_location(
        "ci_pr_inventory", os.path.join(HERE, "ci-pr-inventory.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


INV = _inventory()


class Refused(Exception):
    pass


EXPR = re.compile(r"\$\{\{.*?\}\}")
LEGS = re.compile(r"^[ \t]*#[ \t]*required-checks:[ \t]*matrix-name-legs[ \t]+(\S+)[ \t]+(.+?)[ \t]*$")


def legs_directive(path, job):
    """`<file> <filter>` declared inside the job's block, or None — the same
    scoping as required-checks-generate.sh's matrix_legs_directive."""
    cur, injobs = None, False
    with open(path) as fh:
        for line in fh:
            if line.startswith("jobs:"):
                injobs = True
                continue
            if injobs and re.match(r"^[a-z]", line):
                injobs = False
            if injobs and re.match(r"^  [A-Za-z0-9_.-]+:", line):
                cur = line.strip().split(":", 1)[0]
                continue
            if injobs and cur == job:
                m = LEGS.match(line.rstrip("\n"))
                if m:
                    return m.group(1), m.group(2)
    return None


def leg_names(root, legsfile, flt):
    p = os.path.join(root, legsfile)
    if not os.path.isfile(p):
        raise Refused(f"matrix-name-legs file {legsfile} does not exist")
    r = subprocess.run(["jq", "-r", flt, p], capture_output=True, text=True)
    names = [n for n in r.stdout.splitlines() if n.strip()]
    if r.returncode != 0 or not names:
        raise Refused(f"matrix-name-legs `{legsfile} {flt}` yielded nothing "
                      f"(jq exit {r.returncode})")
    return names


def accounting(root, path, jid, job, tmpl, census):
    """(accounted?, why) for one job against required ∪ exclusions."""
    strat = job.get("strategy")
    matrixed = isinstance(strat, dict) and bool(strat.get("matrix"))
    if "${{" not in tmpl:
        if tmpl in census:
            return True, "named"
        if matrixed:
            rx = re.compile(re.escape(tmpl) + r" \(.+\)")
            if any(rx.fullmatch(c) for c in census):
                return True, "named with its matrix tuple"
        return False, "no context in required ∪ exclusions is this name"
    if tmpl in census:
        return True, "its uninterpolated template is named"
    if not EXPR.sub("", tmpl).strip():
        d = legs_directive(path, jid)
        if d is None:
            return False, ("its name is NOTHING BUT interpolation and declares no "
                           "`# required-checks: matrix-name-legs` source, so no "
                           "context can be matched to it")
        missing = [n for n in leg_names(root, *d) if n not in census]
        if missing:
            return False, "legs not named: " + "; ".join(missing)
        return True, "every declared leg is named"
    parts = EXPR.split(tmpl)
    rx = re.compile(".+".join(re.escape(p) for p in parts))
    if any(rx.fullmatch(c) for c in census):
        return True, "an expansion of its template is named"
    return False, "no context matches its template"


def census(root):
    wf_dir = os.path.join(root, ".github", "workflows")
    spec_p = os.path.join(root, ".github", "required-checks.json")
    files = glob.glob(os.path.join(wf_dir, "*.yml")) + glob.glob(os.path.join(wf_dir, "*.yaml"))
    if not files:
        raise Refused(f"scanned ZERO workflow files under {wf_dir} — scanning "
                      "nothing is the vacuous pass this guard exists to refuse")
    try:
        req, exc = INV.required_contexts(spec_p)
    except Exception as e:
        raise Refused(f"cannot read {spec_p}: {e}")
    if not req:
        raise Refused("the spec names zero required contexts — a closure walked "
                      "from nothing is vacuous")
    try:
        graphs = INV.workflow_graphs(wf_dir, req)
    except Exception as e:
        raise Refused(f"cannot parse the workflows: {e}")
    produced = {g["jnames"][j] for g in graphs for j in g["req_jobs"]}
    orphan = sorted(req - produced)
    if orphan:
        raise Refused("required context(s) no job in .github/workflows/ produces: "
                      + "; ".join(orphan) + " — the closure below them cannot be walked")
    C = req | exc
    blocking, residue, total = [], [], 0
    for g in graphs:
        aggs = [g["jnames"][j] for j in g["req_jobs"]]
        on_pr = "pull_request" in g["keys"]
        for jid, job in g["jobs"].items():
            total += 1
            tmpl = str(g["jnames"][jid])
            ok, why = accounting(root, g["path"], jid, job, tmpl, C)
            row = {"workflow": g["workflow"], "job": jid, "name": tmpl,
                   "accounted": ok, "why": why, "aggregators": aggs,
                   "required": jid in g["req_jobs"], "on_pr": on_pr,
                   "coe": job.get("continue-on-error")}
            if jid in g["req_jobs"] or jid in g["feeds"]:
                blocking.append(row)
            elif not ok:
                residue.append(row)
    return {"files": len(files), "jobs": total, "required": sorted(req),
            "blocking": blocking, "residue": residue}


def report(r, out=sys.stdout):
    b = r["blocking"]
    bad = [x for x in b if not x["accounted"]]
    res = r["residue"]
    on_pr = [x for x in res if x["on_pr"]]
    no_coe = [x for x in on_pr if not x["coe"]]
    p = lambda s="": print(s, file=out)
    p(f"scanned {r['files']} workflow files, {r['jobs']} jobs; "
      f"{len(r['required'])} required contexts, each produced by a job")
    p(f"blocking-shaped (a required job or in its transitive needs closure): "
      f"{len(b)} jobs, {len(b) - len(bad)} accounted, {len(bad)} UNACCOUNTED")
    p(f"w56 recipe (jobs residue on_pull_request no_continue_on_error): "
      f"{r['jobs']} {len(res)} {len(on_pr)} {len(no_coe)}")
    p("  residue = not required, not in any closure, not named — it CANNOT block "
      "a merge, so it is reported, never red here:")
    for x in no_coe:
        p(f"    {x['workflow']} job {x['job']}: {x['name']}")
    for x in bad:
        p(f"UNACCOUNTED: {x['workflow']} job `{x['job']}` renders `{x['name']}` — "
          f"it is in the needs closure of required `{', '.join(x['aggregators'])}`, "
          f"so a red in it reds a required context, and {x['why']}. Name it in "
          f".github/required-checks.json (an S3 SUBSUMED exclusions row for a "
          f"leaf), or take it out of the aggregator's needs.")
    if bad:
        p(f"RED: {len(bad)} merge-blocking job name(s) the spec does not account for.")
    else:
        p("OK: every merge-blocking job name is in required ∪ exclusions.")
    return 1 if bad else 0


def at_rev(rev):
    d = tempfile.mkdtemp(prefix="blocking-census-")
    a = subprocess.run(["git", "-C", REPO, "archive", rev, ".github"],
                       capture_output=True)
    if a.returncode != 0:
        raise Refused(f"git archive {rev} failed: {a.stderr.decode().strip()}")
    t = subprocess.run(["tar", "-x", "-C", d], input=a.stdout, capture_output=True)
    if t.returncode != 0:
        raise Refused(f"tar -x failed: {t.stderr.decode().strip()}")
    return d


# ----------------------------------------------------------------- selftest ---
def selftest():
    import io, textwrap
    fails = []

    def check(label, cond, detail=""):
        print(("ok   " if cond else "FAIL ") + label + ("" if cond else " :: " + detail))
        if not cond:
            fails.append(label)

    def tree(wfs, req, exc, extra=None):
        d = tempfile.mkdtemp(prefix="bnc-selftest-")
        os.makedirs(os.path.join(d, ".github", "workflows"))
        for n, body in wfs.items():
            open(os.path.join(d, ".github", "workflows", n), "w").write(textwrap.dedent(body))
        json.dump({"protection": {"required_status_checks": {
            "checks": [{"context": c} for c in req]}},
            "exclusions": [{"context": c, "reason": "x"} for c in exc]},
            open(os.path.join(d, ".github", "required-checks.json"), "w"))
        for n, body in (extra or {}).items():
            open(os.path.join(d, n), "w").write(body)
        return d

    def run(d):
        buf = io.StringIO()
        try:
            rc = report(census(d), buf)
        except Refused as e:
            rc, _ = 2, buf.write("REFUSED: " + str(e))
        shutil.rmtree(d, ignore_errors=True)
        return rc, buf.getvalue()

    GATE = """
        name: g
        on: {pull_request: {}, push: {branches: [main]}}
        jobs:
          changes: {name: Dispatch, runs-on: x, steps: []}
          leaf: {name: Leaf, needs: changes, runs-on: x, steps: []}
          mid: {name: Mid, needs: [leaf], runs-on: x, steps: []}
          side: {name: Side, runs-on: x, steps: []}
          gate: {name: Gate, if: always(), needs: [changes, mid], runs-on: x, steps: []}
    """
    ROWS = ["Dispatch", "Leaf", "Mid"]
    rc, o = run(tree({"g.yml": GATE}, ["Gate"], ROWS))
    check("s1 every closure member named -> exit 0", rc == 0, o)
    check("s1b the count is emitted, not typed",
          "3 jobs" not in o and "4 jobs, 4 accounted, 0 UNACCOUNTED" in o, o)
    rc, o = run(tree({"g.yml": GATE}, ["Gate"], ["Dispatch", "Mid"]))
    check("s2 EDGE DIRECTION: a leaf that only needs `changes` and is needed "
          "THROUGH mid is found (walk inward from the aggregator)",
          rc == 1 and "UNACCOUNTED: g.yml job `leaf` renders `Leaf`" in o, o)
    mut = GATE.replace("needs: [changes, mid]", "needs: [changes, mid, planted]") + \
        "      planted: {name: Planted blocker, runs-on: x, steps: []}\n"
    rc, o = run(tree({"g.yml": mut}, ["Gate"], ROWS))
    check("s3 MUTATION: a job added to the aggregator's needs with no row reds BY NAME",
          rc == 1 and "`Planted blocker`" in o and "required `Gate`" in o, o)
    rc, o = run(tree({"g.yml": mut}, ["Gate"], ROWS + ["Planted blocker"]))
    check("s3b ... and naming it turns the guard green again", rc == 0, o)
    rc, o = run(tree({"g.yml": GATE}, ["Gate"], ROWS))
    check("s4 an unnamed sibling OUTSIDE the closure is residue, not red",
          rc == 0 and "g.yml job side: Side" in o, o)
    mtx = GATE.replace("leaf: {name: Leaf,", "leaf: {name: Leaf, strategy: {matrix: {v: [1]}},")
    rc, o = run(tree({"g.yml": mtx}, ["Gate"], ["Dispatch", "Leaf (27.0, 1.18.1)", "Mid"]))
    check("s5 a matrixed static name is named by its tuple-suffixed context", rc == 0, o)
    rc, o = run(tree({"g.yml": GATE}, ["Gate"], ["Dispatch", "Leaf (27.0, 1.18.1)", "Mid"]))
    check("s5b ... but an UNmatrixed job is not accounted by a suffixed row", rc == 1, o)
    tpl = GATE.replace("{name: Leaf,", "{name: 'Leaf (OTP ${{ matrix.otp }})',")
    rc, o = run(tree({"g.yml": tpl}, ["Gate"], ["Dispatch", "Leaf (OTP 27.0)", "Mid"]))
    check("s6 a partial template is accounted by a context it expands to", rc == 0, o)
    rc, o = run(tree({"g.yml": tpl}, ["Gate"], ["Dispatch", "Leaf (OTP ${{ matrix.otp }})", "Mid"]))
    check("s6b ... or by its own uninterpolated template (the skipped-leg name)", rc == 0, o)
    rc, o = run(tree({"g.yml": tpl}, ["Gate"], ["Dispatch", "Other (OTP 27.0)", "Mid"]))
    check("s6c ... and not by an unrelated context", rc == 1, o)
    catch_wf = textwrap.dedent(GATE).replace(
        "  leaf: {name: Leaf, needs: changes, runs-on: x, steps: []}\n",
        "  leaf:\n    # required-checks: matrix-name-legs legs.json .[].name\n"
        "    name: ${{ matrix.leg.name }}\n    needs: changes\n    runs-on: x\n    steps: []\n")
    legs = json.dumps([{"name": "leg one"}, {"name": "leg two"}])
    rc, o = run(tree({"g.yml": catch_wf}, ["Gate"], ["Dispatch", "Mid", "leg one", "leg two"],
                     {"legs.json": legs}))
    check("s7 a whole-interpolation name is accounted leg by leg through its declaration",
          rc == 0, o)
    rc, o = run(tree({"g.yml": catch_wf}, ["Gate"], ["Dispatch", "Mid", "leg one"],
                     {"legs.json": legs}))
    check("s7b ... and one unnamed leg reds, naming the leg", rc == 1 and "leg two" in o, o)
    undecl = catch_wf.replace("    # required-checks: matrix-name-legs legs.json .[].name\n", "")
    rc, o = run(tree({"g.yml": undecl}, ["Gate"], ["Dispatch", "Mid", "anything"]))
    check("s7c an undeclared catch-all is never matched (a .+ row is a takeover)",
          rc == 1 and "NOTHING BUT interpolation" in o, o)
    rc, o = run(tree({"g.yml": catch_wf}, ["Gate"], ["Dispatch", "Mid"], {}))
    check("s7d a declared legs file that does not exist REFUSES (exit 2)", rc == 2, o)
    d = tempfile.mkdtemp(prefix="bnc-selftest-")
    os.makedirs(os.path.join(d, ".github", "workflows"))
    json.dump({"protection": {"required_status_checks": {"checks": [{"context": "Gate"}]}}},
              open(os.path.join(d, ".github", "required-checks.json"), "w"))
    rc, o = run(d)
    check("s8 ZERO workflow files REFUSES — never a vacuous pass",
          rc == 2 and "ZERO workflow files" in o, o)
    rc, o = run(tree({"g.yml": GATE}, ["Gate", "Ghost gate"], ROWS))
    check("s9 a required context NO job produces REFUSES", rc == 2 and "Ghost gate" in o, o)
    bare_on = "name: b\non: [pull_request]\njobs:\n  gate: {name: Gate, needs: [x], runs-on: y, steps: []}\n" \
              "  x: {name: X, runs-on: y, steps: []}\n"
    rc, o = run(tree({"b.yml": bare_on}, ["Gate"], []))
    check("s10 the list form of `on:` (YAML 1.1 `on` -> True) is still walked",
          rc == 1 and "`X`" in o, o)
    two = {"g.yml": GATE, "p.yml": """
        name: p
        on: {push: {branches: [main]}}
        jobs:
          a: {name: A, runs-on: x, steps: []}
          b: {name: B, runs-on: x, continue-on-error: true, steps: []}
    """}
    rc, o = run(tree(two, ["Gate"], ROWS))
    check("s11 the recipe line is total/residue/on-PR/no-coe over ALL files",
          "(jobs residue on_pull_request no_continue_on_error): 7 3 1 1" in o, o)
    print()
    print(("SELFTEST FAILED: " + ", ".join(fails)) if fails else "SELFTEST OK")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=REPO)
    ap.add_argument("--at", metavar="REV")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    tmp = None
    try:
        root = a.root
        if a.at:
            root = tmp = at_rev(a.at)
        r = census(root)
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    if a.json:
        print(json.dumps(r, indent=1, default=str))
        return 1 if any(not x["accounted"] for x in r["blocking"]) else 0
    return report(r)


if __name__ == "__main__":
    sys.exit(main())
