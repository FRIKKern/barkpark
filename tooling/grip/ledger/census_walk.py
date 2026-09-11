#!/usr/bin/env python3
"""A paginated /v1/data/query walk that CANNOT read a failed page as the end of
the board.

WHY THIS FILE EXISTS. Every PDS census walks the same endpoint the same way:

    while True:
        docs = GET /v1/data/query/<ds>/<type>?limit=N&offset=K ["result"]["documents"]
        ...
        if len(docs) < N: break
        K += N

`if len(docs) < N: break` is a terminator that CANNOT TELL THREE THINGS APART:

  1. the genuine last page (fewer rows exist),
  2. a page that FAILED (HTTP 500 -- observed live on 2026-07-30 ~19:22Z on
     `?limit=1000&offset=0` while sibling builders wrote concurrently) and was
     swallowed into an empty/short list by a caller with a bare `except`,
  3. a page the server TRUNCATED -- short, 200, and NOT the last page.

In cases 2 and 3 the walk stops early and the census reports a SMALLER BOARD
WITH NO ERROR: a vacuous green. The safe direction is not "retry harder", it is
"a walk that terminates only on a page that PROVES it is the last one".

WHAT PROVES IT. The envelope carries an EXACT `hasMore`, computed server-side by
reading `limit + 1` rows (api/lib/barkpark/content/query.ex:115-118) and
surfaced at api/lib/barkpark_web/controllers/query_controller.ex:234-242. So:

  * `hasMore == False`             -> the ONLY clean terminator.
  * `hasMore == True` + short page -> TRUNCATED STREAM, refuse. (The old
                                      `< limit: break` walk stopped here and
                                      called it the end of the board.)
  * `hasMore` absent               -> fall back to the short-page rule, but only
                                      after count/limit/offset/documents have
                                      all been asserted coherent, and SAY SO.

Everything else -- a non-2xx, an unparseable body, a `{"ok":false,...}` that
parses cleanly, a silently capped `limit`, a page answered at a different
`offset`, `count != len(documents)` -- raises `CensusWalkRefusal`. NEVER breaks.

USE:
    from census_walk import walk_pages, CensusWalkRefusal
    pages, rows = walk_pages(fetch, page_size=500)

where `fetch(offset) -> (status:int, body:bytes|str)` is YOUR transport (so the
retry policy, the auth header and the pacing stay with the caller, and the guard
stays testable with a stub).

SELFTEST (no network, no credential):  python3 census_walk.py --selftest
"""

import json
import sys

__all__ = ["CensusWalkRefusal", "walk_pages", "WalkResult"]

DEFAULT_MAX_PAGES = 400


class CensusWalkRefusal(Exception):
    """A named refusal. A census that catches this and continues is the bug."""


class WalkResult(object):
    """What a completed walk knows about itself. `terminator` is load-bearing:
    a walk that ended on `hasMore=false` proved it saw the whole board; one that
    ended on `short-page-no-hasMore` only proved the server did not say."""

    __slots__ = ("rows", "pages", "terminator", "order")

    def __init__(self, rows, pages, terminator, order):
        self.rows = rows            # dict: _id -> doc, deduped
        self.pages = pages          # list[int]: rows delivered per page
        self.terminator = terminator
        self.order = order          # list[str]: _id in first-seen order

    def __repr__(self):
        return "WalkResult(pages=%d loaded=%d unique=%d terminator=%s)" % (
            len(self.pages), sum(self.pages), len(self.rows), self.terminator)


def _refuse(offset, msg, extra=None):
    detail = "" if not extra else "\n  " + "\n  ".join(str(x) for x in extra)
    raise CensusWalkRefusal(
        "census walk REFUSED at offset %d: %s%s" % (offset, msg, detail))


