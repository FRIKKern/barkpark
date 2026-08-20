# One-sidedness census — clock-semantics wave (verify phase, onesidedness-census)

Date: 2026-08-19. All facts derived from `origin/main` via `git show` / `git grep origin/main`,
never the working tree (the primary checkout is dirty and shared).

## Re-derivation commands

```sh
# the mandated census
git grep -nE '(System\.(system_time|os_time)\(:second\)|DateTime\.utc_now\(\)) *[-)]' origin/main -- api/lib cloud/lib
git grep -nE 'DateTime\.diff\(' origin/main -- api/lib cloud/lib          # 31 hits
git grep -nE 'DateTime\.compare\(' origin/main -- api/lib cloud/lib       # 33 hits
git grep -n 'abs(now' origin/main -- api/lib cloud/lib                    # 4 hits, 1 is prose
# integer-arith clock comparisons (catches the MFA gate's subtraction form)
git grep -nE '(System\.(system_time|os_time)\([^)]*\)|\bnow(_ms)?\b) *(<=?|>=?|-) ' origin/main -- api/lib cloud/lib
```

## Verdict

One-sidedness is HOUSE STYLE, and the partition is principled, not accidental:

* TWO-SIDED (`abs(now - t) <= tol`) is used iff the compared instant is supplied
  by an UNTRUSTED REMOTE SENDER — 3 sites, all HMAC signature replay-tolerance
  gates: `api/lib/barkpark/webhooks/dispatcher.ex:418`,
  `cloud/lib/barkpark_cloud/billing/stripe_gateway.ex:365`,
  `cloud/lib/barkpark_cloud/webhooks/inbound_signature.ex:111`
  (the latter two carry the verbatim comment "in either direction").
* ONE-SIDED is used iff the compared instant is SERVER-STORED or
  server-HMAC-sealed — 16 auth/expiry/replay sites, 34 bound-bearing sites total.

`api/lib/barkpark_web/controllers/session_controller.ex:347`
(`is_integer(at) and System.system_time(:second) - at <= 300`) sits on the
server-stored side of that partition (`at` is put into the SIGNED session cookie at
`session_controller.ex:189`), so it is a MEMBER of the 16, not an outlier against
the 3. Its only genuine outlier property is FORM: it is the sole member expressed
as integer subtraction instead of `DateTime.compare(now, add(stored, window))`,
which is why it reads like a duration. Arithmetically `now - at <= 300`
⟺ `now <= at + 300`, identical to `UserSession.mfa_fresh?/3` at
`api/lib/barkpark/accounts/user_session.ex:174`.

## Second, unrelated defect surfaced by the same sweep

`api/lib/barkpark/accounts.ex:698-736` (`verify_totp` / `consume_totp_step`) has NO
ordering predicate at all: `cas_last_totp(query, seen)` is
`u.last_totp_at == ^seen` (equality CAS). Its own moduledoc claims "The stamp is
therefore also monotonic (a winner always moves it forward)" — that claim holds
only under a monotone wall clock. Cloud's twin uses an ordering predicate,
`cloud/lib/barkpark_cloud/accounts.ex:2186`:
`(is_nil(u.two_factor_last_step) or u.two_factor_last_step < ^step)`.
One repo, two TOTP replay floors, one with an ordering guard and one without.

Re-derive: `git show origin/main:api/lib/barkpark/accounts.ex | sed -n '690,740p'`
and `git grep -n two_factor_last_step origin/main -- cloud/lib`.
