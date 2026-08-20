<!-- doc-tier: cold | canonical-for: cch-w72-census-extraction-rederivation | budget: 1200tok -->

# cch-w72 census Side-A / Side-B extraction rule — re-derivation recipe

Verifier `census-rule`, wave 72, against `origin/main` only (never the worktree).
Pins the denominator (emitter set) and numerator (console reader set) for the
committed wire-vs-reader census guard.

## Side A — emitter denominator = 171

RULE: comment-stripped union of `(error|code): "<snake>"` string-KEY literals over
`cloud/lib/barkpark_cloud/web/router.ex` + `auth.ex`. Comment-strip is MANDATORY.
`when code in [...]` guards are READERS, not mints — excluded (they never match
`error:`/`code:` key syntax anyway).

Naive (polluted) baselines and why they are wrong:

    # raw space-required union grep = 172  (carries ONE comment artifact)
    cat <(git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -oE '(error|code): "[a-z0-9_]+"') \
        <(git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex   | grep -oE '(error|code): "[a-z0-9_]+"') \
      | sed -E 's/.*: "//;s/"//' | sort -u | wc -l          # -> 172
    # the +1 over 171 is internal_error, which lives ONLY in a comment:
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n '"internal_error"'   # -> 8793: # `%{error: "internal_error"}` ...

    # space-OPTIONAL grep = 183  (comment + when-guard pollution, e.g. code:"no_previous_slot")
    # -> never use space-optional without comment-strip.

Defensible denominator (comment-stripped, python), = 171:
strip `#`..EOL respecting string state, then union of `error:` (161) and `code:` (17)
keys; the 10 codes UNIQUE to `code:` are:
already_running, capability_unavailable, identity_refused, instance_error,
instance_unavailable, not_supported, pinned, runner_start_failed, upstream_error,
webhook_gone — all with ≥1 real comment-stripped `code: "..."` emitter.
=> an `error:`-only census (161) UNDERCOUNTS the real refusal denominator by exactly 10.

The "%{error:...} literal-map parse = 120" is a PARSER ARTIFACT: a faithful
nested-brace parse recovers all 161 error-codes (every one sits inside some map
literal), and strict `%{error:` additionally misses keyword-list emissions
(`json(conn, error: "...")`, 41 raw router occurrences) and all 17 `code:` codes.
120 is a narrow-parser miss, not a real emitter category.

## Side B — console reader numerator = 55  (UNREAD = 116)

RULE: a code is READ iff it appears as a WHOLE quoted string literal (`"x"` or `'x'`)
on a comment-stripped line of `cloud/priv/static/app.js`. This subsumes ERRORS
object keys (friendly's `ERRORS[key]`), switch `case "x":` arms, and `key === "x"`
comparisons. Comment-strip mandatory. Whole-file regex string-scans DESYNC on a
dangling quote — test per-code, per-line.

    READ = { c in emitter171 : "c" or 'c' occurs on a comment-stripped app.js line }
    |READ| = 55   |UNREAD| = 116   (171 - 55)

UNREAD 116 CONVERGES independently with strategize's 116. READ 55 is lower than
strategize's 57 / raw 56 because those count comment-only PHANTOM readers.

## Phantom-reader adjudication (three candidates)

- expired_or_invalid  -> PHANTOM / UNREAD. Sole app.js hit is a comment
  (app.js:21751 `// ... 404 {error:"expired_or_invalid"}`). No case, no ERRORS key.
- instance_unavailable -> REAL READER (READ). app.js:8762 `case "instance_unavailable":`
  inside updateRefusalReason — a switch on the wire refusal code. NOT a phantom.
- provision_failed     -> REAL READER (READ). app.js:3397 NOTIF_EVENTS census-pinned
  label; reads the notification-event namespace but is also a genuine refusal emitter.
