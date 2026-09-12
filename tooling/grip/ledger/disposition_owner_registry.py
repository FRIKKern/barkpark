#!/usr/bin/env python3
"""disposition_owner, adjudicated against a registry instead of against emptiness.

WHY THIS FILE EXISTS. `disposition_owner` is a PDS ledger field with NO schema
field, NO validator and NO code writer anywhere in api/lib or internal/ (checked
by absence + control: the same string DOES occur in the charter, in
api/test/barkpark/content/disposition_trigger_gate_test.exs, in
pds-w25-shard-count.py and in tooling/pds/fixtures/, so the grep reaches the
right tree). The only thing any instrument asserted about it was
pds-w25-shard-count.py's

    if d == "open" and (not ow or ow == i): prob.append(...)

i.e. NON-EMPTY AND NOT SELF. That greens on every string a shard invents. It
greened on `truth-grip-epic lead (wave-10 steward)` (spaces and parentheses, 26
rows), on `lead-truthgrip` (24 rows pointing at a DIFFERENT epic's lead), on
`wave-24`/`wave-25` (owners that expire when their wave closes) and on three
literal task ids, one of which owned ITSELF. A non-empty check greening on a
name is the epic's own failure class, moved from the row to the vocabulary.

WHAT IT DOES. tooling/pds/disposition-owner-registry.json lists every slug the
board actually carries, each durable role with a one-line definition and a
resolution rule, and each refused slug with the reason and the remedy. This
module is the only reader, and it REFUSES rather than scoring non-emptiness.

ORDER OF ADJUDICATION IS LOAD-BEARING (classify()):
    1. empty                      -> UNOWNED
    2. shape violation            -> MALFORMED
    3. wave-N                     -> EXPIRING   (the ruling; see below)
    4. self-owner                 -> SELF
    5. not in roles[]             -> UNREGISTERED
    6. otherwise                  -> OK
wave-N is adjudicated BEFORE membership on purpose: the ruling is REFUSE, so a
wave-N slug stays refused even if someone lists it in roles[], and
lint_registry() reds on a registry that tries. That is what makes the ruling
ENFORCED rather than documented.

THE MUTATION ARM IS THE POINT. --selftest does not merely assert that a good
owner passes; for every refusal class it MUTATES ONE ROW to a garbage value and
requires the red, then restores it and requires the green. A registry check that
cannot be made to fail is the same vacuous green this epic exists to kill.

USE:
    python3 disposition_owner_registry.py --selftest   # no network, no credential
    python3 disposition_owner_registry.py --derive     # re-derive the slug tally
    python3 disposition_owner_registry.py --check      # verdict over the live board
"""

import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
REGISTRY_PATH = os.path.join(REPO, "tooling", "pds", "disposition-owner-registry.json")

SHAPE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
EXPIRING = re.compile(r"^wave-[0-9]+$")

OK = "OK"
UNOWNED = "UNOWNED"
MALFORMED = "MALFORMED"
EXPIRING_OWNER = "EXPIRING"
SELF = "SELF"
UNREGISTERED = "UNREGISTERED"

EXIT_WALK_REFUSED = 2


class RegistryError(Exception):
    """A registry that cannot be trusted. Never downgraded to a warning."""


def load_registry(path=REGISTRY_PATH):
    with open(path) as fh:
        reg = json.load(fh)
    lint_registry(reg)
    return reg


def role_slugs(reg):
    return {r["slug"] for r in reg["roles"]}


def lint_registry(reg):
    """The registry is itself checkable. A registry that lists an expiring or a
    malformed slug as a legal role would launder exactly what it is meant to
    refuse, so that is a REFUSAL of the file, not of a row."""
    if not isinstance(reg.get("roles"), list) or not reg["roles"]:
        raise RegistryError("registry has no roles[]")
    seen = set()
    for r in reg["roles"]:
        s = r.get("slug", "")
        if s in seen:
            raise RegistryError("registry lists %r twice" % s)
        seen.add(s)
        if not SHAPE.match(s):
            raise RegistryError("registry lists a malformed slug %r" % s)
        if EXPIRING.match(s):
            raise RegistryError(
                "registry lists the EXPIRING slug %r as a durable role -- the "
                "wave-N ruling is REFUSE, and listing one here would launder it" % s)
        for field in ("definition", "resolution"):
            if not str(r.get(field, "")).strip():
                raise RegistryError("role %r has no %s" % (s, field))
    for r in reg.get("refused", []):
        if r.get("slug") in seen:
            raise RegistryError("%r is listed as BOTH a role and refused" % r.get("slug"))
    return True


