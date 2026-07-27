#!/usr/bin/env python3
"""THE EMULATOR ORACLE (charter D51) — the mechanical on-device proof that the
native reader renders every registered PortableDoc type.

WHAT IS AND IS NOT THE EVIDENCE. The evidence of record is one grep: an
on-device `uiautomator dump` of the paged crown paper must contain ZERO
occurrences of the degrade box the dispatcher paints for a type it does not
recognise. Screenshots are artifacts for a human to look at afterwards; they
prove nothing on their own, because nobody diffs a PNG against an expectation.
The jest crown floor already covers the same corpus in-process — this run adds
the one thing jest cannot: that the renderers survive a RELEASE build, on a real
Android runtime, with Hermes and the production Metro bundle instead of the
babel-jest transform.

TWO TRAPS THIS SCRIPT REFUSES TO FALL INTO.

  1. Believing it navigated. Hard-coded tap coordinates are AVD-specific, and a
     tap that lands on nothing leaves you dumping the PREVIOUS screen — which
     contains no unknown-block box either, so the oracle reports a triumphant
     zero for a page it never opened. Every tap here resolves its target's
     bounds from the live view hierarchy BY TEXT, and the paper's own title must
     appear on screen before a single dump is counted.
  2. Trusting an unchanging dump. An unchanged dump after a swipe is genuinely
     what the end of the document looks like — but it is ALSO what a DROPPED
     GESTURE looks like, and what a frozen app looks like. The first run of this
     script stopped after one screen for exactly that reason (the same swipe
     replayed by hand scrolled fine), and had the guards below not existed it
     would have reported a clean zero for a 243-block paper it never scrolled.
     So: the end is only declared after TWO consecutive no-change swipes, the
     app must still be the focused window at the end, and a run that saw fewer
     screens than the document could possibly fit in FAILS rather than passes.

Usage:
    python3 apps/mobile/scripts/crown-oracle.py [--paper-title "..."] [--out DIR]

Exit 0 = zero unknown-block hits across the paged paper. Exit 1 = hits found, or
the run could not honestly prove it navigated. Never `adb emu kill` — the
emulator is a shared instance.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time

ADB = os.environ.get(
    "ADB", "/opt/homebrew/share/android-commandlinetools/platform-tools/adb"
)
PACKAGE = "cloud.barkpark.mobile"
ACTIVITY = f"{PACKAGE}/{PACKAGE}.MainActivity"

# The label registry.tsx's unknownBlock() paints. Kept as a split literal so this
# FILE never matches a grep for the sentinel either — the same collision that
# already produced one false positive in the crown paper itself.
SENTINEL = "Unsupported" + " block"

BOUNDS_RE = re.compile(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')


def adb(*args: str, timeout: int = 120) -> str:
    out = subprocess.run(
        [ADB, *args], capture_output=True, text=True, timeout=timeout
    )
    return out.stdout


def dump() -> str:
    """The current view hierarchy as XML. `exec-out` keeps it binary-clean."""
    for _ in range(3):
        xml = adb("exec-out", "uiautomator", "dump", "/dev/tty")
        if "<hierarchy" in xml or "<?xml" in xml:
            return xml
        time.sleep(1)
    return xml


def texts(xml: str) -> list[str]:
    return [t for t in re.findall(r'text="([^"]*)"', xml) if t]


def tap_text(xml: str, needle: str, *, exact: bool = False) -> bool:
    """Tap the centre of the first node whose text matches. Returns False when no
    node matches — the caller must treat that as a navigation failure rather than
    tapping a guessed coordinate."""
    for node in xml.split(">"):
        m = re.search(r'text="([^"]*)"', node)
        if not m:
            continue
        value = m.group(1)
        if (value == needle) if exact else (needle in value):
            b = BOUNDS_RE.search(node)
            if not b:
                continue
            x1, y1, x2, y2 = (int(g) for g in b.groups())
            adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
            return True
    return False


def focused_package() -> str:
    out = adb("shell", "dumpsys", "window")
    m = re.search(r"mCurrentFocus=Window\{[^}]*\s(\S+)/", out)
    return m.group(1) if m else ""


def wait_for_text(needle: str, *, timeout: int = 90) -> str:
    """Poll the hierarchy until `needle` appears, returning the dump that has it
    (or the last one tried). Fixed sleeps were the wrong instrument here: a cold
    start of a release build on a loaded host took longer than a 12 s wait more
    than once, and the run then reported "no Papers tab" about an app that was
    merely still starting. Polling makes the script slow when the host is busy
    instead of wrong."""
    deadline = time.time() + timeout
    xml = ""
    while time.time() < deadline:
        xml = dump()
        if needle in xml:
            return xml
        time.sleep(2)
    return xml


def screencap(path: str) -> None:
    with open(path, "wb") as fh:
        fh.write(
            subprocess.run(
                [ADB, "exec-out", "screencap", "-p"], capture_output=True, timeout=120
            ).stdout
        )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--paper-title",
        default="Mobile Crown Floor",
        help="substring of the crown paper's title, used both to find its row and to assert arrival",
    )
    ap.add_argument("--out", default="/tmp/crown-oracle")
    ap.add_argument("--max-pages", type=int, default=250)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    devices = [
        line.split()[0]
        for line in adb("devices").splitlines()[1:]
        if line.strip() and line.split()[-1] == "device"
    ]
    if not devices:
        print("FAIL: no adb device attached", file=sys.stderr)
        return 1
    print(f"device: {devices[0]}")

    print("launching the release build…")
    adb("shell", "am", "force-stop", PACKAGE)
    time.sleep(2)
    adb("shell", "am", "start", "-n", ACTIVITY)

    xml = wait_for_text("Papers")
    if not tap_text(xml, "Papers", exact=True):
        print(f"FAIL: no 'Papers' tab in the view hierarchy; saw {texts(xml)[:12]}", file=sys.stderr)
        return 1

    # The papers list is recency-ordered, so the freshly published crown paper is
    # row 1 — but the row is FOUND by title, never assumed to be at a position,
    # and the list is given time to fetch before that conclusion is drawn.
    xml = wait_for_text(args.paper_title)
    if not tap_text(xml, args.paper_title):
        print(
            f"FAIL: the crown paper row was not on the Papers list; saw {texts(xml)[:12]}",
            file=sys.stderr,
        )
        return 1

    # THE ARRIVAL ASSERTION (D51). Until the paper's own title is on screen IN
    # THE READER, a clean dump means nothing. The back-link text distinguishes the
    # reader from the list, which also carries the title.
    xml = wait_for_text("\u2039 Papers")
    if args.paper_title not in xml:
        print(
            f"FAIL: tapped the row but the reader never showed '{args.paper_title}' — "
            f"refusing to certify a page this run cannot prove it opened; saw {texts(xml)[:12]}",
            file=sys.stderr,
        )
        return 1
    print(f"arrived: '{args.paper_title}' is on screen — the dumps below are the real page")
    screencap(os.path.join(args.out, "page-000-top.png"))

    hits: list[str] = []
    seen_types: set[str] = set()
    previous = ""
    pages = 0
    stalls = 0
    for page in range(args.max_pages):
        xml = dump()
        if xml == previous:
            # One stall is more often a dropped gesture than the end of the
            # document; two in a row is the end. Costing one extra swipe here is
            # the difference between a proof and a coincidence.
            stalls += 1
            if stalls >= 2:
                break
            adb("shell", "input", "swipe", "540", "1600", "540", "700", "400")
            time.sleep(1.2)
            continue
        stalls = 0
        previous = xml
        pages += 1
        if SENTINEL in xml:
            for t in texts(xml):
                if SENTINEL in t:
                    hits.append(f"page {page}: {t}")
            screencap(os.path.join(args.out, f"page-{page:03d}-HIT.png"))
        # The h2 per section is the type name, so this doubles as a coverage
        # ledger: which sections the scroll actually reached.
        for t in texts(xml):
            if re.fullmatch(r"[a-z][a-z0-9-]{2,24}", t):
                seen_types.add(t)
        if page % 25 == 0:
            screencap(os.path.join(args.out, f"page-{page:03d}.png"))
        # Deliberately a measured drag, not a fling: a 220 ms sweep over 1400 px
        # was the parameter set that silently dropped its first gesture.
        adb("shell", "input", "swipe", "540", "1600", "540", "700", "400")
        time.sleep(1.0)

    screencap(os.path.join(args.out, "page-999-bottom.png"))
    still_focused = focused_package()

    print(f"paged {pages} screens; section labels observed: {len(seen_types)}")
    print(f"focused package at end: {still_focused or '(none)'}")
    print(f"artifacts: {args.out}")

    ok = True
    if still_focused != PACKAGE:
        print(
            f"FAIL: the app is no longer the focused window ({still_focused!r}) — it may have "
            "crashed mid-scroll, so an empty grep is not trustworthy",
            file=sys.stderr,
        )
        ok = False
    if pages < 3:
        print(
            f"FAIL: only {pages} distinct screens — a 243-block paper cannot fit in that, so the "
            "scroll did not actually traverse the document",
            file=sys.stderr,
        )
        ok = False
    if hits:
        print(f"FAIL: {len(hits)} unknown-block hit(s):", file=sys.stderr)
        for h in hits:
            print(f"  {h}", file=sys.stderr)
        ok = False

    print("ORACLE: PASS — zero unknown-block hits across the paged paper" if ok else "ORACLE: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
