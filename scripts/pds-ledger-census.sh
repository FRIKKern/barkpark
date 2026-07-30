#!/usr/bin/env bash
#
# PDS LEDGER CENSUS — re-derive the Personal Development Server epic's board
# from the ledger itself, and FAIL LOUDLY on every lens that silently
# undercounts it.
#
# WHY A SCRIPT AND NOT A PAPER. A number that lives only in a Paper is a number
# nobody can re-derive. The epic's law is that no verb may report success on an
# exit code alone; a census is a verb whose whole output is a success claim
# ("the board is N rows, M of them live"), so it is exactly the verb most able
# to lie. Every clause below was EARNED by a silent undercount measured against
# the live board during wave 24 — each one exits 0 today and reports a SMALLER
# board with no error, which is the vacuous green this instrument exists to
# make impossible.
#
# THE FIVE CLAUSES, AND THE MEASUREMENT BEHIND EACH
#
#   (1) PAGE, AND PROVE THE PAGE WAS HONOURED.
#       GET /v1/data/query/production/task?limit=5000 returns HTTP 200 and
#       `result.limit: 1000` — the server silently caps and never says so.
#       Measured 2026-07-30: asked 5000, echoed 1000, 1000 documents. A reader
#       that trusts its own request builds a 127-descendant closure and exits
#       0 — a ~54% undercount with no error anywhere. So: page by EXPLICIT
#       offsets until a short page, and assert on every page that the server
#       echoed back the limit and offset that were ASKED FOR. A cap that is
#       not echoed honestly is a transport failure, not a smaller board.
#
#   (2) WALK THE TRANSITIVE CLOSURE OVER parent_id — NEVER `.children`.
#       `bp task get <root> | .children` is a ONE-LEVEL read: 179 rows against
#       a closure of 285 descendants / 168 live, with 57 live rows hanging
#       under done/cancelled parents. Re-measured here 2026-07-30 with this
#       script: `--lens children` drops 106 rows (181 of 287) and the fixpoint
#       assertion names every one of them, e.g. pds-bl-bandit-request-line-
#       ceiling under pds-w1-crown-proof. A `.children` census scores ~63% of
#       the board and greens. `blocked` appears in the closure and NOWHERE at
#       level 1, so a status vocabulary built from `.children` does not even
#       know `blocked` is legal. The guard is not "use the right lens" (a
#       classification string, which is what wave 23 refused to ship) but a
#       BEHAVIOURAL fixpoint assertion: after the walk, no row anywhere in the
#       fully-paged corpus may have a parent inside the closure while sitting
#       outside it. A one-level lens violates that on its first grandchild.
#       `--lens children` exists ONLY so the selftest can inject that lens and
#       watch the fixpoint assertion catch it.
#
#   (3) SCORE ON HTTP STATUS AND AN ASSERTED SHAPE — NEVER AN ENVELOPE KEY,
#       NEVER "json.load SUCCEEDED".
#       /v1/data/* fails with {"ok":false,"error":{"code":...}}; /v1/tasks/*
#       fails with {"ok":false,"reason":...}. A census keyed on `error.code`
#       reads every tasks-API failure as a success. Worse, the 429 body
#       {"ok":false,"error":{"code":"rate_limited"}} is VALID JSON, so a
#       "did it parse?" test reads a rate limit AS DATA and counts the row as
#       a leaf. Here: the HTTP status decides first, and a 2xx still has to
#       produce a body of the asserted shape (result{count,offset,limit,
#       documents:list}) before a single row is counted.
#
#   (4) SERIAL, PACED, WITH BACKOFF.
#       A 10-way parallel walk of the same board returned 191 of 285 nodes and
#       exited 0, caching five rate-limited responses AS DOCUMENTS. guerrilla
#       rate-limits hard under concurrent wave load, and `bp` re-fetches
#       /v1/capabilities on EVERY invocation against the same budget, where a
#       429 surfaces as a config-shaped BARKPARK_MANIFEST error that looks
#       nothing like rate limiting. This instrument therefore issues its own
#       requests, one at a time, paced, and treats 429 as retry-then-fail —
#       never as an empty page. Deriving the closure from the paged corpus
#       (a handful of requests) rather than fetching each of 285 nodes is the
#       same closure at ~1/50th the request budget.
#
#   (5) NAME THE INSTANT AND ASSERT COHERENCE.
#       A census is a snapshot or it is an average. The window is named in the
#       output, and any row in the closure whose _updatedAt lands INSIDE that
#       window (or any row served twice across pages) makes the run exit 4:
#       the board moved under the read, so re-run it. Silence about drift is
#       how an average gets quoted as a snapshot.
#
# THE DONE-CONDITION. `--assert-round-done` demands that every non-empty
# disposition_reason be DISTINCT (distinct reason hashes == non-empty reasons)
# and that zero rows carry an off-vocabulary disposition. It is honestly RED on
# today's board — a done-condition that is green before the work is done is not
# a done-condition. Measured 2026-07-30: 145 non-empty reasons collapsing to
# 127 distinct hashes (the 18-row boilerplate gap), 78 off-vocabulary
# dispositions. Exit 1.
#
# CLAUSE 4 OF THE DONE-CONDITION — LIVE COVERAGE (wave 25, PDS-D346/D347).
# Clauses 1-3 above are CLOSURE-scoped and they are correctly so: distinctness
# and vocabulary are properties of everything ever written. But they are all
# satisfiable by a board that says NOTHING. A live row with no disposition lands
# in the `<unset>` bucket no clause reads; a blank reason is skipped before it is
# hashed; an unset disposition is skipped before it is scored. So the predicate
# that is supposed to certify "the round adjudicated the board" could go green
# over a board where every LIVE row is silent — the exact vacuous green this
# instrument exists to make impossible. Clause 4 is therefore the ONE
# LIVE-scoped clause, with three sub-lines that each say no on their own:
#
#   (a) a LIVE row with no disposition at all — it says nothing;
#   (b) a LIVE row that carries a disposition but no disposition_reason — it
#       asserts a verdict it cannot prove;
#   (c) a LIVE `parked` row with no STRUCTURED `reopen_trigger` — a park with
#       no machine-evaluable way back out is a park nobody will ever revisit.
#
# (c) READS `reopen_trigger` AND NOTHING ELSE. It deliberately does NOT inherit
# the REOPEN_TRIGGER_RE prose match used by the display counter below: prose
# that says "REOPEN: when the cap lifts" inside a reason is DECORATION, not a
# field a script can evaluate, and PDS-D336(b) condemns scoring it by name. The
# two are reported side by side and NEVER summed — on the live board of
# 2026-07-30 that is 0 structured against 40 prose-only, and a summed counter
# would have read 40 and called it coverage.
#
# CLAUSE 4(a) IS ROUND-ANCHORED (wave 26, PDS-D364/D365). Clause 4(a) as wave 25
# shipped it is STRUCTURALLY UNREACHABLE by any round that discovers work: a row
# is BORN with no disposition, so a round that files a single new row can never
# satisfy "every live row carries a disposition" at the instant it wants to
# certify. Wave 25 ended with 19 bare rows that were ITS OWN residue. The fix is
# not to weaken the clause but to say WHICH ROUND it is asking about:
#
#   --anchor-from-paper <wave-slug> resolves GET /v1/data/doc/<dataset>/paper/
#   <slug> and reads `result._createdAt` -- the instant the round was born.
#   4(a) then asserts over the live rows that existed AT OR BEFORE that instant,
#   and every live bare row born AFTER it is printed as a NAMED residue list:
#   the next round's inbox, not this round's failure.
#
# THE ANCHOR IS DERIVED, NEVER ARGUED. `--anchor 2020-01-01T00:00:00Z` was
# measured on the LIVE board to flip 4(a) from `157/172 FAIL` to `172/172 PASS`
# -- a round could seal itself by argv. So the raw `--anchor` is reachable ONLY
# under --fixture-dir (it is the selftest's clock), and --anchor-from-paper FAILS
# CLOSED on a non-200 or an unreadable `_createdAt`. It NEVER falls back to now():
# an anchor at now() is an anchor that excuses every row the round just filed.
#
# IT TERMINATES, AND THAT WAS OBSERVED, NOT ARGUED. Anchored at wave 25's Paper
# the live board reports residue 14 and 4(a) 171/172; anchored at wave 26's,
# residue 0 and 4(a) 157/172. The SAME 14 rows are residue for round N and
# in-scope for round N+1 -- deferred by exactly one round, never forever, and
# adjudicating a row files no new rows.
#
# FAIL CLOSED ON A ROW THE PREDICATE CANNOT PLACE. A live bare row with a missing
# or unreadable `_createdAt` exits 2, exactly as clause 5 does for `_updatedAt`.
# A row that cannot be placed on either side of the anchor must never be silently
# excused into the residue.
#
# THE ANCHOR ENTERS IN EXACTLY ONE PLACE: census()'s clause-4(a) live subset. It
# does NOT touch build_closure or read_corpus -- the closure stays WHOLE or the
# fixpoint assertion stops being able to catch a truncated walk (PDS-D347: clause
# 4 is added BESIDE clauses 1-3 and never rescopes them). 4(b) and 4(c) stay
# whole-live: a row that HAS a disposition owes a reason regardless of birth.
#
# CLAUSE 5 IS ORTHOGONAL AND STAYS SO. Its window is THIS CENSUS'S OWN READ
# WINDOW (`started` below, measured 17.9-30.8s wide live), not the round window.
# Widening it to the round window would trip on every residue write by
# construction and make a certifying run impossible. Because exit 4 fires BEFORE
# the predicate block prints, the operational rule is:
#
#     ADJUDICATE -> QUIESCE -> CERTIFY
#
# adjudicate the board, stop writing to it, and only then run the census with
# --assert-round-done --anchor-from-paper <this wave's Paper>. Exit 4 is
# retryable and means only "you were still writing"; re-run once quiet.
#
# PDS-D336(a) is pinned in the other direction too: triggers are NOT required to
# be distinct. One family trigger over several distinct reasons ("REOPEN when
# the Hetzner rate cap lifts") is legitimate and is what the board's best rows
# already do; only REASONS must be distinct.
#
# THE KEY PATH IS SETTLED: /v1/data/query FLATTENS content.* to the top level,
# so reading `disposition` / `disposition_reason` / `reopen_trigger` off the row
# is correct and an absence measured here is a REAL absence. Do not add a
# content-unwrapping normaliser: 13 corpus rows carry a literal top-level
# `content` key and one of them is null, so unwrapping would corrupt the read.
#
# CASE IS PART OF THE VALUE. Dispositions are counted CASE-EXACT, so `OPEN`
# (67 rows on 2026-07-30) and `open` (44) are two different things and the
# split is visible rather than averaged away. `open` is the canonical form and
# lives in one named constant (CANONICAL_OPEN) — change it there, nowhere else.
#
# READ-ONLY. This instrument never writes, never creates, never publishes.
# Charter PDS-D334 (a bare patch writes the DRAFT and the published route
# serves the PRE-WRITE value for a variable 5-40s) is therefore not in play,
# and cannot be brought into play by a flag.
#
# NOT WIRED INTO CI. It is an instrument. Arming a gate on it is a separate
# decision the round has to make on its own evidence.
#
# EXIT CODES
#   0  census produced, coherent, and (if asked) the round-done predicate holds
#   1  --assert-round-done predicate is FALSE — the round is not done
#   2  FAIL CLOSED: transport, shape, pagination, lens or population failure.
#      Nothing is reported as a board. This is the exit code that a silent
#      undercount used to be able to dodge.
#   3  usage error
#   4  SNAPSHOT INCOHERENT: the board moved inside the named window. Re-run.
#
# USAGE
#   scripts/pds-ledger-census.sh [--root SLUG] [--page-limit N] [--pace SECS]
#                                [--retries N] [--lens closure|children]
#                                [--assert-round-done] [--json]
#                                [--anchor-from-paper WAVE-PAPER-SLUG]
#                                [--fixture-dir DIR] [--server URL]
#   bash scripts/pds-ledger-census_test.sh    # the mutation fixtures
#
# --fixture-dir DIR replaces the network with canned HTTP responses
# (DIR/page-<i>.http, first line "HTTP <status>", remainder the body; and
# DIR/paper-<slug>.http for the anchor read). It is the selftest's transport and
# the only reason the selftest can prove this instrument REDS rather than merely
# prove it runs. --anchor <ISO-8601> is the selftest's clock and is REFUSED
# outside --fixture-dir; a certifying run derives its anchor or has none.

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "pds-ledger-census: python3 is required (stdlib only, no new deps)" >&2
  exit 3
