# V7 error-tuple-weak — re-derivation recipe (2026-08-18)

Cloud control-plane correctness audit wave. Verdict: all three candidates SAFE, zero REAL.

## Claim 1 — router:1684 `{:ok,_} = Accounts.disable_two_factor/1` cannot hit the error arm

    git show origin/main:cloud/lib/barkpark_cloud/accounts/user.ex | sed -n '221,229p'
    # two_factor_disable_changeset uses change/2 only — no cast/validate_*/constraint
    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '2236,2238p'
    # disable_two_factor = changeset |> Repo.update()
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1684p'

A `change/2` changeset carries no validations and no DB constraints, so it is always `valid?: true`. `Repo.update` on it can only fail via DB-level errors that RAISE (e.g. `Ecto.StaleEntryError`), never `{:error, changeset}`. The strict match is infallible on the happy path. SAFE.

## Claim 2 — router:3790/3800 (+operator twins) `{:ok,_} = Registry.set_autoupdate_halted/1`

    git show origin/main:cloud/lib/barkpark_cloud/registry/fleet_settings.ex   # cast+validate_required([:autoupdate_halted])
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '4448,4454p'  # is_boolean guard; insert_or_update
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '3788,3811p'  # called with literal true/false

set_autoupdate_halted has an `is_boolean` guard; router passes literal `true`/`false`. cast of a boolean succeeds and validate_required passes → changeset always valid. No unique/exclusion constraint on the single-row schema, so insert_or_update cannot return `{:error,_}`. Strict match infallible. SAFE.

## Claim 3 — daily_digest_worker CaseClauseError on `{:error,_}` from deliver_fleet_digest

    git show origin/main:cloud/lib/barkpark_cloud/workers/daily_digest_worker.ex | sed -n '55,80p'
    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '426,516p'

deliver_fleet_digest's @spec and body return EXACTLY `{:ok, :no_admins}` or `{:ok, %{sent, recipients}}` — there is no `{:error,_}` return path. The worker's case over those two shapes is therefore exhaustive against the real contract. Belt-and-suspenders: any internal raise is caught by the worker's `rescue e -> Logger.error; :ok`, and `max_attempts: 1` forecloses a retry storm. SAFE on both dimensions.
