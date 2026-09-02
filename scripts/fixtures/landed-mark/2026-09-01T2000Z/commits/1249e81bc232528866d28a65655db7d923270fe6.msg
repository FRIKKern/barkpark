fix(cloud): delete the replay-blind 2FA verifier that read as the canonical one (#14368)

* fix(cloud): delete the replay-blind 2FA verifier that read as the canonical one

`BarkparkCloud.Accounts.TwoFactor` exported `valid_otp?/2` — a public,
`@doc`'d, `@spec`'d boolean verifier with ZERO call sites and ZERO tests
anywhere in `cloud/`. It ran exactly the `Enum.any?` over the `[-1, 0, 1]`
step window that `matching_step/3` runs, minus the step.

The step is the whole point. `matching_step/3` returns `{:ok, step}` so
`Accounts.verify_two_factor_otp/2` can CONSUME it in a SQL guard
(`is_nil(u.two_factor_last_step) or u.two_factor_last_step < ^step`), which
is what makes one OTP spendable exactly once. A boolean cannot carry the
step, so its caller has nothing to consume and the same six digits clear
every challenge for the full ~90s tolerance window.

Nothing could catch it, by construction on all three axes: the compiler
raises no unused warning for a PUBLIC function; a zero-caller sweep counted
`matching_step/3`'s own `@doc` — "Like `valid_otp?/2`, but…" — as a
reference, so the decoy was hidden by the sentence recommending it; and no
behavioural 2FA test can see an unused door, because the live path already
takes the safe one. The naming inverted the two: the shorter, plainer name
read as canonical while the replay-safe one documented itself as its variant.

The fix deletes it and folds its ±1-step tolerance rationale into
`matching_step/3`'s `@doc`, which now states that the absence of a boolean
twin is deliberate. No behaviour changes on any live path — the deleted
function had no callers.

`two_factor_replay_door_test.exs` is the tripwire, in two arms because one
is not enough:

  * ARM 1 censuses `TwoFactor.__info__(:functions)`: `{:matching_step, 3}`
    must stay public and no exported predicate may name an OTP.
  * ARM 2 censuses every `.ex` under `cloud/lib` for `NimbleTOTP.valid?(`
    CALLS — exactly one, in `two_factor.ex`, below `matching_step/3`'s
    definition clause. This catches a reintroduced twin that dodges the
    naming rule (`otp_ok/2`, or a copy in another module).

ARM 2 reads CODE, not prose: it strips `#` comments and `@doc`/`@moduledoc`
heredocs first. That is not tidiness — the first cut of this arm reported
TWO call sites, the second being the new `@doc` sentence explaining the rule.
A census that cannot tell a call from a mention reds on its own
documentation and teaches the next reader to delete the explanation. Its
anti-vacuity guard is asserting the count is exactly 1, not 0: a wrong
`@lib_root` makes `Path.wildcard/1` return `[]`, and an `offenders == []`
assertion would pass having read nothing.

RED-BEFORE, MEASURED (not claimed): with `two_factor.ex` restored to HEAD and
the tripwire kept, `mix test test/barkpark_cloud/two_factor_replay_door_test.exs`
exits 2 with `2 tests, 2 failures` — ARM 1 naming `[valid_otp?: 2]`, ARM 2
naming both call sites at `two_factor.ex:56` and `:125`. With the deletion
applied: `2 tests, 0 failures`.

Gate (cloud/, MIX_ENV=test): `mix format --check-formatted` ok;
`mix compile --warnings-as-errors` ok; `mix test` over the new file plus
`two_factor_test.exs` and `web/router_two_factor_test.exs` — `34 tests, 0
failures`.

Task: task-b68092d5bac508e0

* docs(cloud): stamp matching_step/3 canonical, with the deleted twin in its aka

The tripwire in the parent commit stops a replay-blind OTP verifier being
REINTRODUCED. It does nothing for the reader who goes looking for one — and
that reader is the likelier failure now, because the shorter, more obvious name
is the one that was just deleted.

`@canonical capability:totp-step-verification` marks `matching_step/3` as the
one true door, and `aka:` deliberately carries `valid_otp` alongside the
surviving spellings. A marker listing only names that still exist protects
nobody: nobody greps for the term they already found. `valid_otp` is what a
reader who learned this module from the old code — or from a stale note, a
cached search, a model's memory of this file — will actually type, and it must
land on the function that returns the step rather than on nothing, because
"no such thing" reads as an invitation to write one.

`scripts/canonical-marker-bindings.pin` gains exactly one row,
`totp-step-verification -> matching_step`, regenerated via
`REGEN_CANON_PIN=1 scripts/docs-anchors-check.sh` rather than hand-typed. That
pin is what makes the marker a tripwire in its own right: §8b re-derives every
marker's bound symbol from source each run, so a future edit that slides this
marker onto a different function reds by name instead of silently re-pointing
the index.

Gate (all print their own verdict; none piped to tail):
  scripts/docs-anchors-check.sh — exit 0
    "@canonical capability slugs unique"
    "§8 scanned 60 @canonical marker(s) in the repo corpus"
    "§8b all 60 marker pairing(s) match the pin — none has migrated"
  cloud/: mix format --check-formatted ok · mix compile --warnings-as-errors ok
  cloud/: FULL suite 3984 tests, 0 failures (unchanged from the parent commit —
  a comment cannot move behaviour, and this says so with a run rather than
  assuming it)

Slug uniqueness verified against all 60 markers in the tree; the nearest
neighbour is api/'s `user-auth` (aka includes `totp`), a different capability in
a different OTP app — the api/ context module, not this verifier.

Task: task-b68092d5bac508e0
