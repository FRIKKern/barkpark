<!-- doc-tier: cold | canonical-for: legendary-paper-survey-15-evidence | budget: 1200tok -->
# Survey 15 — wave 29 / CLI and API semantic parity

Verdict: `partial`. Machine JSON is exact, but the human terminal reader loses table headers and list bodies and omits durable identity and plain-text semantics.

- Authority: revision `18768b0a14c2eead927181c4a0e37c18`; canonical API-result SHA-256 `d5ca959bca06279251a2e2e498a6979efcbdb24ffcfdbe423f2ba26e60cb6e81`; canonical block-tree SHA-256 `46ed01f7416f064f950cee3b00f1a59da00cd0cef523b2a6e4cf1e7cee4b1a50`.
- Document API, source API, `bp doc get -o json`, and `bp paper view -o json` agree exactly on all 252 blocks.
- Human rendering loses all 35 header cells because the source uses `header` while `internal/pdrender/richblocks.go` reads only `head`.
- Eleven paragraph-wrapped list items become bullet-only rows, losing 2,268 characters. The inline fallback reads `children`, not paragraph `content`.
- The source contains 313 marked nodes / 8,508 characters. ANSI profiles style them, but profile `none` has no textual strong/code fallback, so piped text loses those distinctions.
- Four callouts retain their bodies, but profile `none` renders warning/info/note with identical textual chrome.
- Machine projections retain all unique IDs and the revision. Human output exposes neither. There are 49 case-folding ID pairs (`w29d...` versus `w29D...`), a future anchor/index risk rather than a proven current collision.
- The source has no typed task-reference nodes. Of 20 task-like prose strings, 18 resolve and two do not; prose names cannot provide durable Paper-to-task traversal.
- Width 60/80/120 bounds are exact; width 80 is 1,440 lines / 126,556 bytes.

Browser, Studio, email, TUI, release-gate reads, screen readers, clipboard round-trips, and exhaustive body-cell text comparison remain unvisited. No state mutation occurred.