fi

exec python3 - "$@" <<'PYEOF'
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone

# --- ratified constants -------------------------------------------------------

# The PDS epic root. Every count in this census is relative to it.
DEFAULT_ROOT = "task-2ac1f95237c4a8e5"

# The canonical case for the OPEN disposition. `OPEN` (67 rows on 2026-07-30)
# is off-vocabulary against it. ONE constant: if a later round ratifies the
# other case, this line is the whole change.
#
# WAVE-24 REVIEW CORRECTION (2026-07-30). This was `OPEN` as the wave brief
# instructed. The brief predates the same wave's D337 verb: `Tasks.Stage` now
# owns the triple and NORMALISES the term with String.trim/1 + String.downcase/1
# (`stage.ex` @dispositions ~w(open parked closed)), and it is the ONLY
# sanctioned writer. An uppercase canon is therefore UNREACHABLE by the only
# door that can write it — every governed row would count as off-vocabulary and
# `--assert-round-done` could never pass, on any board, forever. The writer is
# the normaliser, so the census follows the writer. Lowercase also matches the
# 27 `parked` template exemplars (PDS-D332) and the `lifecycle_status` idiom,
# so the round rewrites 67 rows rather than 71.
CANONICAL_OPEN = "open"
DISPOSITION_VOCABULARY = (CANONICAL_OPEN, "closed", "parked")

