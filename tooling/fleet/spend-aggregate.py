#!/usr/bin/env python3
"""spend-aggregate.py — the orchestrator's spend total, aggregated from the ledgers
that actually have a producer.

THE DEFECT THIS CLOSES (PDF-D105, task pdf-bl-orchestrator-spend-producer).
The dispatch cap gate reads ONE file, `$FLEET_HOME/orchestrator/spend.jsonl`, and
NOTHING in the repo has ever written it: the only producer is `record_spend` in
tooling/fleet/fleet-run.sh, which appends to the PER-WORKER path
`$FLEET_HOME/<worker>/spend.jsonl`. A missing file summed to $0.00, so the cap gate
reported "spent $0.00 of cap $N — dispatch allowed" forever: a brake whose input has
no producer, green in the proof harness (which seeds its own rows) and inert in
production.

THE CHOICE, AND WHY (acceptance criterion c0).
Two ways out: teach dispatch.sh to AGGREGATE the ledgers that already exist, or add a
SECOND WRITER that appends an orchestrator row per dispatched order. This is the
AGGREGATING READER, for three reasons:
  1. The simplicity law. A second writer is a new producer of the same dialect, and
     two producers of one number drift — the orchestrator would be charging orders at
     dispatch time while record_spend charges them at close time, and the difference
     between "dispatched" and "cost money" is exactly the gap that made this ledger
     a lie in the first place.
  2. The money is measured where it is spent. `record_spend` holds the run's own
     receipt (claude's `total_cost_usd`, codex's `turn.completed.usage`). A dispatch-
     time writer would have to ESTIMATE, and an estimated brake is not a brake.
  3. It is append-only-safe by construction: this reader never writes, never creates,
     never truncates. PDF-D37's NEVER-auto-reset rule cannot be violated by a process
     that has no write path at all.
D37 also says "orchestrator keeps its own under .../orchestrator/", so that file stays
in the sum when it exists (the efficiency proof seeds it). The total is the UNION of
every ledger found, summed per distinct FILE with no row-level de-duplication: a
de-dup on order_id could only ever UNDER-report spend, and under-reporting is the
precise failure direction this task was filed about.

CANNOT-READ IS NOT ZERO (the load-bearing part).
An absent ledger set and a genuinely unspent one are the same number and must not be
the same verdict. When no ledger file can be found or read at all, this exits
NO_SPEND_LEDGER (13) and prints NO total — the caller must render that as "cannot
read", never as a compliant $0.00. A ledger directory that exists and holds only
empty files is a real, readable zero and exits 0 with 0.0000.

MALFORMED IS LOUD (criterion c2). A row that is not JSON, is not an object, or whose
`cost_usd` is missing / non-numeric / a bool aborts with MALFORMED_SPEND_LEDGER_ROW
(12) naming the file and line. It is never coerced to 0 (brake disabled) or to
infinity (brake stuck). `cost_usd: null` is the one canonical non-number: an honest
"could not price it", skipped and counted in `unpriced`, matching record_spend's own
contract and dispatch.sh's existing reader.

VERDICTS. Rows carrying `"verdict": "MISS"` still count toward the total — the money
was spent whether or not the order succeeded — but are reported separately so a failed
turn's `total_cost_usd: 0` is legible as a failure rather than as a cheap success
(pdf-w1-honest-evidence cross-reference).

USAGE
    spend-aggregate.py [--fleet-home DIR] [--total]
      default : a JSON summary on stdout
      --total : the bare total, 4dp, for a shell gate to consume
EXIT
      0  a total was read      12 malformed row      13 no readable ledger
      2  usage error
"""
import argparse
import glob
import json
import os
import sys

E_MALFORMED = 12
E_NO_LEDGER = 13


def ledger_files(fleet_home):
    """Every per-worker ledger plus the orchestrator's own, sorted, deduplicated by path."""
    found = set(glob.glob(os.path.join(fleet_home, "*", "spend.jsonl")))
    return sorted(found)


def sum_file(path):
    """(total, rows, priced, unpriced, miss) for one ledger. Raises on malformed."""
    total = 0.0
    rows = priced = unpriced = miss = 0
    # errors="strict" ON PURPOSE, and the decode error is caught and RENAMED into the
    # same named abort as any other malformed row. Reading a corrupt ledger with
    # errors="replace" would silently turn undecodable bytes into U+FFFD and hand the
    # line to json.loads — coercion of a brake input by another route.
    with open(path, encoding="utf-8") as fh:
        n = 0
        while True:
            try:
                line = fh.readline()
            except UnicodeDecodeError as exc:
                raise Malformed(path, n + 1, "not valid UTF-8 at or after this line (%s)" % exc.reason, "")
            if line == "":
                break
            n += 1
            line = line.strip()
            if not line:
                continue
            rows += 1
            try:
                row = json.loads(line)
            except ValueError:
                raise Malformed(path, n, "not JSON", line)
            if not isinstance(row, dict):
                raise Malformed(path, n, "not a JSON object", line)
            if row.get("verdict") == "MISS":
                miss += 1
            usd = row.get("cost_usd", "__MISSING__")
            if usd is None:
                unpriced += 1
                continue
            if usd == "__MISSING__":
                raise Malformed(path, n, "missing 'cost_usd'", line)
            if isinstance(usd, bool) or not isinstance(usd, (int, float)):
                raise Malformed(path, n, "non-numeric 'cost_usd'", line)
            priced += 1
            total += float(usd)
    return total, rows, priced, unpriced, miss


class Malformed(Exception):
    def __init__(self, path, line_no, why, line):
        self.path, self.line_no, self.why, self.line = path, line_no, why, line
        super().__init__(why)

    def render(self):
        return (
            "ABORT: MALFORMED_SPEND_LEDGER_ROW %s line %d: %s: %s"
            % (self.path, self.line_no, self.why, self.line[:120])
        )


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--fleet-home", default=os.environ.get("FLEET_HOME")
                    or os.path.join(os.path.expanduser("~"), ".barkpark-fleet"))
    ap.add_argument("--total", action="store_true",
                    help="print only the bare total (4dp) instead of the JSON summary")
    args = ap.parse_args(argv)

    files = ledger_files(args.fleet_home)
    if not files:
        sys.stderr.write(
            "ABORT: NO_SPEND_LEDGER under %s — no <worker>/spend.jsonl and no orchestrator/"
            "spend.jsonl exists. A ledger that cannot be read is NOT $0.00 spent: the cap gate"
            " must report CANNOT READ, never 'dispatch allowed' (PDF-D37/D105).\n" % args.fleet_home)
        return E_NO_LEDGER

    total = 0.0
    rows = priced = unpriced = miss = 0
    read_ok = []
    for path in files:
        try:
            t, r, p, u, m = sum_file(path)
        except Malformed as exc:
            sys.stderr.write(exc.render() + "\n")
            sys.stderr.write(
                "ABORT: refusing to coerce a brake input to 0 (brake disabled) or to infinity"
                " (brake stuck) — PDF-D37.\n")
            return E_MALFORMED
        except OSError as exc:
            sys.stderr.write("ABORT: UNREADABLE_SPEND_LEDGER %s: %s\n" % (path, exc))
            return E_NO_LEDGER
        total += t
        rows += r
        priced += p
        unpriced += u
        miss += m
        read_ok.append(path)

    if args.total:
        print("%.4f" % total)
        return 0
    print(json.dumps({
        "fleet_home": args.fleet_home,
        "total_usd": round(total, 4),
        "ledgers": read_ok,
        "rows": rows,
        "priced_rows": priced,
        "unpriced_rows": unpriced,
        "miss_rows": miss,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