def classify(owner, row_id=None, reg=None):
    """(verdict, detail). The order of these arms is the contract; see the
    module docstring."""
    reg = reg if reg is not None else load_registry()
    ow = owner.strip() if isinstance(owner, str) else ""
    if not ow:
        return UNOWNED, "no disposition_owner"
    if not SHAPE.match(ow):
        return MALFORMED, "owner %r breaks the lowercase-kebab shape %s" % (ow, SHAPE.pattern)
    if EXPIRING.match(ow):
        return EXPIRING_OWNER, (
            "owner %r is a wave-N owner; the ruling is REFUSE (it self-clears at "
            "wave close and the row silently degrades to unowned)" % ow)
    if row_id is not None and ow == row_id:
        return SELF, "owner %r is the row itself" % ow
    if ow not in role_slugs(reg):
        return UNREGISTERED, (
            "owner %r is not in tooling/pds/disposition-owner-registry.json; a "
            "non-empty owner is not evidence of ownership" % ow)
    return OK, ow


def score_rows(rows, reg=None, only_open=True):
    """rows: {row_id: doc}. Returns (ok_count, bad) where bad is
    [(row_id, verdict, detail)]. Scores rows whose disposition is `open` by
    default -- a closed row's owner is history, a live row's owner is a claim."""
    reg = reg if reg is not None else load_registry()
    ok, bad = 0, []
    for rid, doc in sorted(rows.items()):
        d = doc.get("disposition")
        d = d.strip() if isinstance(d, str) else ""
        if only_open and d != "open":
            continue
        verdict, detail = classify(doc.get("disposition_owner"), rid, reg)
        if verdict == OK:
            ok += 1
        else:
            bad.append((rid, verdict, detail))
    return ok, bad


# ---------------------------------------------------------------- live board

def _walk():
    sys.path.insert(0, HERE)
    from census_walk import walk_pages, CensusWalkRefusal  # noqa: E402

    src = open(os.path.join(HERE, "pds-w25-shard-count.py")).read().split("if __name__")[0]
    ns = {"__name__": "shard_count_reused",
          "__file__": os.path.join(HERE, "pds-w25-shard-count.py")}
    exec(compile(src, "pds-w25-shard-count.py", "exec"), ns)  # noqa: S102
    srv, tok = ns["load_config"]()
    return walk_pages(ns["make_fetch"](srv, tok), 500), CensusWalkRefusal


def _walk_or_die():
    """NEVER a smaller board: a refused walk has no verdict at all."""
    try:
        res, _ = _walk()
    except Exception as exc:                                  # noqa: BLE001
        if type(exc).__name__ != "CensusWalkRefusal":
            raise
        print("WALK ABORT -- no board was read, so there is no verdict:\n%s" % exc,
              file=sys.stderr)
        sys.exit(EXIT_WALK_REFUSED)
    print("WALK pages=%d loaded=%d unique=%d terminated=%s"
          % (len(res.pages), sum(res.pages), len(res.rows), res.terminator))
    return res


def derive():
    res = _walk_or_die()
    reg = load_registry()
    known = role_slugs(reg)
    all_t, open_t, unowned = collections.Counter(), collections.Counter(), 0
    for rid, doc in res.rows.items():
        ow = doc.get("disposition_owner")
        ow = ow.strip() if isinstance(ow, str) else ""
        d = doc.get("disposition")
        d = d.strip() if isinstance(d, str) else ""
        if ow:
            all_t[ow] += 1
        if d == "open":
            if ow:
                open_t[ow] += 1
            else:
                unowned += 1
    print("distinct disposition_owner values board-wide: %d" % len(all_t))
    print("open rows carrying NO owner: %d" % unowned)
    print("%-6s %-6s %-14s %s" % ("OPEN", "ALL", "VERDICT", "SLUG"))
    for slug, n in all_t.most_common():
        verdict, _ = classify(slug, None, reg)
        print("%-6d %-6d %-14s %r" % (open_t.get(slug, 0), n, verdict, slug))
    missing = sorted(known - set(all_t))
    if missing:
        print("registered but carried by NO row today: %s" % ", ".join(missing))
    return 0


def check():
    res = _walk_or_die()
    reg = load_registry()
    ok, bad = score_rows(res.rows, reg)
    print("REGISTRY %d role(s); live-open rows scored: OK=%d REFUSED=%d"
          % (len(reg["roles"]), ok, len(bad)))
    for rid, verdict, detail in bad:          # EVERY failing row, never a head slice
        print("  REFUSED %-12s %-52s %s" % (verdict, rid, detail))
    return 0 if not bad else 1


# ------------------------------------------------------------------ selftest

