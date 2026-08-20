# cch w35 — DeliveryReason asserts four mechanisms nothing observed (re-derivation recipes)

Verifier lane `delivery-reason-miscause`, 2026-08-06. Every row re-derives from
`origin/main` @ `c73bbc07c` — NOT from the primary checkout, which is **474
commits behind** and does not contain `delivery_reason.ex` at all.

## R0 — the checkout trap (run this FIRST or every grep lies)

    git -C /Volumes/SATECHI/github/barkpark rev-list --count HEAD..origin/main   # 474
    grep -rn "ehostunreach" /Volumes/SATECHI/github/barkpark/cloud/              # NO MATCHES (false negative)
    git -C /Volumes/SATECHI/github/barkpark grep -n "ehostunreach" origin/main -- cloud   # the truth

    cd /Volumes/SATECHI/github/barkpark/cloud && CC=clang mix test test/barkpark_cloud/notifications/delivery_reason_test.exs
    # => Paths given to "mix test" did not match any directory/file

## R1 — the four miscauses, executed (no DB, no Phoenix, ~1s)

    mkdir -p /tmp/dr && cd /tmp/dr
    git -C /Volumes/SATECHI/github/barkpark show origin/main:cloud/lib/barkpark_cloud/notifications/delivery_reason.ex > delivery_reason.ex
    # probe.exs: Code.require_file then classify/label each term
    elixir probe.exs

Observed on origin/main:

| term | gen_smtp meaning | class | published sentence |
|---|---|---|---|
| `:no_credentials` | `check_option/2` (`gen_smtp_client.erl:974`) — `auth: always` with no username/password. **No socket opened.** | `:auth_rejected` | "The destination rejected our credentials." |
| `{:missing_requirement, host, :tls}` | `erlang:throw` at `:798` — server did **not advertise** STARTTLS; `quit(Socket)` before any handshake | `:tls_failure` | "The secure (TLS) handshake with the destination failed." |
| `{:missing_requirement, host, :auth}` | `try_AUTH/3` `:575/:583/:597` — server advertised **no AUTH types** | `:auth_rejected` | "The destination rejected our credentials." |
| `:ehostunreach` / `:enetunreach` | no route — **nobody answered** | `:connection_refused` | "The destination refused the connection." |
| SMTP `450` / `451` / `452` | mailbox busy / **local error** / **insufficient storage** | `:rate_limited` | "The destination is rate-limiting us — try again later." |

`:econnrefused` (peer answered with RST) and `421` are the CONTROLS — they stay
put. Charter D321(3) (`failure_copy.ex:535-547`) already ruled that fusing
"refused" with the network class is a defect, because it hands the reader the one
remedy that cannot work. `:ehostunreach → :connection_refused` is that ruling run
backwards, inside a different module.

## R2 — which arms are PINNED by the shipped test (the fail-before budget)

    git -C /Volumes/SATECHI/github/barkpark show origin/main:cloud/test/barkpark_cloud/notifications/delivery_reason_test.exs | grep -c 'ehostunreach\|enetunreach\|451\|452'
    # => 0

`census_terms/0` (:52-83) pins exactly TWO of the four: `:no_credentials` and
`{:missing_requirement, :tls}`. `missing_requirement :auth`, `ehostunreach`,
`enetunreach`, `450/451/452` have **no census row** — correcting them produces no
red, so the builder must ADD rows or those two arms ship green-by-construction.
`test "covers every class …"` uses `class in classes()`, so it is additive-safe
and cannot lose on a widening either.

## R3 — the changeset clamp does NOT need a hand edit (refutes the brief)

`delivery.ex:117` is `@failure_labels Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1)`.
Simulated with 5 added classes: OLD clamp 9 sentences → NEW clamp 14, **derived**.
`withhold_test.exs:593` and `legacy_last_error_backfill_test.exs:136` both derive
from `classes/0` too. The real rule is the inverse: a `label/1` arm added WITHOUT
an `@classes` entry is REJECTED by the clamp
("must be a classified delivery reason, not a raw transport term") — verified
false on the orphan-sentence probe.

## R4 — two second-readers that DO move in the same commit

* `delivery_reason.ex:47` moduledoc asserts "every one of its **nine** labels" —
  a count the code stops supporting. Same defect class as the slice itself.
* No retry exists (`delivery.ex:10` — "the **future** retry seam"), so a new
  label may not say "we'll retry it". `:rate_limited`'s existing "try again
  later" is advice to a human, not a claim about the system, and survives.

## R5 — no client reader

    git -C /Volumes/SATECHI/github/barkpark grep -n "last_error" origin/main -- cloud/priv/static/app.js
    # app.js:3050-3051 — esc(d.last_error), VERBATIM. No copy table.

Server-only fix. File-disjoint from s6 (app.js), s5 (registry.ex) and the merge
half (scripts). `app.js:8461`'s `last_error_text` is a DIFFERENT field, proxied
from `api/lib/barkpark/webhooks.ex:426`, and is NOT classified at all — residue.

## R6 — historical rows are not repairable

`priv/repo/migrations/20260805210000_backfill_legacy_last_error.exs` already ran.
Rows stamped with a wrong sentence keep it — the raw term is gone. The slice must
SAY forward-only rather than claim a correction it cannot perform.
