#!/usr/bin/env python3
"""doc-drift-extract.py — the PROSE-vs-CODE split doc-drift-check.sh depends on.

Reads one markdown file, writes one `KIND\tLINE\tPAYLOAD` record per finding
candidate to stdout.  KIND is `link` or `placeholder`.

WHY THIS IS NOT A GREP.  The first version of this gate greped the raw file and
produced 14 findings on main, 13 of them FALSE: every one sat inside a fenced
block or an inline code span, i.e. inside text that is being QUOTED rather than
asserted.  `[text](url)` in a sentence describing markdown syntax is not a
broken link; `<warning ref="xxx">` in an XML sample is not an exposed
placeholder.  A line-oriented grep cannot tell prose from a quotation, so the
split is done here, once, and both checks read the same answer.
"""
import re
import sys

PLACEHOLDER = re.compile(
    r"(^|[^A-Za-z0-9_-])(FIXME|TBD|TODO:|lorem ipsum|<PLACEHOLDER>|REPLACE[-_]ME)([^A-Za-z0-9_-]|$)",
    re.IGNORECASE,
)
INLINE_LINK = re.compile(r"\]\(([^)\s]+)\)")
# `[^id]: text` is a FOOTNOTE definition, not a reference link — its body is
# prose, and reading it as a target invented 8 of the 14 findings on main.
REF_LINK = re.compile(r"^\[(?!\^)[^\]]+\]:\s+(\S+)")
CODE_SPAN = re.compile(r"`[^`]*`")


def main() -> int:
    path = sys.argv[1]
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    in_fence = False
    fence_marker = ""
    for idx, raw in enumerate(lines, start=1):
        stripped = raw.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            marker = stripped[:3]
            if not in_fence:
                in_fence, fence_marker = True, marker
            elif marker == fence_marker:
                in_fence = False
            continue
        if in_fence:
            continue
        # Inline code spans are quotations too — strip them before judging.
        prose = CODE_SPAN.sub("", raw)
        for m in INLINE_LINK.finditer(prose):
            print("link\t%d\t%s" % (idx, m.group(1)))
        m = REF_LINK.match(prose)
        if m:
            print("link\t%d\t%s" % (idx, m.group(1)))
        if PLACEHOLDER.search(prose):
            print("placeholder\t%d\t%s" % (idx, prose.strip()[:80]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
