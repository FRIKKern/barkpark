"""Page-scanner for scripts/landed-open-report.sh — the READER half of the
landing back-link. See that script's header for the decision record.

Two subcommands, both file-in / stdout-JSON so nothing depends on a pipe:

    scan  <page.json>   -> one JSON object describing that page
    render <hits.jsonl> -> the human report body, oldest landing first

WHY A FILE ARGUMENT AND NEVER STDIN. `python3 - <<HEREDOC` makes the heredoc BE
stdin, so a helper that read stdin would read its own source and report a
confident empty zero. Every input here arrives by path.
"""

import json
import re
import sys

LANDED_CLASS = "landed-on-main"
# landed:pr-<n>@<sha>  and the PR-less spelling landed:main@<sha>
FACT_RE = re.compile(r"^landed:(?:pr-(\d+)@)?(?:main@)?([0-9a-f]{7,40})$")
LIVE = ("open", "in_progress")

# The two systematic false-positive classes, measured before this reader was
# written. Neither is filtered OUT — a reader that silently drops rows is the
# same failure as a reader that finds none. They are FLAGGED, so a lead spends
# attention in the right order.
#
#   PARENT  an epic/goal row is named by MANY PRs; one row was named by 34.
#           A PR naming a parent is a CONTRIBUTION, not a discharge, so a
#           landed label on a row with children is near-worthless as evidence.
#   GATE?   a human-gate criterion always LOOKS finished: the work merged and
#           the gate is a person who has not looked yet.
GATE_RE = re.compile(
    r"merge[- ]gate|human[- ]gate|sign[- ]?off|signed off|a lead |reviewer|"
    r"by hand|manually verif|owner approval",
    re.I,
)
PARENT_KINDS = ("epic", "goal", "initiative")


def norm_labels(raw):
    """`labels` is sometimes an array of STRINGS and sometimes an array of
    OBJECTS carrying {tag,strength,rationale}. A join() over the mixed shape
    aborts the whole page, so every consumer goes through here."""
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if isinstance(item, dict):
            tag = item.get("tag")
            if isinstance(tag, str):
                out.append(tag)
        elif isinstance(item, str):
            out.append(item)
        else:
            out.append(str(item))
    return out


def row_parts(row):
    doc = row.get("doc", row) or {}
    content = doc.get("content") or {}
    return doc, content


def lifecycle_of(doc, content):
    for src in (doc, content):
        v = src.get("lifecycle_status")
        if isinstance(v, str) and v:
            return v
    return "?"


def criteria_tally(content):
    crit = content.get("acceptance_criteria")
    if not isinstance(crit, list):
        return 0, 0, []
    texts = []
    met = 0
    for c in crit:
        if not isinstance(c, dict):
            continue
        # The criterion text is keyed `criterion`, NOT `text`. Walking .text
        # returns None and looks exactly like an empty row.
        texts.append(str(c.get("criterion") or ""))
        # NEVER read a boolean with jq's `//` or python's `or`: False is falsy
        # and would read as absent. has-key, then the value.
        if c.get("met") is True:
            met += 1
    return met, len(texts), texts


def flags_for(doc, content, texts):
    flags = []
    kind = str(content.get("kind") or doc.get("kind") or "").lower()
    children = doc.get("child_count")
    if kind in PARENT_KINDS or (isinstance(children, int) and children > 0):
        flags.append("PARENT")
    for i, t in enumerate(texts):
        c = content.get("acceptance_criteria")[i]
        if isinstance(c, dict) and c.get("met") is True:
            continue
        if GATE_RE.search(t):
            flags.append("GATE?")
            break
    return flags


def err(msg):
    """A read failure leaves the message on STDERR and exits 3. It is NOT put
    in the JSON payload: the payload also carries row titles, and a caller that
    substring-matched for `error` there would red on a task whose title says
    the word."""
    sys.stderr.write("scan: %s\n" % msg)
    return 3