def parse_page(status, body, offset, limit):
    """One page, scored. Returns (docs, has_more_or_None).

    Every arm here is a REFUSAL, never a short page. Split out from the loop so
    a test can drive it directly.
    """
    if not isinstance(status, int):
        _refuse(offset, "transport returned a non-integer status %r" % (status,))
    if status < 200 or status >= 300:
        snippet = body[:300] if body is not None else b""
        if isinstance(snippet, bytes):
            snippet = snippet.decode("utf-8", "replace")
        _refuse(offset,
                "HTTP %d -- a failed page is never the end of the board" % status,
                ["body: %s" % snippet])
    if isinstance(body, bytes):
        try:
            body = body.decode("utf-8")
        except UnicodeDecodeError as exc:
            _refuse(offset, "HTTP %d but undecodable body: %s" % (status, exc))
    try:
        payload = json.loads(body)
    except ValueError as exc:
        _refuse(offset, "HTTP %d but unparseable body: %s" % (status, exc))
    if not isinstance(payload, dict):
        _refuse(offset, "HTTP %d but body is %s, not an object"
                % (status, type(payload).__name__))
    # A `{"ok": false, "reason": ...}` failure PARSES CLEANLY and has no
    # `result`. A "did it parse?" caller reads it as an empty last page.
    if "result" not in payload or not isinstance(payload["result"], dict):
        _refuse(offset,
                "HTTP %d but no `result` object -- this is the shape a "
                "{\"ok\":false,...} failure takes, and it parses cleanly" % status,
                ["keys: %s" % sorted(payload.keys())[:12]])
    result = payload["result"]
    for key, want in (("count", int), ("limit", int), ("offset", int),
                      ("documents", list)):
        if key not in result or not isinstance(result[key], want) \
                or isinstance(result[key], bool):
            _refuse(offset, "result.%s is missing or not %s" % (key, want.__name__),
                    ["result keys: %s" % sorted(result.keys())[:12]])
    docs = result["documents"]
    if result["limit"] != limit:
        _refuse(offset,
                "server silently capped the page: asked limit=%d, echoed limit=%d. "
                "A walk trusting its own request reports a SMALLER board and exits 0."
                % (limit, result["limit"]))
    if result["offset"] != offset:
        _refuse(offset, "server answered a different page: echoed offset=%d"
                % result["offset"])
    if result["count"] != len(docs):
        _refuse(offset, "truncated page: result.count=%d but %d documents delivered"
                % (result["count"], len(docs)))
    if len(docs) > limit:
        _refuse(offset, "incoherent page: %d documents for limit=%d" % (len(docs), limit))
    for doc in docs:
        if not isinstance(doc, dict) or not doc.get("_id"):
            _refuse(offset, "page carries a row with no _id")
    has_more = result.get("hasMore")
    if has_more is not None and not isinstance(has_more, bool):
        _refuse(offset, "result.hasMore is %r, not a boolean" % (has_more,))
    return docs, has_more


def walk_pages(fetch, page_size, max_pages=DEFAULT_MAX_PAGES, on_page=None):
    """Page to exhaustion or refuse. `fetch(offset) -> (status, body)`.

    Terminates ONLY on a page that proves it is the last one. Returns a
    WalkResult. Raises CensusWalkRefusal on anything else.
    """
    if page_size < 1:
        raise ValueError("page_size must be >= 1")
    rows = {}
    order = []
    pages = []
    offset = 0
    for _ in range(max_pages):
        got = fetch(offset)
        if not (isinstance(got, tuple) and len(got) == 2):
            _refuse(offset, "transport returned %r, not a (status, body) pair" % (got,))
        status, body = got
        docs, has_more = parse_page(status, body, offset, page_size)
        pages.append(len(docs))
        for doc in docs:
            did = doc["_id"]
            if did not in rows:
                order.append(did)
            rows[did] = doc
        if on_page is not None:
            on_page(offset, len(docs), has_more)

        if has_more is False:
            # The only terminator that PROVED it saw the whole board.
            return WalkResult(rows, pages, "hasMore=false", order)
        if has_more is True:
            if len(docs) < page_size:
                # SHORT BUT NOT LAST. The `< limit: break` walk stopped here and
                # reported a smaller board with no error.
                _refuse(offset,
                        "TRUNCATED STREAM: %d of %d rows delivered but the server "
                        "says hasMore=true -- a short page is not the end of the "
                        "board" % (len(docs), page_size))
            offset += page_size
            continue
        # hasMore absent: an older server, or a projection that dropped it. Fall
        # back to the short-page rule, but only now that the page is coherent.
        if len(docs) < page_size:
            return WalkResult(rows, pages, "short-page-no-hasMore(last=%d)" % len(docs), order)
        offset += page_size
    _refuse(offset,
            "walk did not terminate after %d pages of %d -- refusing to report a "
            "board it never finished reading" % (max_pages, page_size))