def selftest():
    reg = load_registry()
    bad = []
    arms = [0]

    def arm(name, cond, got=""):
        arms[0] += 1
        print("  %-6s %-62s %s" % ("ok" if cond else "FAIL", name, got))
        if not cond:
            bad.append(name)

    print("disposition_owner_registry selftest (no network, no credential)")

    # --- the registry file itself ------------------------------------------
    arm("registry lints clean", lint_registry(reg) is True)
    arm("registry is DERIVED, and says from what",
        reg["derived_from_the_ledger"]["rows_walked"] > 1000
        and reg["derived_from_the_ledger"]["terminator"] == "hasMore=false",
        str(reg["derived_from_the_ledger"]["rows_walked"]))
    arm("every role carries a definition AND a resolution rule",
        all(r["definition"].strip() and r["resolution"].strip() for r in reg["roles"]),
        "%d roles" % len(reg["roles"]))
    arm("the wave-N ruling is present and is REFUSE",
        reg["expiring_owner_ruling"]["ruling"].startswith("REFUSED"))

    # --- MUTATION: the registry may not launder what it refuses ------------
    mutant = json.loads(json.dumps(reg))
    mutant["roles"].append({"slug": "wave-99", "definition": "d", "resolution": "r"})
    try:
        lint_registry(mutant)
        arm("MUTATION: registry listing wave-99 as a role -> RED", False, "lint accepted it")
    except RegistryError as exc:
        arm("MUTATION: registry listing wave-99 as a role -> RED", "EXPIRING" in str(exc),
            str(exc)[:70])
    mutant2 = json.loads(json.dumps(reg))
    mutant2["roles"].append({"slug": "Not A Slug", "definition": "d", "resolution": "r"})
    try:
        lint_registry(mutant2)
        arm("MUTATION: registry listing a malformed slug -> RED", False, "lint accepted it")
    except RegistryError as exc:
        arm("MUTATION: registry listing a malformed slug -> RED", "malformed" in str(exc),
            str(exc)[:70])

    # --- CONTROL: a registered owner passes --------------------------------
    good = reg["roles"][0]["slug"]
    arm("CONTROL: a registered owner passes", classify(good, "some-row", reg)[0] == OK, good)

    # --- the row-level mutation the criterion demands -----------------------
    # ONE row, carried through the FULL scorer (not classify() in isolation),
    # mutated to a garbage slug and required to red, then restored and required
    # to green. Command byte-identical either side; only the claim changes.
    def row(owner):
        return {"r1": {"disposition": "open", "disposition_reason": "why",
                       "disposition_owner": owner}}

    ok_n, bad_rows = score_rows(row(good), reg)
    arm("CONTROL: scorer greens on the clean row", ok_n == 1 and not bad_rows,
        "ok=%d bad=%d" % (ok_n, len(bad_rows)))

    for label, owner, want in [
            ("garbage slug", "totally-made-up-owner", UNREGISTERED),
            ("expiring wave-25", "wave-25", EXPIRING_OWNER),
            ("prose with spaces", "truth-grip-epic lead (wave-10 steward)", MALFORMED),
            ("foreign epic lead", "lead-truthgrip", UNREGISTERED),
            ("task id as owner", "pds-w25-round-terminal", UNREGISTERED),
            ("empty owner", "   ", UNOWNED)]:
        ok_n, bad_rows = score_rows(row(owner), reg)
        got = bad_rows[0][1] if bad_rows else "GREEN"
        arm("MUTATION: %-20s -> %s" % (label, want), ok_n == 0 and got == want, got)

    # self-ownership needs the row id, so it gets its own arm
    ok_n, bad_rows = score_rows({"pds-self": {"disposition": "open",
                                              "disposition_owner": "pds-self"}}, reg)
    arm("MUTATION: row owned BY ITSELF -> SELF",
        ok_n == 0 and bad_rows and bad_rows[0][1] == SELF,
        bad_rows[0][1] if bad_rows else "GREEN")

    # --- RESTORE: the same scorer greens again ------------------------------
    ok_n, bad_rows = score_rows(row(good), reg)
    arm("RESTORE: scorer greens again after the mutations", ok_n == 1 and not bad_rows)

    # --- a closed row's owner is history, not a claim -----------------------
    ok_n, bad_rows = score_rows({"r1": {"disposition": "closed",
                                        "disposition_owner": "wave-25"}}, reg)
    arm("SCOPE: a CLOSED row's wave-N owner is not scored", ok_n == 0 and not bad_rows)

    # The count is PRINTED and floored: a file that loses arms to a bad edit
    # must not be able to report a spotless green over a shrunken suite.
    print("disposition_owner_registry selftest: %d arms, %d failures"
          % (arms[0], len(bad)))
    if arms[0] < 17:
        print("  FAIL   the suite SHRANK: %d arms, floor is 17" % arms[0])
        return 1
    return 1 if bad else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--derive" in argv:
        return derive()
    if "--check" in argv:
        return check()
    print(__doc__.strip().splitlines()[-4:][0], file=sys.stderr)
    print("usage: disposition_owner_registry.py --selftest | --derive | --check",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
