#!/usr/bin/env python3
"""Fetch the task ledger for the re-land advisory — loudly, or not at all.

The CI half of task-obsession used to fetch the ledger with a bare
`curl -sS … && python3 reland_check.py`, which false-greened three ways
(re-derived 2026-08-17, tooling/grip/ledger/arpss-w2-reland-check-falsegreen-
rederivation-2026-08-17.md):

  1. HTTP-ERROR SILENCE — `curl -sS` has no `--fail`, so a 404/5xx error
     envelope was written to the tasks file and curl still exited 0. The check
     then read the error envelope as an EMPTY ledger and reported 0 findings:
     indistinguishable from "scanned everything, found nothing".
  2. TRUNCATION — the query pinned `limit=1000` with no offset walk. The live
     corpus is 6212 published tasks and the server CLAMPS limit to 1000, so the
     check silently scanned 16% of the ledger and called it a clean scan.
  3. NO TOTAL — without `?count=true` the envelope carries no `total`, so the
     truncation was not even detectable by the caller.

This fetcher fixes all three at the source: it captures the HTTP status code,
offset-walks to exhaustion under a page cap, and asks for `count=true` on the
first page so `total` is known. It writes ONE artifact carrying both the merged
documents AND its own verdict under a `reland_fetch` key, which
`reland_check.py` reads BEFORE it reads any findings.

Tri-state status (printed as `RELAND_STATUS=` on stdout, machine-readable):

  ok      — fetched and parsed. `truncated=1` if the page cap hit before `total`.
  infra   — HTTP error, transport failure, or an unparseable/unrecognizable
            body. The check could not evaluate; the workflow must say so out
            loud (::warning) rather than report "0 findings".
  skipped — deliberately not evaluated. The one case: a run with NO token
            (a fork PR, where secrets are unavailable) whose anonymous read was
            refused. A 401/403 WITH a token present is `infra` instead — that is
            a rotated secret, not a fork, and it must never hide behind the
            fork exemption.

Usage:
  python3 reland_fetch.py --base https://host --out /tmp/tasks.json \
    [--type task] [--dataset production] [--limit 1000] [--max-pages 20] \
    [--timeout 20] [--token TOK]

Always exits 0: the re-land check is advisory by design, so the workflow keys
on the printed status, never on an exit code.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

STATUS_OK = "ok"
STATUS_INFRA = "infra"
STATUS_SKIPPED = "skipped"


def page_url(base, dataset, doc_type, limit, offset, want_total):
    q = {
        "perspective": "published",
        "limit": str(limit),
        "offset": str(offset),
    }
    if want_total:
        q["count"] = "true"
    return "%s/v1/data/query/%s/%s?%s" % (
        base.rstrip("/"),
        urllib.parse.quote(dataset),
        urllib.parse.quote(doc_type),
        urllib.parse.urlencode(q),
    )


def get(url, token, timeout):
    """One GET. Returns (http_code, body_bytes_or_None, transport_error_or_None)."""
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        req.add_header("Authorization", "Bearer %s" % token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read(), None
    except urllib.error.HTTPError as e:  # a real response with a non-2xx code
        try:
            body = e.read()
        except Exception:  # pragma: no cover - stream already consumed
            body = b""
        return e.code, body, None
    except Exception as e:  # URLError, timeout, DNS, TLS …
        return 0, None, "%s: %s" % (type(e).__name__, e)


def documents_of(body):
    """The page's documents list, or None if the body is not a query envelope."""
    try:
        payload = json.loads(body.decode("utf-8", "replace"))
    except Exception as e:
        return None, None, "unparseable body (%s)" % type(e).__name__
    result = payload.get("result") if isinstance(payload, dict) else None
    if isinstance(result, dict) and isinstance(result.get("documents"), list):
        return result["documents"], result.get("total"), ""
    if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
        err = payload["error"]
        return None, None, "error envelope code=%s message=%s" % (
            err.get("code"),
            err.get("message"),
        )
    keys = sorted(payload.keys())[:6] if isinstance(payload, dict) else type(payload).__name__
    return None, None, "no result.documents in body (top level: %s)" % (keys,)


def fetch(base, dataset, doc_type, token, limit, max_pages, timeout):
    docs, pages, total, http = [], 0, None, 0
    status, note = STATUS_OK, ""

    for page in range(max_pages):
        url = page_url(base, dataset, doc_type, limit, page * limit, page == 0)
        http, body, transport = get(url, token, timeout)

        if transport is not None:
            status = STATUS_INFRA
            note = "ledger unreachable on page %d — %s" % (page + 1, transport)
            break
        if http in (401, 403) and not token:
            status = STATUS_SKIPPED
            note = (
                "no BARKPARK_TASK_TOKEN (fork PR — secrets are not exposed to forks) "
                "and the anonymous read was refused with HTTP %d" % http
            )
            break
        if not (200 <= http < 300):
            status = STATUS_INFRA
            note = "HTTP %d from the ledger on page %d%s" % (
                http,
                page + 1,
                " — the token may have been rotated" if token and http in (401, 403) else "",
            )
            break

        page_docs, page_total, why = documents_of(body)
        if page_docs is None:
            status = STATUS_INFRA
            note = "HTTP %d but %s" % (http, why)
            break

        pages += 1
        docs.extend(page_docs)
        if page_total is not None and total is None:
            total = page_total
        if len(page_docs) < limit:
            break
    else:
        # Ran the cap without a short page: the walk did NOT reach the end.
        status = STATUS_OK
        note = "page cap (%d) hit before exhaustion" % max_pages

    truncated = bool(
        status == STATUS_OK
        and (
            (total is not None and len(docs) < total)
            or (pages >= max_pages and note)
        )
    )
    return {
        "status": status,
        "note": note,
        "pages": pages,
        "page_size": limit,
        "docs": len(docs),
        "total": total,
        "truncated": truncated,
        "http": http,
        "auth": "token" if token else "anon",
    }, docs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="ledger base URL")
    ap.add_argument("--out", required=True, help="write the fetch artifact here")
    ap.add_argument("--dataset", default="production")
    ap.add_argument("--type", dest="doc_type", default="task")
    ap.add_argument("--limit", type=int, default=1000, help="page size (server clamps to 1000)")
    ap.add_argument("--max-pages", type=int, default=20, help="non-termination cap")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--token", default="", help="defaults to $BARKPARK_TASK_TOKEN")
    args = ap.parse_args()

    token = args.token or os.environ.get("BARKPARK_TASK_TOKEN", "")
    meta, docs = fetch(
        args.base,
        args.dataset,
        args.doc_type,
        token,
        max(1, args.limit),
        max(1, args.max_pages),
        args.timeout,
    )

    with open(args.out, "w") as f:
        json.dump({"reland_fetch": meta, "result": {"documents": docs}}, f)

    # Machine lines — the workflow reads STATUS before it reads anything else.
    print("RELAND_STATUS=%s" % meta["status"])
    print("RELAND_PAGES=%d" % meta["pages"])
    print("RELAND_DOCS=%d" % meta["docs"])
    print("RELAND_TOTAL=%s" % ("" if meta["total"] is None else meta["total"]))
    print("RELAND_TRUNCATED=%d" % (1 if meta["truncated"] else 0))
    print("RELAND_HTTP=%d" % meta["http"])
    print("RELAND_AUTH=%s" % meta["auth"])
    print("RELAND_NOTE=%s" % meta["note"].replace("\n", " "))
    return 0  # advisory by design — the status is the verdict, not the exit code


if __name__ == "__main__":
    sys.exit(main())