# --------------------------------------------------------------------------
# selftest: the MUTATION proof. Every arm drives the real walk with a stub
# transport, and every arm must REFUSE rather than return a smaller board.
# --------------------------------------------------------------------------

def _page(n, offset, limit, has_more=None, **over):
    result = {"count": n, "limit": limit, "offset": offset,
              "documents": [{"_id": "d%d" % (offset + i)} for i in range(n)]}
    if has_more is not None:
        result["hasMore"] = has_more
    result.update(over)
    return json.dumps({"result": result})


def _stub(pages):
    """pages: list of (status, body) keyed by page index."""
    def fetch(offset):
        idx = offset // _stub.size
        return pages[idx]
    return fetch


def selftest():
    _stub.size = 500
    L = 500
    bad = []

    def arm(name, want, fn):
        try:
            got = fn()
            ok = (want == "OK")
            note = repr(got)
        except CensusWalkRefusal as exc:
            ok = (want != "OK") and (want in str(exc))
            note = str(exc).splitlines()[0]
        except Exception as exc:            # noqa: BLE001
            ok = False
            note = "UNEXPECTED %s: %s" % (type(exc).__name__, exc)
        ran.append(name)
        print("  %-6s %-46s %s" % ("ok" if ok else "FAIL", name, note[:150]))
        if not ok:
            bad.append(name)

    print("census_walk selftest -- every arm drives walk_pages() with a stub transport")
    ran = []

    # --- CONTROL: a healthy three-page board walks clean. Without this arm a
    # guard that refuses EVERYTHING would score 100%.
    arm("control: clean board, hasMore=false", "OK", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)),
               (200, _page(L, L, L, True)),
               (200, _page(7, 2 * L, L, False))]), L))
    arm("control: clean board, no hasMore key", "OK", lambda: walk_pages(
        _stub([(200, _page(L, 0, L)), (200, _page(7, L, L))]), L))
    arm("control: exact multiple, hasMore=false", "OK", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)), (200, _page(L, L, L, False))]), L))

    # --- THE MUTATION the row is about: inject a FAILING page mid-walk.
    arm("MUTATION: 500 on page 2", "HTTP 500", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)),
               (500, b'{"errors":[{"code":"internal_error"}]}'),
               (200, _page(7, 2 * L, L, False))]), L))
    arm("MUTATION: 500 on page 1 (offset 0)", "HTTP 500", lambda: walk_pages(
        _stub([(500, b"boom")]), L))
    arm("MUTATION: 503 storage_unavailable", "HTTP 503", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)), (503, b'{"ok":false}')]), L))
    arm("MUTATION: 401 mid-walk", "HTTP 401", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)), (401, b"{}")]), L))

    # --- a failure that PARSES CLEANLY and has no `result`.
    arm("MUTATION: 200 {\"ok\":false} envelope", "no `result` object", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)),
               (200, '{"ok":false,"reason":"pagination_shifted"}')]), L))
    arm("MUTATION: 200 unparseable body", "unparseable body", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)), (200, b"<html>502 Bad Gateway</html>")]), L))
    arm("MUTATION: 200 body is a list", "not an object", lambda: walk_pages(
        _stub([(200, b"[]")]), L))

    # --- SHORT BUT NOT LAST: the exact vacuous green.
    arm("MUTATION: short page with hasMore=true", "TRUNCATED STREAM", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)), (200, _page(3, L, L, True))]), L))

    # --- shape faults that a `len(docs)` walk cannot see.
    arm("MUTATION: server capped limit", "silently capped", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)),
               (200, json.dumps({"result": {"count": 0, "limit": 1000, "offset": L,
                                            "documents": []}}))]), L))
    arm("MUTATION: wrong offset echoed", "different page", lambda: walk_pages(
        _stub([(200, _page(L, 0, L, True)),
               (200, json.dumps({"result": {"count": 4, "limit": L, "offset": 0,
                                            "hasMore": False,
                                            "documents": [{"_id": "x%d" % i} for i in range(4)]}}))]), L))
    arm("MUTATION: count disagrees with documents", "result.count=99", lambda: walk_pages(
        _stub([(200, _page(4, 0, L, False, count=99))]), L))
    arm("MUTATION: documents is not a list", "result.documents is missing", lambda: walk_pages(
        _stub([(200, json.dumps({"result": {"count": 0, "limit": L, "offset": 0,
                                            "documents": None}}))]), L))
    arm("MUTATION: row with no _id", "row with no _id", lambda: walk_pages(
        _stub([(200, json.dumps({"result": {"count": 1, "limit": L, "offset": 0,
                                            "documents": [{"title": "x"}]}}))]), L))
    arm("MUTATION: hasMore is a string", "not a boolean", lambda: walk_pages(
        _stub([(200, _page(4, 0, L, "false"))]), L))

    # --- a walk that never ends must refuse, not spin.
    arm("MUTATION: never-terminating stream", "did not terminate", lambda: walk_pages(
        (lambda offset: (200, _page(L, offset, L, True))), L, max_pages=5))

    # --- THE RED THIS GUARD REPLACES. The legacy terminator, run over the SAME
    # stub that carries a 500 on page 2, returns a SMALLER BOARD and no error.
    # If this arm ever stops reproducing, the premise of this file is gone.
    def legacy_is_wrong():
        stub = _stub([(200, _page(L, 0, L, True)),
                      (500, b'{"errors":[{"code":"internal_error"}]}'),
                      (200, _page(7, 2 * L, L, False))])

        def legacy_walk():
            # verbatim shape of every pre-guard census: a bare except that turns
            # a failed page into an empty one, then `< limit: break`.
            rows, off = {}, 0
            while True:
                try:
                    status, body = stub(off)
                    docs = json.loads(body)["result"]["documents"]
                except Exception:                      # noqa: BLE001
                    docs = []
                for d in docs:
                    rows[d["_id"]] = d
                if len(docs) < L:
                    break
                off += L
            return rows

        legacy = legacy_walk()
        assert len(legacy) == L, len(legacy)           # 500, not 1007: THE BUG
        try:
            walk_pages(stub, L)
        except CensusWalkRefusal as exc:
            return "legacy reported %d rows and exited clean; guard REFUSED: %s" % (
                len(legacy), str(exc).splitlines()[0])
        raise AssertionError("the guard did NOT refuse the injected failing page")
    arm("RED: legacy `< limit: break` under-reports", "OK", legacy_is_wrong)

    # --- the DEDUP + terminator record survive.
    def dedup():
        r = walk_pages(_stub([(200, _page(L, 0, L, True)),
                              (200, json.dumps({"result": {
                                  "count": L, "limit": L, "offset": L, "hasMore": False,
                                  "documents": [{"_id": "d0"}] * L}}))]), L)
        assert len(r.rows) == L, len(r.rows)
        assert r.pages == [L, L], r.pages
        assert r.terminator == "hasMore=false", r.terminator
        return r
    arm("dedup across pages, terminator recorded", "OK", dedup)

    print("census_walk selftest: %d arms, %d failures" % (len(ran), len(bad)))
    if bad:
        for b in bad:
            print("  FAILED:", b)
        return 1
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    print(__doc__)
    sys.exit(0)