# lifecycle_status values that mean the row is finished. Everything else --
# including `blocked`, which appears only in the closure and never at level 1 --
# counts as live.
TERMINAL_LIFECYCLE = ("done", "cancelled", "canceled")

# DISPLAY ONLY. A disposition_reason that MENTIONS a reopen trigger in prose.
# This regex scores decoration, so it is quarantined here: it feeds the
# `prose-only REOPEN mention` display counter and NOTHING else. The done
# condition's clause 4(c) reads the structured `reopen_trigger` field alone --
# see structured_trigger() -- because PDS-D336(b) condemns scoring prose.
REOPEN_TRIGGER_RE = re.compile(r"\b(RE-?OPEN|REACTIVATE)\b\s*(TRIGGER)?\s*[:\-]", re.I)

# The disposition value that means "parked", matched case-insensitively ONLY
# here: counting is case-exact everywhere else (that split is the finding), but
# a row must not be able to dodge the trigger requirement by shouting PARKED.
PARKED_DISPOSITION = "parked"

# The API's page cap. Asking for more is answered with a silently smaller page.
DEFAULT_PAGE_LIMIT = 1000
DEFAULT_PACE_SECONDS = 0.15
DEFAULT_RETRIES = 4
MAX_PAGES = 200

EXIT_OK = 0
EXIT_ROUND_NOT_DONE = 1
EXIT_FAIL_CLOSED = 2
EXIT_USAGE = 3
EXIT_INCOHERENT = 4


def die(code, msg, detail=None):
    label = {
        EXIT_FAIL_CLOSED: "FAIL CLOSED",
        EXIT_USAGE: "USAGE",
        EXIT_INCOHERENT: "SNAPSHOT INCOHERENT",
    }.get(code, "FAILED")
    print("pds-ledger-census: %s: %s" % (label, msg), file=sys.stderr)
    if detail:
        for line in detail:
            print("  %s" % line, file=sys.stderr)
    sys.exit(code)


# --- transport ----------------------------------------------------------------
#
# Clause 3 lives here: the caller gets (status, body_bytes) and NOTHING else.
# There is no code path by which a body can be interpreted before its status
# has been judged.


