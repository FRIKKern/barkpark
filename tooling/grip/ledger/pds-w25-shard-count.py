# Pinned GATE for the pds-w25 round shards: every manifest row of the named
# class must carry a well-formed disposition. Pages the corpus TO EXHAUSTION
# (stop on a page that PROVES it is the last one -- never a hardcoded ceiling:
# the server silently clamps limit>1000 and range(0,5000,...) was blind to every
# row past position 5000, measured 5000-of-6971 on 2026-08-22), guards each page
# against overflow, asserts the walk terminated, and prints EVERY failing row
# (bad[:15] made an operator fix fifteen, re-run, and red again on the
# sixteenth). Same pager shape as tooling/grip/seal.mjs (PR #12954).
#
# THE PAGE GUARD IS NOT LOCAL ANY MORE. `if len(docs) < PAGE: break` cannot tell
# the last page from a FAILED one (GET /v1/data/query/production/task 500'd
# mid-run on 2026-07-30 ~19:22Z under concurrent write load) or from a TRUNCATED
# one. A caller that swallows either reports a SMALLER BOARD and exits 0. The
# terminator now lives in census_walk.walk_pages, which refuses instead of
# breaking; drive it with `python3 census_walk.py --selftest` (20 arms, three of
# them controls, one of them the legacy under-report reproduced).
#
# Usage:    python3 pds-w25-shard-count.py <class> <manifest.tsv>
#           python3 pds-w25-shard-count.py --selftest
import json, os, sys, time, urllib.error, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from census_walk import walk_pages, CensusWalkRefusal  # noqa: E402

PAGE = 500
EXIT_WALK_REFUSED = 2


def load_config():
    cfg = json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))
    return cfg["server"].rstrip("/"), cfg["token"]


def make_fetch(srv, tok, page=PAGE, attempts=6):
    """(status, body) for one page. guerrilla 500s intermittently under fleet
    load and the IDENTICAL request succeeds moments later, so a 5xx is retried
    with backoff -- the SAME request, never a new shape. When the retries are
    spent the status is handed back UNCHANGED: walk_pages turns it into a named
    refusal. It is never allowed to become an empty page."""
    def fetch(off):
        url = "%s/v1/data/query/production/task?limit=%d&offset=%d" % (srv, page, off)
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
        last = None
        for attempt in range(1, attempts + 1):
            try:
                with urllib.request.urlopen(req, timeout=90) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                last = (e.code, e.read())
                if e.code >= 500 and attempt < attempts:
                    print("pds-w25-shard-count: HTTP %d at offset %d, retry %d/%d"
                          % (e.code, off, attempt, attempts), file=sys.stderr)
                    time.sleep(6 * attempt)
                    continue
                return last
            except urllib.error.URLError as e:
                # A dead socket is a TRANSPORT FAILURE, not an empty page.
                if attempt < attempts:
                    time.sleep(6 * attempt)
                    continue
                return 599, str(e.reason).encode()
        return last if last else (599, b"retries exhausted with no response")
    return fetch


def score(cls, want, rows):
    def s(v):
        return v.strip() if isinstance(v, str) else ""
    ok, bad = 0, []
    for i in want:
        r = rows.get(i)
        if not r:
            bad.append((i, "MISSING"))
            continue
        d = s(r.get("disposition")); rs = s(r.get("disposition_reason"))
        ow = s(r.get("disposition_owner")); tg = s(r.get("reopen_trigger"))
        prob = []
        if d not in ("open", "closed", "parked"): prob.append("disposition=%r" % d)
        if not rs: prob.append("no reason")
        if d == "parked" and not tg: prob.append("no reopen_trigger")
        if d == "open" and (not ow or ow == i): prob.append("owner=%r" % ow)
        if prob: bad.append((i, "; ".join(prob)))
        else: ok += 1
    return ok, bad