def cmd_scan(argv):
    """Read one `bp task ls -o json` page. Emits the accounting the caller
    ASSERTS on — a pager that trusts its own loop wrote zero rows for 3 of 9
    pages while printing a tidy 'page N: 0 rows' at exit 0."""
    raw = open(argv[0], encoding="utf-8", errors="replace").read()
    # bp can print warning lines on STDOUT before the JSON.
    start = raw.find("{")
    if start < 0:
        return err("no JSON object in page (%d bytes read)" % len(raw))
    try:
        page = json.loads(raw[start:])
    except ValueError as exc:
        return err("unparseable page: %s" % exc)

    docs = page.get("docs")
    if not isinstance(docs, list):
        # `.docs`, NOT `.tasks` — a pager keyed on the wrong name reports zero
        # rows and exit 0, which is byte-identical to a genuinely empty ledger.
        return err("page has no `docs` array (keys: %s)"
                   % ",".join(sorted(page.keys())))

    meta = page.get("page") or {}
    returned = meta.get("returned")
    hits = []
    for row in docs:
        doc, content = row_parts(row)
        labels = norm_labels(content.get("labels"))
        if LANDED_CLASS not in labels:
            continue
        lifecycle = lifecycle_of(doc, content)
        fact, pr, sha = "", "", ""
        for lab in labels:
            m = FACT_RE.match(lab)
            if m:
                fact, pr, sha = lab, m.group(1) or "", m.group(2)
                break
        met, total, texts = criteria_tally(content)
        hits.append({
            "doc_id": doc.get("doc_id") or doc.get("id") or content.get("doc_id") or "?",
            "lifecycle": lifecycle,
            "live": lifecycle in LIVE,
            "met": met,
            "total": total,
            "fact": fact or "landed:<no-sha-label>",
            "pr": pr,
            "sha": sha,
            "flags": flags_for(doc, content, texts),
            "assignee": content.get("assignee") or doc.get("assignee") or "-",
            "title": (doc.get("title") or content.get("title") or "")[:80],
        })

    print(json.dumps({
        "docs_len": len(docs),
        "returned": returned,
        "has_more": bool(meta.get("has_more")),
        "next_cursor": meta.get("next_cursor") or "",
        "hits": hits,
    }))
    return 0


def cmd_render(argv):
    """hits.jsonl -> report body. argv[1] is an optional sha->epoch map so the
    age of the LANDING (not of the row's last touch) can be printed."""
    rows = []
    with open(argv[0], encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    ages = {}
    if len(argv) > 1 and argv[1]:
        try:
            ages = json.load(open(argv[1], encoding="utf-8"))
        except (IOError, ValueError):
            ages = {}

    live = [r for r in rows if r["live"]]
    # Oldest landing first — the oldest is the most damning. A landing whose
    # sha git could not resolve sorts LAST and prints `?`, never 0: an
    # unresolved age must not masquerade as the oldest row in the report.
    def key(r):
        a = ages.get(r["sha"])
        # OLDEST FIRST, so age DESCENDING: a row whose work landed a month ago
        # and is still open is the most damning line in the report and belongs
        # at the top. (Sorting the age ascending puts today's merges first,
        # which reads as a changelog rather than a debt list.)
        return (0, -a) if isinstance(a, (int, float)) else (1, 0)

    live.sort(key=key)
    for r in live:
        a = ages.get(r["sha"])
        age = "%dd" % int(a) if isinstance(a, (int, float)) else "?"
        flags = (" [" + ",".join(r["flags"]) + "]") if r["flags"] else ""
        print("%-26s %-12s %2d/%-2d %-28s %5s  %s%s" % (
            r["doc_id"], r["lifecycle"], r["met"], r["total"],
            r["fact"], age, r["title"], flags))
    return 0


CMDS = {"scan": cmd_scan, "render": cmd_render}

if __name__ == "__main__":
    sys.exit(CMDS[sys.argv[1]](sys.argv[2:]))