class HttpTransport(object):
    def __init__(self, server, token):
        self.server = server.rstrip("/")
        self.token = token

    def describe(self):
        return self.server

    def get(self, path, query, page_index, attempt):
        return self._request("%s%s?%s" % (self.server, path, query))

    def get_doc(self, path, slug):
        """The anchor read. Same status-first discipline, no retry budget: an
        anchor that could not be resolved is a fail, never a default."""
        return self._request("%s%s" % (self.server, path))

    def _request(self, url):
        req = urllib.request.Request(url, headers={
            "Authorization": "Bearer %s" % self.token,
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except urllib.error.URLError as exc:
            die(EXIT_FAIL_CLOSED, "network failure reaching %s: %s" % (url, exc.reason))


class FixtureTransport(object):
    """Canned HTTP responses: DIR/page-<i>.http, first line `HTTP <status>`.

    Responses are keyed by PAGE INDEX, not by request count, because a retry
    re-requests the SAME page -- a transport that advanced on retry would model
    a server that answers a different page each time you ask, which is not the
    server. DIR/page-<i>-attempt-<n>.http overrides page <i> on attempt n, so a
    fixture can serve a 429 first and the real page on the retry.

    This is the selftest's transport. It exercises the SAME status-scoring,
    shape-asserting and paging code the live run uses -- a fixture that bypassed
    them would prove nothing.
    """

    def __init__(self, directory):
        self.dir = directory

    def describe(self):
        return "fixture://%s" % self.dir

    def get(self, path, query, page_index, attempt):
        path_i = os.path.join(self.dir, "page-%d-attempt-%d.http" % (page_index, attempt))
        if not os.path.exists(path_i):
            path_i = os.path.join(self.dir, "page-%d.http" % page_index)
        if not os.path.exists(path_i):
            die(EXIT_FAIL_CLOSED,
                "fixture exhausted: no %s (the read wanted another page and the "
                "source stopped answering -- that is a truncated read, not a "
                "smaller board)" % os.path.basename(path_i))
        return self._read(path_i)

    def get_doc(self, path, slug):
        """The anchor read, canned as DIR/paper-<slug>.http. A fixture with no
        such file models a Paper the server does not serve -- which must fail
        closed, not default."""
        path_i = os.path.join(self.dir, "paper-%s.http" % slug)
        if not os.path.exists(path_i):
            die(EXIT_FAIL_CLOSED,
                "fixture has no %s: the anchor Paper could not be resolved, and an "
                "unresolvable anchor is never a default" % os.path.basename(path_i))
        return self._read(path_i)

    def _read(self, path_i):
        with open(path_i, "rb") as fh:
            raw = fh.read()
        head, _, body = raw.partition(b"\n")
        head = head.decode("utf-8", "replace").strip()
        if not head.upper().startswith("HTTP "):
            die(EXIT_USAGE, "malformed fixture %s: first line must be 'HTTP <status>'" % path_i)
        try:
            status = int(head.split()[1])
        except (IndexError, ValueError):
            die(EXIT_USAGE, "malformed fixture %s: unparsable status in %r" % (path_i, head))
        return status, body


# --- paged, shape-asserted read ----------------------------------------------


def fetch_page(transport, dataset, doctype, page_index, offset, limit, pace, retries):
    query = "limit=%d&offset=%d" % (limit, offset)
    path = "/v1/data/query/%s/%s" % (dataset, doctype)
    attempt = 0
    while True:
        status, body = transport.get(path, query, page_index, attempt)

        # CLAUSE 3, first half: the status decides, before the body is looked at.
        if status == 429:
            if attempt >= retries:
                die(EXIT_FAIL_CLOSED,
                    "HTTP 429 rate limited at offset %d after %d retries -- refusing "
                    "to treat a rate-limited response as an empty page" % (offset, attempt),
                    ["body: %s" % body[:200].decode("utf-8", "replace"),
                     "the body above is VALID JSON; a 'did it parse?' test reads it as data"])
            attempt += 1
            backoff = pace * (2 ** attempt) + 0.5
            print("pds-ledger-census: 429 at offset %d, backing off %.2fs (retry %d/%d)"
                  % (offset, backoff, attempt, retries), file=sys.stderr)
            time.sleep(backoff)
            continue
        if status < 200 or status >= 300:
            die(EXIT_FAIL_CLOSED,
                "HTTP %d at offset %d -- a non-2xx is never a leaf and never an "
                "empty page" % (status, offset),
                ["body: %s" % body[:300].decode("utf-8", "replace")])

        # CLAUSE 3, second half: 2xx is not enough, and neither is parseable JSON.
        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            die(EXIT_FAIL_CLOSED, "HTTP %d but unparseable body at offset %d: %s" % (status, offset, exc))
        if not isinstance(payload, dict):
            die(EXIT_FAIL_CLOSED,
                "HTTP %d but body is %s, not an object, at offset %d"
                % (status, type(payload).__name__, offset))
        if "result" not in payload or not isinstance(payload["result"], dict):
            die(EXIT_FAIL_CLOSED,
                "HTTP %d but no `result` object at offset %d -- this is the shape a "
                "/v1/tasks-style {\"ok\":false,\"reason\":...} failure takes, and it "
                "parses cleanly" % (status, offset),
                ["keys: %s" % sorted(payload.keys())[:12]])
        result = payload["result"]
        for key, kind in (("count", int), ("offset", int), ("limit", int), ("documents", list)):
            if key not in result or not isinstance(result[key], kind):
                die(EXIT_FAIL_CLOSED,
                    "HTTP %d but result.%s is missing or not %s at offset %d"
                    % (status, key, kind.__name__, offset),
                    ["result keys: %s" % sorted(result.keys())[:12]])

        docs = result["documents"]

        # CLAUSE 1: the server must have honoured the page it was ASKED for.
        if result["limit"] != limit:
            die(EXIT_FAIL_CLOSED,
                "server silently capped the page: asked limit=%d, echoed limit=%d at "
                "offset %d. An unpaginated read trusting its own request would report a "
                "SMALLER board and exit 0." % (limit, result["limit"], offset))
        if result["offset"] != offset:
            die(EXIT_FAIL_CLOSED,
                "server answered a different page: asked offset=%d, echoed offset=%d"
                % (offset, result["offset"]))
        if result["count"] != len(docs):
            die(EXIT_FAIL_CLOSED,
                "truncated page at offset %d: result.count=%d but %d documents were "
                "delivered" % (offset, result["count"], len(docs)))
        if len(docs) > limit:
            die(EXIT_FAIL_CLOSED,
                "incoherent page at offset %d: %d documents for limit=%d"
                % (offset, len(docs), limit))
        for doc in docs:
            if not isinstance(doc, dict) or not doc.get("_id"):
                die(EXIT_FAIL_CLOSED, "page at offset %d carries a row with no _id" % offset)

        time.sleep(pace)
        return docs


def read_corpus(transport, dataset, doctype, limit, pace, retries):
    """CLAUSE 1 + CLAUSE 4: explicit offsets, serial, paced, short page ends it."""
    by_id = {}
    pages = []
    offset = 0
    duplicates = []
    for page_index in range(MAX_PAGES):
        docs = fetch_page(transport, dataset, doctype, page_index, offset, limit, pace, retries)
        pages.append(len(docs))
        for doc in docs:
            doc_id = doc["_id"]
            if doc_id in by_id:
                duplicates.append(doc_id)
            by_id[doc_id] = doc
        if len(docs) < limit:
            break
        offset += limit
    else:
        die(EXIT_FAIL_CLOSED,
            "read did not terminate after %d pages of %d -- refusing to report a "
            "partial board" % (MAX_PAGES, limit))
    if not by_id:
        die(EXIT_FAIL_CLOSED,
            "empty population: zero %s rows. A census with nothing in it has not "
            "passed, it has failed to run." % doctype)
    return by_id, pages, duplicates


# --- closure ------------------------------------------------------------------


def build_closure(corpus, root, lens):
    """CLAUSE 2. `closure` is the transitive descendant set over parent_id.

    `children` is the one-level lens, present ONLY so the selftest can inject it
    and watch the fixpoint assertion below refuse it.
    """
    kids = defaultdict(list)
    for doc_id, doc in corpus.items():
        parent = doc.get("parent_id")
        if parent:
            kids[parent].append(doc_id)

    closure = []
    seen = set()
    depth_of = {}
    frontier = [(child, 1) for child in sorted(kids.get(root, []))]
    while frontier:
        node, depth = frontier.pop(0)
        if node in seen:
            continue
        seen.add(node)
        closure.append(node)
        depth_of[node] = depth
        if lens == "children":
            continue  # the undercounting lens, on purpose
        for child in sorted(kids.get(node, [])):
            if child not in seen:
                frontier.append((child, depth + 1))

    # THE FIXPOINT ASSERTION. Lens-independent, and the thing a classification
    # string cannot satisfy: if any row in the fully-paged corpus has a parent
    # inside the closure but is itself outside it, the walk did not finish.
    escaped = sorted(
        doc_id for doc_id, doc in corpus.items()
        if doc.get("parent_id") in seen and doc_id not in seen
    )
    if escaped:
        die(EXIT_FAIL_CLOSED,
            "closure is NOT closed under parent_id: %d row(s) have a parent inside "
            "the closure and sit outside it. The walk stopped early (a one-level "
            "`.children` lens does this on its first grandchild)." % len(escaped),
            ["lens=%s" % lens] + ["escaped: %s (parent %s)" % (e, corpus[e].get("parent_id"))
                                  for e in escaped[:8]])
    return closure, depth_of


# --- census -------------------------------------------------------------------


def reason_hash(text):
    return hashlib.sha256(" ".join(text.split()).encode("utf-8")).hexdigest()[:16]


def disposition_of(row):
    """The row's disposition, trimmed. Case is PRESERVED -- the split is data."""
    value = row.get("disposition")
    return value.strip() if isinstance(value, str) else ""


def reason_of(row):
    value = row.get("disposition_reason")
    return value.strip() if isinstance(value, str) else ""


def structured_trigger(row):
    """CLAUSE 4(c)'s ONLY source of truth: the `reopen_trigger` FIELD.

    Never REOPEN_TRIGGER_RE, never the reason text. A trigger a script cannot
    read is not a trigger, and counting prose as one is the decoration PDS-D336(b)
    condemns by name.
    """
    value = row.get("reopen_trigger")
    return value.strip() if isinstance(value, str) else ""


def parse_instant(value):
    if not isinstance(value, str):
        return None
    raw = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def resolve_anchor_from_paper(transport, dataset, slug):
    """THE ROUND ANCHOR, DERIVED. The wave Paper's `_createdAt` IS the instant
    the round was born, and it is the only anchor a certifying run may use.

    Fails closed on every step -- a non-2xx, a body that is not the asserted
    shape, a missing or unreadable `_createdAt`. There is deliberately NO
    fallback: an anchor at now() excuses every row the round just filed, which
    is the exact vacuous green clause 4 exists to make impossible.
    """
    path = "/v1/data/doc/%s/paper/%s" % (dataset, slug)
    status, body = transport.get_doc(path, slug)
    if status < 200 or status >= 300:
        die(EXIT_FAIL_CLOSED,
            "HTTP %d resolving the anchor Paper `%s` -- refusing to fall back to "
            "now(), which would excuse every row this round filed" % (status, slug),
            ["GET %s" % path,
             "body: %s" % body[:300].decode("utf-8", "replace")])
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        die(EXIT_FAIL_CLOSED, "HTTP %d but unparseable body resolving anchor Paper `%s`: %s"
            % (status, slug, exc))
    result = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(result, dict):
        die(EXIT_FAIL_CLOSED,
            "HTTP %d but no `result` object resolving anchor Paper `%s` -- this is "
            "the shape a cleanly-parsing failure envelope takes" % (status, slug))
    raw = result.get("_createdAt")
    born = parse_instant(raw)
    if born is None:
        die(EXIT_FAIL_CLOSED,
            "anchor Paper `%s` has a missing or unreadable _createdAt %r -- an "
            "anchor that cannot be read is not an anchor" % (slug, raw))
    return born, raw


def census(corpus, closure, depth_of, started, finished, duplicates, anchor=None):
    rows = [corpus[i] for i in closure]
    lifecycle = Counter((r.get("lifecycle_status") or "<unset>") for r in rows)
    live = [r for r in rows if (r.get("lifecycle_status") or "") not in TERMINAL_LIFECYCLE]
    dispositions = Counter()
    for row in rows:
        value = row.get("disposition")
        dispositions[value if isinstance(value, str) and value else "<unset>"] += 1

    reasons = []
    triggers_structured = 0
    triggers_prose_only = 0
    for row in rows:
        structured = structured_trigger(row)
        if structured:
            triggers_structured += 1
        reason = reason_of(row)
        if reason:
            reasons.append(reason)
            # NEVER an `or` with the structured field, and never summed with it:
            # this counts DECORATION, so it is reported beside the real number.
            if not structured and REOPEN_TRIGGER_RE.search(reason):
                triggers_prose_only += 1
    hashes = {reason_hash(r) for r in reasons}

    # CLAUSE 4: live coverage. Row-ID LISTS, not counts -- a shard consumes the
    # worklist, and a count nobody can turn back into rows is not a worklist.
    #
    # 4(a) IS THE ONE ROUND-ANCHORED LINE, and this is the ONE place the anchor
    # enters (PDS-D364/D365). A row born AFTER the round started cannot have been
    # adjudicated by it, so it is the NEXT round's inbox -- named, never merely
    # counted. Everything else here, including 4(b) and 4(c), stays whole-live: a
    # row that HAS a disposition owes a reason regardless of when it was born.
    # With no anchor, `residue` is empty and 4(a) is exactly what wave 25 shipped.
    live_bare_rows = [r for r in live if not disposition_of(r)]
    live_bare_residue = []
    if anchor is not None:
        in_round = []
        for row in live_bare_rows:
            raw = row.get("_createdAt")
            born = parse_instant(raw)
            if born is None:
                # FAIL CLOSED, exactly as clause 5 does for _updatedAt: a row the
                # predicate cannot place on either side of the anchor must never
                # be silently excused into the residue.
                die(EXIT_FAIL_CLOSED,
                    "live row %s has a missing or unreadable _createdAt %r -- the "
                    "round-anchored predicate cannot place it before or after the "
                    "anchor, and a row it cannot place is never excused" % (row["_id"], raw))
            (in_round if born <= anchor else live_bare_residue).append(row)
        live_bare_rows = in_round
    live_bare = sorted(r["_id"] for r in live_bare_rows)
    live_bare_residue = sorted(r["_id"] for r in live_bare_residue)
    live_adjudicated = [r for r in live if disposition_of(r)]
    live_adjudicated_no_reason = sorted(r["_id"] for r in live_adjudicated if not reason_of(r))
    live_parked = [r for r in live if disposition_of(r).lower() == PARKED_DISPOSITION]
    live_park_no_trigger = sorted(r["_id"] for r in live_parked if not structured_trigger(r))

    off_vocab = Counter()
    off_vocab_samples = defaultdict(list)
    for row in rows:
        value = row.get("disposition")
        if isinstance(value, str) and value and value not in DISPOSITION_VOCABULARY:
            off_vocab[value] += 1
            if len(off_vocab_samples[value]) < 3:
                off_vocab_samples[value].append(row["_id"])

    # CLAUSE 5: a row that moved inside the window makes this an average.
    drifted = []
    for row in rows:
        raw = row.get("_updatedAt")
        if raw is None:
            die(EXIT_FAIL_CLOSED,
                "row %s carries no _updatedAt -- coherence of the named window "
                "cannot be asserted, so nothing here is a snapshot" % row["_id"])
        moved = parse_instant(raw)
        if moved is None:
            die(EXIT_FAIL_CLOSED,
                "row %s has an unreadable _updatedAt %r -- an unparsable timestamp "
                "must never be silently read as 'did not move'" % (row["_id"], raw))
        if started <= moved <= finished:
            drifted.append((row["_id"], raw))

    return {
        "instant": {
            "started": started.isoformat().replace("+00:00", "Z"),
            "finished": finished.isoformat().replace("+00:00", "Z"),
            "seconds": round((finished - started).total_seconds(), 2),
        },
        "closure_size": len(rows),
        "max_depth": max(depth_of.values()) if depth_of else 0,
        "live": len(live),
        "lifecycle": dict(lifecycle),
        "dispositions": dict(dispositions),
        "reasons_non_empty": len(reasons),
        "reason_hashes_distinct": len(hashes),
        "reopen_triggers_structured": triggers_structured,
        "reopen_triggers_prose_only": triggers_prose_only,
        "live_adjudicated": len(live_adjudicated),
        "live_parked": len(live_parked),
        "live_bare": live_bare,
        "live_bare_residue": live_bare_residue,
        "live_adjudicated_no_reason": live_adjudicated_no_reason,
        "live_park_no_trigger": live_park_no_trigger,
        "off_vocabulary": dict(off_vocab),
        "off_vocabulary_samples": {k: v for k, v in off_vocab_samples.items()},
        "off_vocabulary_total": sum(off_vocab.values()),
        "drifted": drifted,
        "duplicates": sorted(set(duplicates)),
    }


def _eg(ids, limit=3):
    """A count nobody can turn back into rows is not a worklist."""
    if not ids:
        return ""
    tail = ", ..." if len(ids) > limit else ""
    return "   e.g. %s%s" % (", ".join(ids[:limit]), tail)


def render(report, corpus_size, pages, page_limit, source, root, lens):
    out = []
    out.append("PDS LEDGER CENSUS")
    out.append("  instant     %s -> %s  (%.2fs)"
               % (report["instant"]["started"], report["instant"]["finished"],
                  report["instant"]["seconds"]))
    out.append("  source      %s" % source)
    out.append("  root        %s" % root)
    if report.get("round_anchor"):
        out.append("  round       born %s  (anchor: %s)"
                   % (report["round_anchor"], report["round_anchor_source"]))
    out.append("  paging      %d page(s) of limit %d -> corpus %d rows  (page sizes: %s)"
               % (len(pages), page_limit, corpus_size, ", ".join(str(p) for p in pages)))
    out.append("  closure     %d descendants over parent_id (lens=%s, max depth %d)"
               % (report["closure_size"], lens, report["max_depth"]))
    out.append("  live        %d  (terminal: %s)" % (report["live"], ", ".join(TERMINAL_LIFECYCLE)))
    out.append("")
    out.append("lifecycle_status (closure, case-exact)")
    for key, count in sorted(report["lifecycle"].items(), key=lambda kv: (-kv[1], kv[0])):
        out.append("  %-16s %5d" % (key, count))
    out.append("")
    out.append("disposition (closure, CASE-EXACT -- `%s` and `%s` are different values)"
               % (CANONICAL_OPEN, CANONICAL_OPEN.upper()))
    for key, count in sorted(report["dispositions"].items(), key=lambda kv: (-kv[1], kv[0])):
        out.append("  %-16s %5d" % (key, count))
    out.append("")
    out.append("disposition_reason")
    out.append("  non-empty                   %5d" % report["reasons_non_empty"])
    out.append("  distinct reason hashes      %5d" % report["reason_hashes_distinct"])
    out.append("  carrying a reopen trigger   %5d   (structured `reopen_trigger` field ONLY)"
               % report["reopen_triggers_structured"])
    out.append("  prose-only REOPEN mention   %5d   (DECORATION -- NEVER summed with the line above)"
               % report["reopen_triggers_prose_only"])
    out.append("")
    out.append("live coverage (LIVE rows only -- the round's own worklist)")
    out.append("  live rows                          %5d" % report["live"])
    out.append("  live rows with NO disposition      %5d%s"
               % (len(report["live_bare"]), _eg(report["live_bare"])))
    if report.get("round_anchor"):
        out.append("  ^ born after the anchor (RESIDUE)  %5d%s"
                   % (len(report["live_bare_residue"]), _eg(report["live_bare_residue"])))
    out.append("  live adjudicated with NO reason    %5d   (of %d adjudicated)%s"
               % (len(report["live_adjudicated_no_reason"]), report["live_adjudicated"],
                  _eg(report["live_adjudicated_no_reason"])))
    out.append("  live parked with NO reopen_trigger %5d   (of %d parked)%s"
               % (len(report["live_park_no_trigger"]), report["live_parked"],
                  _eg(report["live_park_no_trigger"])))
    out.append("")
    out.append("off-vocabulary disposition values (vocabulary: %s)"
               % ", ".join(DISPOSITION_VOCABULARY))
    if report["off_vocabulary"]:
        for key, count in sorted(report["off_vocabulary"].items(), key=lambda kv: (-kv[1], kv[0])):
            out.append("  %-16s %5d   e.g. %s"
                       % (key, count, ", ".join(report["off_vocabulary_samples"].get(key, []))))
    else:
        out.append("  (none)")
    return "\n".join(out)


def main(argv):
    parser = argparse.ArgumentParser(add_help=True, prog="pds-ledger-census.sh")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--dataset", default="production")
    parser.add_argument("--type", dest="doctype", default="task")
    parser.add_argument("--page-limit", type=int, default=DEFAULT_PAGE_LIMIT)
    parser.add_argument("--pace", type=float, default=DEFAULT_PACE_SECONDS)
    parser.add_argument("--retries", type=int, default=DEFAULT_RETRIES)
    parser.add_argument("--lens", choices=("closure", "children"), default="closure",
                        help="closure = transitive over parent_id. `children` is the "
                             "one-level undercounting lens, present only so the "
                             "selftest can inject it.")
    parser.add_argument("--assert-round-done", action="store_true")
    parser.add_argument("--anchor-from-paper", metavar="WAVE-PAPER-SLUG",
                        help="derive the round anchor from the wave Paper's "
                             "_createdAt. Clause 4(a) then asserts only over live "
                             "rows born at or before it; rows born after it are "
                             "named as residue.")
    parser.add_argument("--anchor", metavar="ISO-8601",
                        help="SELFTEST CLOCK ONLY -- refused outside --fixture-dir, "
                             "because a caller-supplied anchor lets a round seal "
                             "itself by argv.")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--fixture-dir")
    parser.add_argument("--server")
    parser.add_argument("--token")
    args = parser.parse_args(argv)

    if args.page_limit < 1:
        die(EXIT_USAGE, "--page-limit must be >= 1")
    if args.pace < 0 or args.retries < 0:
        die(EXIT_USAGE, "--pace and --retries must be >= 0")

    # THE ANCHOR GUARD. A raw --anchor is the selftest's clock and nothing else:
    # on the live board `--anchor 2020-01-01T00:00:00Z` flips 4(a) from 157/172
    # FAIL to 172/172 PASS, so a certifying run that could accept one could seal
    # itself by argv.
    if args.anchor and not args.fixture_dir:
        die(EXIT_USAGE,
            "--anchor is refused outside --fixture-dir: a caller-supplied anchor "
            "lets a round seal itself by argv (measured: --anchor 2020-01-01 flips "
            "clause 4(a) from 157/172 FAIL to 172/172 PASS on the live board). Use "
            "--anchor-from-paper <wave-slug>, which derives the instant.")
    if args.anchor and args.anchor_from_paper:
        die(EXIT_USAGE, "--anchor and --anchor-from-paper are mutually exclusive")

    if args.fixture_dir:
        if not os.path.isdir(args.fixture_dir):
            die(EXIT_USAGE, "--fixture-dir %s is not a directory" % args.fixture_dir)
        transport = FixtureTransport(args.fixture_dir)
    else:
        server = args.server or os.environ.get("BARKPARK_SERVER")
        token = args.token or os.environ.get("BARKPARK_TOKEN")
        if not server or not token:
            config = os.path.expanduser("~/.config/barkpark/config.json")
            if os.path.exists(config):
                with open(config) as fh:
                    data = json.load(fh)
                server = server or data.get("server")
                token = token or data.get("token")
        if not server or not token:
            die(EXIT_USAGE,
                "no server/token: pass --server/--token, set BARKPARK_SERVER/"
                "BARKPARK_TOKEN, or run `bp login`")
        transport = HttpTransport(server, token)

    # THE ANCHOR IS RESOLVED BEFORE THE READ WINDOW OPENS, so it can never be
    # mistaken for part of the snapshot clause 5 asserts coherence over.
    anchor = None
    anchor_source = None
    if args.anchor_from_paper:
        anchor, anchor_raw = resolve_anchor_from_paper(
            transport, args.dataset, args.anchor_from_paper)
        anchor_source = "paper/%s _createdAt %s" % (args.anchor_from_paper, anchor_raw)
    elif args.anchor:
        anchor = parse_instant(args.anchor)
        if anchor is None:
            die(EXIT_USAGE, "--anchor %r is not an ISO-8601 instant" % args.anchor)
        anchor_source = "--anchor (fixture clock)"

    # CLAUSE 5: the window is named before the first byte is read.
    started = datetime.now(timezone.utc)
    corpus, pages, duplicates = read_corpus(
        transport, args.dataset, args.doctype, args.page_limit, args.pace, args.retries)
    finished = datetime.now(timezone.utc)

    if args.root not in corpus:
        die(EXIT_FAIL_CLOSED,
            "root %s is not in the %d-row corpus -- refusing to census an empty "
            "closure under a root that does not exist" % (args.root, len(corpus)))

    closure, depth_of = build_closure(corpus, args.root, args.lens)
    if not closure:
        die(EXIT_FAIL_CLOSED,
            "root %s has zero descendants in a %d-row corpus" % (args.root, len(corpus)))

    report = census(corpus, closure, depth_of, started, finished, duplicates, anchor)
    report["round_anchor"] = (
        anchor.isoformat().replace("+00:00", "Z") if anchor is not None else None)
    report["round_anchor_source"] = anchor_source
    report["root"] = args.root
    report["lens"] = args.lens
    report["corpus_size"] = len(corpus)
    report["pages"] = pages
    report["page_limit"] = args.page_limit
    report["source"] = transport.describe()

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render(report, len(corpus), pages, args.page_limit,
                     transport.describe(), args.root, args.lens))

    # CLAUSE 5 verdict: report first, THEN refuse to call an average a snapshot.
    if report["duplicates"]:
        die(EXIT_INCOHERENT,
            "%d row(s) were served on more than one page -- the corpus shifted "
            "under pagination" % len(report["duplicates"]),
            report["duplicates"][:8])
    if report["drifted"]:
        die(EXIT_INCOHERENT,
            "%d row(s) in the closure were updated INSIDE the named window "
            "%s -> %s. This is an average, not a snapshot. Re-run."
            % (len(report["drifted"]), report["instant"]["started"],
               report["instant"]["finished"]),
            ["%s updated %s" % (i, t) for i, t in report["drifted"][:8]])

    if args.assert_round_done:
        distinct = report["reason_hashes_distinct"]
        non_empty = report["reasons_non_empty"]
        off_vocab = report["off_vocabulary_total"]
        failures = []
        print("")
        print("ROUND-DONE PREDICATE")
        print("  distinct reason hashes == non-empty reasons   %d == %d   %s"
              % (distinct, non_empty, "PASS" if distinct == non_empty else "FAIL"))
        if distinct != non_empty:
            failures.append("%d duplicate reason(s): %d non-empty reasons collapse to %d "
                            "hashes -- boilerplate is not a reason"
                            % (non_empty - distinct, non_empty, distinct))
        print("  non-empty reasons > 0                          %d        %s"
              % (non_empty, "PASS" if non_empty > 0 else "FAIL"))
        if non_empty == 0:
            failures.append("zero non-empty reasons -- an all-empty board trivially has "
                            "all-distinct reasons; that is not done, it is unstarted")
        print("  off-vocabulary dispositions == 0               %d        %s"
              % (off_vocab, "PASS" if off_vocab == 0 else "FAIL"))
        if off_vocab:
            failures.append("%d row(s) carry a disposition outside {%s} (canonical OPEN "
                            "case is `%s`)" % (off_vocab, ", ".join(DISPOSITION_VOCABULARY),
                                               CANONICAL_OPEN))

        # CLAUSE 4 -- the ONLY live-scoped clause. Clauses 1-3 above stay
        # closure-scoped on purpose: distinctness and vocabulary are properties
        # of everything ever written. Three sub-lines, each able to say no alone.
        bare = report["live_bare"]
        residue = report["live_bare_residue"]
        no_reason = report["live_adjudicated_no_reason"]
        no_trigger = report["live_park_no_trigger"]
        if report["round_anchor"]:
            print("  round anchor                                  %s   (%s)"
                  % (report["round_anchor"], report["round_anchor_source"]))
        print("  live rows carrying a disposition               %d/%d    %s"
              % (report["live"] - len(bare), report["live"], "PASS" if not bare else "FAIL"))
        if report["round_anchor"]:
            # A NAMED WORKLIST, NEVER A BARE COUNT: these rows were born after the
            # round started, so they are the NEXT round's inbox -- deferred by
            # exactly one round, and in scope the moment it anchors on its own
            # Paper.
            print("  ^ deferred to the next round (RESIDUE)        %d        %s"
                  % (len(residue), "next-round inbox"))
            for row_id in residue:
                print("      residue: %s" % row_id)
        if bare:
            failures.append("%d LIVE row(s) carry NO disposition -- a live row that says "
                            "nothing is what clauses 1-3 cannot see: %s"
                            % (len(bare), ", ".join(bare[:8]) + (", ..." if len(bare) > 8 else "")))
        print("  live adjudicated rows carrying a reason        %d/%d    %s"
              % (report["live_adjudicated"] - len(no_reason), report["live_adjudicated"],
                 "PASS" if not no_reason else "FAIL"))
        if no_reason:
            failures.append("%d LIVE adjudicated row(s) carry NO disposition_reason -- a "
                            "verdict with no reason is unprovable: %s"
                            % (len(no_reason),
                               ", ".join(no_reason[:8]) + (", ..." if len(no_reason) > 8 else "")))
        print("  live parked rows carrying a reopen_trigger     %d/%d    %s   (STRUCTURED field, not prose)"
              % (report["live_parked"] - len(no_trigger), report["live_parked"],
                 "PASS" if not no_trigger else "FAIL"))
        if no_trigger:
            failures.append("%d LIVE parked row(s) carry NO structured reopen_trigger (prose "
                            "that merely mentions REOPEN is decoration, PDS-D336(b)): %s"
                            % (len(no_trigger),
                               ", ".join(no_trigger[:8]) + (", ..." if len(no_trigger) > 8 else "")))

        if failures:
            print("")
            print("VERDICT: ROUND NOT DONE", file=sys.stderr)
            for failure in failures:
                print("  - %s" % failure, file=sys.stderr)
            sys.exit(EXIT_ROUND_NOT_DONE)
        print("")
        print("VERDICT: ROUND DONE")
        return EXIT_OK

    print("")
    print("VERDICT: census complete and coherent")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