def selftest():
    """The guard this gate depends on, pinned HERE so a change to this file that
    drops the refusal reds without a network. Drives the real walk through the
    real make_fetch contract with a stub urlopen."""
    import io

    class _Resp(object):
        def __init__(self, status, body):
            self.status = status; self._b = body
        def read(self): return self._b
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def page_body(n, off, limit, has_more):
        return json.dumps({"result": {
            "count": n, "limit": limit, "offset": off, "hasMore": has_more,
            "documents": [{"_id": "row%d" % (off + i), "disposition": "open",
                           "disposition_reason": "r", "disposition_owner": "o"}
                          for i in range(n)]}}).encode()

    real_urlopen = urllib.request.urlopen
    bad = []

    def arm(name, want, script):
        seq = list(script)
        calls = {"n": 0}

        def fake(req, timeout=None):
            i = calls["n"]; calls["n"] += 1
            status, body = seq[min(i, len(seq) - 1)]
            if status >= 400:
                raise urllib.error.HTTPError(req.full_url, status, "err", {}, io.BytesIO(body))
            return _Resp(status, body)

        urllib.request.urlopen = fake
        try:
            res = walk_pages(make_fetch("http://stub", "t", page=2, attempts=2), 2)
            got, ok = repr(res), (want == "OK")
        except CensusWalkRefusal as exc:
            got, ok = str(exc).splitlines()[0], (want != "OK" and want in str(exc))
        except Exception as exc:                      # noqa: BLE001
            got, ok = "UNEXPECTED %s: %s" % (type(exc).__name__, exc), False
        finally:
            urllib.request.urlopen = real_urlopen
        print("  %-6s %-44s %s" % ("ok" if ok else "FAIL", name, got[:140]))
        if not ok: bad.append(name)

    print("pds-w25-shard-count selftest (page=2, no network)")
    arm("control: two clean pages", "OK",
        [(200, page_body(2, 0, 2, True)), (200, page_body(1, 2, 2, False))])
    arm("MUTATION: 500 exhausts retries -> refusal", "HTTP 500",
        [(200, page_body(2, 0, 2, True)), (500, b'{"errors":[]}')])
    arm("MUTATION: short page, hasMore=true", "TRUNCATED STREAM",
        [(200, page_body(2, 0, 2, True)), (200, page_body(1, 2, 2, True))])
    arm("MUTATION: 200 {\"ok\":false}", "no `result` object",
        [(200, b'{"ok":false,"reason":"pagination_shifted"}')])
    arm("MUTATION: server capped the page", "silently capped",
        [(200, page_body(2, 0, 1000, False))])

    # the scorer still discriminates -- a guard-only selftest would not notice.
    ok, badrows = score("c", ["a", "b"], {
        "a": {"disposition": "open", "disposition_reason": "r", "disposition_owner": "o"},
        "b": {"disposition": "parked", "disposition_reason": "r"}})
    if not (ok == 1 and len(badrows) == 1 and "no reopen_trigger" in badrows[0][1]):
        bad.append("scorer control"); print("  FAIL   scorer control", ok, badrows)
    else:
        print("  ok     %-44s parked-without-trigger caught" % "scorer control")

    print("pds-w25-shard-count selftest: %d failures" % len(bad))
    return 1 if bad else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2:
        print("usage: pds-w25-shard-count.py <class> <manifest.tsv> | --selftest",
              file=sys.stderr)
        return 2
    cls, mf = argv[0], argv[1]
    want = [l.split("\t")[1].strip() for l in open(mf) if l.split("\t")[0] == cls]
    srv, tok = load_config()
    try:
        res = walk_pages(make_fetch(srv, tok), PAGE)
    except CensusWalkRefusal as exc:
        # NEVER a smaller board. The gate has no verdict at all.
        print("WALK ABORT -- no board was read, so there is no verdict:\n%s" % exc,
              file=sys.stderr)
        return EXIT_WALK_REFUSED
    print("WALK pages=%d loaded=%d unique=%d terminated=%s"
          % (len(res.pages), sum(res.pages), len(res.rows), res.terminator))
    ok, bad = score(cls, want, res.rows)
    print("class=%s pinned=%d COUNTED_OK=%d FAILING=%d" % (cls, len(want), ok, len(bad)))
    for b in bad:
        print("  FAIL", b[0], b[1])
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
