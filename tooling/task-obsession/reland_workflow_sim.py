#!/usr/bin/env python3
"""Run reland-check.yml's OWN shell steps against a localhost stub ledger.

The Python half of the re-land check can be perfect while the workflow around it
still false-greens — the original bug lived entirely in the shell (`curl -sS`
with no `--fail`, `|| true`, `findings=${n:-0}`). So this harness does not
re-implement the steps: it EXTRACTS the `run:` scripts out of
`.github/workflows/reland-check.yml` and executes them, with

  * `${{ … }}` expressions in each step's `env:` replaced by test values,
  * `/tmp/` rewritten to a sandbox dir so a run cannot collide with the host,
  * `$GITHUB_OUTPUT` / `$GITHUB_STEP_SUMMARY` pointed at files we then assert on.

A shell edit that reintroduces a silent green therefore reds the gate. Prints
`SIM_<KEY>=<value>` machine lines for `reland_loudfail.test.sh` to assert on.

Scenarios:
  healthy       token present, ledger paginates    -> status=ok, pages=2, findings=1
  short         ledger total > reachable rows     -> status=ok + a PARTIAL-ledger ::warning
  error         ledger 404s                        -> status=infra, "DID NOT RUN"
  rotated       401 WITH a token                   -> status=infra (a broken secret)
  fork-refused  401 with NO token                  -> status=skipped (a fork)
  fork-anon     no token, anonymous read works     -> status=ok + a LOUD anon notice
                                                      (the live shape: task
                                                      visibility is public today)

Usage:
  python3 reland_workflow_sim.py --scenario <name> [--repo-root .]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler
from socketserver import TCPServer

WORKFLOW = ".github/workflows/reland-check.yml"
FETCH_STEP = "Fetch the ledger + run the re-land check"
ADVISORY_STEP = "Post the advisory (non-blocking)"
SUMMARY_STEP = "What this check actually did (always)"

# The workflow fetches with the real `--limit 1000`, so the stub corpus is
# 1000 + 1 documents and the ONE task that landed the PR's changed file sits at
# index 1000 — reachable only on page 2. The finding therefore exists if and only
# if the offset walk actually happened: the live bug (limit=1000, no walk over
# 6212 tasks) reproduces here as a 0-finding green.
PAGE_ONE = 1000
LANDED_FILE = "shipped.ex"


def stub_corpus():
    docs = [
        {
            "doc_id": "filler-%04d" % i,
            "content": {"lifecycle_status": "done", "landed": {"files": ["filler/%04d.ex" % i]}},
        }
        for i in range(PAGE_ONE)
    ]
    docs.append({
        "doc_id": "landed-on-page-two",
        "content": {"lifecycle_status": "done", "landed": {"files": [LANDED_FILE]}},
    })
    return docs


def stub_server(scenario, docs):
    """A ledger the walk must paginate — or an error surface it must not swallow."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if scenario == "error":
                return self.send_json(404, {
                    "error": {"code": "not_found", "message": "document not found"}
                })
            if scenario in ("fork-refused", "rotated"):
                return self.send_json(401, {
                    "error": {"code": "unauthorized", "message": "unauthorized"}
                })
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            offset = int(q.get("offset", ["0"])[0])
            # Clamp at 1000 exactly as the live server does (recipe R2: limit=2000
            # comes back with 1000 rows), so raising the limit cannot substitute
            # for walking.
            limit = min(int(q.get("limit", ["1000"])[0]), 1000)
            page = docs[offset:offset + limit]
            inner = {"documents": page, "count": len(page)}
            if q.get("count") == ["true"]:
                # `short` models a ledger whose `total` exceeds what the walk can
                # actually reach (rows added mid-walk, a cap, a filtered page):
                # the scan is real but INCOMPLETE, and must say so.
                inner["total"] = len(docs) + (500 if scenario == "short" else 0)
            self.send_json(200, {"result": inner})

        def send_json(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    srv = TCPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


def steps_of(root):
    import yaml  # only this harness needs it; the workflow itself does not

    with open(os.path.join(root, WORKFLOW)) as f:
        wf = yaml.safe_load(f)
    return {s.get("name"): s for s in wf["jobs"]["reland-check"]["steps"]}


def read_outputs(path):
    out = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    out[k] = v
    return out


def resolve_env(env, overrides, outputs):
    """Replace the step's `${{ … }}` expressions with test values."""
    resolved = {}
    for key, raw in (env or {}).items():
        raw = str(raw)
        if key in overrides:
            resolved[key] = overrides[key]
            continue
        m = re.search(r"steps\.check\.outputs\.([a-z_]+)", raw)
        if m:
            resolved[key] = outputs.get(m.group(1), "")
            continue
        # `${{ vars.X || 'default' }}` → the quoted default.
        m = re.search(r"'([^']*)'", raw)
        resolved[key] = m.group(1) if "${{" in raw and m else raw
    return resolved


def advisory_if(step):
    return str(step.get("if", ""))


def run_step(step, root, sandbox, env, out_path, summary_path, outputs=None):
    script = step["run"].replace("/tmp/", sandbox + "/")
    # Inline `${{ steps.check.outputs.X }}` interpolations — bash would choke on
    # the literal `${{`, so substitute them the way Actions would.
    script = re.sub(
        r"\$\{\{\s*steps\.check\.outputs\.([a-z_]+)\s*\}\}",
        lambda m: (outputs or {}).get(m.group(1), ""),
        script,
    )
    full = dict(os.environ, GITHUB_OUTPUT=out_path, GITHUB_STEP_SUMMARY=summary_path, **env)
    proc = subprocess.run(
        ["bash", "-c", script], cwd=root, env=full,
        capture_output=True, text=True,
    )
    return proc.stdout + proc.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--scenario",
        required=True,
        choices=("healthy", "short", "error", "rotated", "fork-refused", "fork-anon"),
    )
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args()

    root = os.path.abspath(args.repo_root)
    docs = stub_corpus()

    srv, base = stub_server(args.scenario, docs)
    sandbox = tempfile.mkdtemp(prefix="reland-sim-")
    try:
        # The "Compute changed files" step's product, without a git fixture: one
        # path that a page-2 document landed, so a healthy walk MUST find it.
        with open(os.path.join(sandbox, "changed.txt"), "w") as f:
            f.write(LANDED_FILE + "\n")
        out_path = os.path.join(sandbox, "github_output")
        summary_path = os.path.join(sandbox, "github_step_summary")

        steps = steps_of(root)
        token = "" if args.scenario.startswith("fork") else "stub-token"
        log = run_step(
            steps[FETCH_STEP], root, sandbox,
            resolve_env(steps[FETCH_STEP].get("env"),
                        {"LEDGER_BASE": base, "LEDGER_TOKEN": token, "PR_TASK": ""}, {}),
            out_path, summary_path,
        )
        outputs = read_outputs(out_path)

        # The advisory step, when its own `if:` gate would let it run. The gate is
        # PINNED below (SIM_ADVISORY_GATED_ON_STATUS) so this replication cannot
        # drift from the YAML it stands in for.
        advisory_gate = advisory_if(steps[ADVISORY_STEP])
        advisory = ""
        if outputs.get("status") == "ok" and outputs.get("findings") not in ("", "0", None):
            before = os.path.getsize(summary_path) if os.path.exists(summary_path) else 0
            log += run_step(
                steps[ADVISORY_STEP], root, sandbox,
                resolve_env(steps[ADVISORY_STEP].get("env"), {}, outputs),
                out_path, summary_path, outputs,
            )
            with open(summary_path) as f:
                f.seek(before)
                advisory = f.read()

        # …then the always() summary step, fed the outputs the check just wrote.
        log += run_step(
            steps[SUMMARY_STEP], root, sandbox,
            resolve_env(steps[SUMMARY_STEP].get("env"), {}, outputs),
            out_path, summary_path,
        )
        with open(summary_path) as f:
            summary = f.read()
    finally:
        srv.shutdown()
        shutil.rmtree(sandbox, ignore_errors=True)

    print("SIM_STATUS=%s" % outputs.get("status", ""))
    print("SIM_PAGES=%s" % outputs.get("pages", ""))
    print("SIM_DOCS=%s" % outputs.get("docs", ""))
    print("SIM_FINDINGS=%s" % outputs.get("findings", ""))
    print("SIM_AUTH=%s" % outputs.get("auth", ""))
    print("SIM_WARN_DID_NOT_RUN=%d" % ("DID NOT RUN" in log))
    print("SIM_WARN_ANON=%d" % ("ANONYMOUSLY" in log))
    print("SIM_WARN_TRUNCATED=%d" % ("PARTIAL ledger" in log))
    print("SIM_ERROR_ANNOTATION=%d" % ("::error" in log))
    print("SIM_SUMMARY_HAS_STATUS=%d" % (("| status | `%s` |" % outputs.get("status", "")) in summary))
    print("SIM_SUMMARY_HAS_PAGES=%d" % ("ledger pages walked | %s" % outputs.get("pages", "") in summary))
    print("SIM_SUMMARY_HAS_DIGESTS=%d" % ("land digests found |" in summary))
    print("SIM_SUMMARY_BYTES=%d" % len(summary))
    print("SIM_ADVISORY_POSTED=%d" % bool(advisory.strip()))
    print("SIM_ADVISORY_ANON_NOTICE=%d" % ("Read ANONYMOUSLY" in advisory))
    print("SIM_ADVISORY_GATED_ON_STATUS=%d" % ("steps.check.outputs.status == 'ok'" in advisory_gate))
    print("SIM_NOTE_HAS_ROTATED=%d" % ("rotated" in outputs.get("note", "")))
    if os.environ.get("RELAND_SIM_DEBUG"):
        sys.stderr.write("--- step log ---\n%s\n--- summary ---\n%s\n" % (log, summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
