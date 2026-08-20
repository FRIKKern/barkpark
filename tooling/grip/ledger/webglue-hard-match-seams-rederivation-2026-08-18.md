# Re-derivation recipe — web-glue hard-match seams (webhook replay/test-send, SCIM deprovision)

Wave: web-glue-robustness-wave-2026-08-18 · verifier lane `hard-match-seams`
Pinned tree: `origin/main` = `228090798bf50a3ae2bb15699c04ddf65b2dcdd2`

## Claim under test

`webhook_controller.ex:104` `{:ok, delivery} = Dispatcher.replay_delivery(wh, body, eid)`,
`:178` `{:ok, delivery} = Dispatcher.deliver_test(wh, body, delivery)` and
`scim_users_controller.ex:77/:104` `{:ok, _} = Scim.deprovision_user(...)` are
in-body hard matches → MatchError-500 IF the callee can ever return non-`{:ok,_}`.

## Verdict: SAFE (all four sites), with two out-of-band-only races noted.

## Recipe

1. Return-shape of both dispatcher senders — both funnel into
   `record_single_attempt/3` (dispatcher.ex:~700), whose only exits are
   `Webhooks.mark_delivered/4` / `mark_giveup/5`, each ending in `Repo.update()`
   on a changeset that cannot be invalid (status ∈ @statuses, source_kind unchanged,
   validate_required_for_kind satisfied by the loaded struct):

       git show origin/main:api/lib/barkpark/webhooks/dispatcher.ex | sed -n '660,730p'
       git show origin/main:api/lib/barkpark/webhooks.ex | sed -n '400,440p'

2. EXECUTED shape proof (scratchpad scripts, not repo files) — swap
   `:webhook_http_adapter` for fakes returning transport-error / 404 / 500 /
   `{:ssrf_blocked,_}` / 200 and assert `match?({:ok, %Delivery{}}, ...)`:

       cd api && MIX_ENV=test mix run <scratchpad>/seam_probe.exs      # deliver_test, 3 arms
       cd api && MIX_ENV=test mix run <scratchpad>/replay_probe.exs    # replay_delivery, 3 arms

   All six arms printed `ok_tuple? true`.

3. SCIM: `Scim.deprovision_user/3` is `Repo.transaction(fn -> ... end)` with NO
   `Repo.rollback` anywhere in the module, so `{:error,_}` is unreachable:

       git show origin/main:api/lib/barkpark/scim.ex | grep -n "Repo.rollback"   # empty

   Its `hard: true` arm's `Repo.delete!(user)` cannot ConstraintError — every FK
   referencing `users` is CASCADE or SET NULL (0 NO ACTION/RESTRICT):

       cd api && MIX_ENV=test mix run <scratchpad>/fk_probe.exs
       # confdeltype over pg_constraint where confrelid = 'users'::regclass

4. Regression floor (green on the pinned tree). NOTE: there is NO
   `test/barkpark_web/controllers/webhook_controller_test.exs` on origin/main —
   `mix test` SILENTLY IGNORES the missing path, so naming it yields a partly
   vacuous green (the 26 tests are all scim_users). The real webhook coverage:

       cd api && mix test test/barkpark_web/controllers/scim_users_controller_test.exs
       # 26 tests, 0 failures
       cd api && mix test test/barkpark_web/controllers/webhook_deliveries_test.exs \
         test/barkpark_web/controllers/webhook_controller_param_coercion_test.exs \
         test/barkpark_web/contract/webhooks_test.exs \
         test/barkpark/webhooks/dispatcher_test.exs
       # 73 tests, 0 failures
       git ls-tree -r --name-only origin/main -- api/test | grep -i "webhook\|scim"

## Residual races (FILE-only, NOT request-reachable)

* R1 `replay_delivery/3` — `claim_delivery` → `{:error, :already_delivered}` →
  immediate `get_delivery` returns nil if the row was deleted in between →
  `record_single_attempt(nil, ...)` → BadMapError-500. Proved `nil.attempts`
  raises BadMapError.
* R2 — `claim_delivery/2`'s changeset declares no `foreign_key_constraint`, so a
  `mutation_events` row deleted between the controller's `Repo.get` and the
  insert raises `Ecto.ConstraintError` (`webhook_deliveries_event_id_fkey`) →
  500. Reproduced directly by claiming against a non-existent event id. No
  in-app pruner deletes `mutation_events` (`git grep MutationEvent -- api/lib |
  grep delete_all` → empty), so only an out-of-band DELETE opens the window.
