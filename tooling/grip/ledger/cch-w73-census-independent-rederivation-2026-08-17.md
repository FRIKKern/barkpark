<!-- doc-tier: cold | canonical-for: cch-w73-census-independent-rederivation | budget: 1400tok -->

# cch-w73 census — INDEPENDENT re-derivation of Side A / Side B (fresh extractor)

Verifier `census-counts-independent`, wave 73, against `origin/main`
(83fe72c3, HEAD at run; the digest's e085a927 gives the SAME Side-B count).
A second implementation of D867's rule, written from scratch — NOT the
surveyor's `census.py`. Purpose: prove the guard's build-time denominator/
numerator are reproducible before the guard is committed.

## Result: 171 minted / 59 read / 112 unread — MATCHES the assignment's 171/59/112

Side A decomposition reproduces D867 exactly:
- `error:` string-key literals (comment-stripped) = 161
- `code:` string-key literals (comment-stripped) = 17
- codes UNIQUE to `code:` = 10, byte-identical to D867's list:
  already_running, capability_unavailable, identity_refused, instance_error,
  instance_unavailable, not_supported, pinned, runner_start_failed,
  upstream_error, webhook_gone
- UNION (minted) = 171

Side B (quoted-literal reader scan of app.js) = 59 read, 112 unread.
Phantom verdicts reproduce: expired_or_invalid UNREAD, instance_unavailable
READ, provision_failed READ. Side-B was ALREADY 59 at e085a927 (old app.js
== new app.js read-set, diff empty) — so the +4 over D867's pinned 55 predates
this HEAD; Side A unchanged at 171.

## Re-run recipe (fresh extractor, ~40 lines)

Dump the three files from origin/main, then run a comment-stripper that respects
Elixir string/heredoc/charlist/`?x` state and JS string/template/`//`/`/* */`
state, then:
- Side A: `\b(error|code):\s*"([a-z0-9_]+)"` over stripped router.ex + auth.ex, union.
- Side B: for each minted slug, READ iff `"slug"` or `'slug'` occurs on any
  comment-stripped app.js line (per-code, per-line — whole-file scans desync).

Extractor kept at (scratchpad, not committed):
`scratchpad/census.*/extract.py`. Any faithful re-impl of the two strippers
reproduces 171/59/112.

## LOAD-BEARING FINDING for the guard: 13 minted ERRORS keys are INVISIBLE to Side B

D867 asserts Side B "subsumes ERRORS object keys (friendly's ERRORS[key])".
This is TEXTUALLY FALSE. Every key in `var ERRORS = { ... }` (app.js:179) is a
BARE identifier (`checkout_failed: "..."`, not `"checkout_failed": "..."`), so
the quoted-literal scan never matches them. A minted ERRORS key counts as READ
ONLY if the same slug ALSO appears quoted at another site (a `case "x":` arm or
`x === "y"`). 13 minted codes are ERRORS-key-only and therefore counted UNREAD:

  billing_not_configured, checkout_failed, email_invalid, email_taken,
  invalid_credentials, live_twin, name_required, no_active_subscription,
  no_subscription, password_invalid, plan_invalid, portal_failed, role_too_high

Includes all FIVE D871 curated keys (checkout_failed, portal_failed,
no_subscription, live_twin, role_too_high) — present in app.js on origin/main
yet UNREAD by the rule. The pinned numbers still reproduce because the surveyor
used the same pure-quoted-literal rule; the numerator is internally consistent,
not intent-consistent.

GUARD RISK (for decide/builders, not a count error): the standard console way to
add a reader IS a bare ERRORS key. A future new code given only a bare ERRORS
entry would be scanned UNREAD and RED the guard — punishing the exact fix the
guard exists to reward — unless parked in CLASSIFIED with a "read via bare ERRORS
key, invisible to quoted scan" reason, which muddies the honest-silence class.
Two clean resolutions: (a) extend Side B to parse the ERRORS keyset (union with
quoted-literal reads → 72 read / 99 unread), or (b) keep the pure rule and pin
the 13 bare-key codes in CLASSIFIED with an explicit read-but-bare reason arm.
Either is a decide call; the count re-derivation itself is sound.

## Adjacent confirmations

- No test asserts the ERRORS key count: `grep -rn 'Object.keys(ERRORS)\|ERRORS)'
  cloud/priv/static/__app.test.mjs cloud/priv/static/*census*.mjs` → rc=1, no
  hits. A bare ERRORS add is silently green (no counter to bump).
- `console_reader_census_test.exs` absent from the tracked tree AND from every
  open PR's file list (gh pr list --limit 200, empty). Filename is free.
- Collision precedent still live: `payload_key_set_census_test.exs` is claimed by
  BOTH #11901 and #10811 — the census guard must NOT reuse an existing census
  filename.
