# Re-derivation recipe — `:test` is producerless in `@always_send`, and the always-send row is unguarded

Wave 52 (cloud-console-hardening), verifier `test-event-producerless-and-copy`.
All commands run from a full-tree extract of `origin/main` @ `572d51e1`.

## 0. Build the tree (every recipe below assumes `$D/cloud`)

```
D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C $D
cp -R /Volumes/SATECHI/github/barkpark/cloud/deps $D/cloud/deps
cp -R /Volumes/SATECHI/github/barkpark/cloud/_build $D/cloud/_build
```
`cloud/mix.lock` and `cloud/mix.exs` are byte-identical between the (652-behind)
primary checkout and `origin/main` — `git diff --stat origin/main -- cloud/mix.lock cloud/mix.exs`
prints nothing — so the borrowed deps are the right ones. `cloud/lib` and
`cloud/test` are NOT identical (127 files, 35,526 deletions): never run this in
the primary checkout.

## 1. `:test` has no producer in `cloud/lib`

```
git grep -n 'dispatch_event(' origin/main -- cloud/lib
git -C $D/cloud grep -rn 'dispatch_event(.*:test\|dispatch_site_event(.*:test\|dispatch_barkpark_event(.*:test' lib test
```
Producers in `cloud/lib`: `provision_succeeded`, `provision_failed`,
`agent_reachable`, `agent_unreachable`, `subscription_past_due`,
`trial_expiring`, `deployment_failed`. The only `:test` literals are in
`test/barkpark_cloud/notifications_test.exs:252,256` and
`test/barkpark_cloud/notifications/withhold_test.exs:885`.

## 2. `:test` has no `EventEmail` arm (it renders the catch-all)

```
cd $D/cloud && MIX_ENV=test CC=clang mix run --no-start /tmp/v52probe.exs
```
with `/tmp/v52probe.exs` building `EventEmail.build(%EmailSettings{}, :test, …).subject`.
Expected: `"Barkpark Cloud notification"` (the catch-all `EmailSettings.events/0`
does not contain `:test`, so `event_vocabulary_census_test.exs` never drives it).

## 3. MUTATION — the console's always-send list is UNGUARDED in the offer→producer direction

```
# add ["quota_exceeded","Quota exceeded","…"] as the first row of NOTIF_ALWAYS_SEND
node $D/cloud/priv/static/__app.test.mjs   # → rc 0, 1004 pass / 0 fail
```
The wave-30 census's ARM (a) filters `NOTIF_EVENTS` only. Deleting the `test`
row instead reds ARM (b) plus the parse floor (`rc 1`, `not ok 827`, `not ok 829`),
so the SENDS→surfaced direction IS guarded and the surfaced→producible direction
is not.

## 4. MUTATION — dropping `test` from `@always_send` costs exactly one synthetic test

```
sed -i '' 's/@always_send ~w(test trial_expiring)a/@always_send ~w(trial_expiring)a/' \
  $D/cloud/lib/barkpark_cloud/notifications.ex
cd $D/cloud && MIX_ENV=test CC=clang mix test test/barkpark_cloud/notifications_test.exs test/barkpark_cloud/notifications/
```
Expected: `164 tests, 1 failure` — `notifications_test.exs:247`, the test that is
itself the only caller of `dispatch_event(team, :test, …)`. `@chat_always_send`
is untouched and the whole chat suite stays green.

## 5. The three live behaviours (write to `test/v52_probe_test.exs`, then `mix test`)

* `deliver_test/2` sends while `alerts_enabled: false`.
* `deliver_test/2` sends while `transport: "smtp"` (`Transactional.deliver_test/1`
  is `Mailer.deliver()`, arity 1 — `notifications/transactional.ex:109`).
* `transport: "api"` is accepted and persisted; a real `dispatch_event` still
  sends and `list_deliveries/1` writes `status: "sent"` with no `carrier` field.

Expected: `3 tests, 0 failures`.

## 6. Restore check

```
for f in cloud/lib/barkpark_cloud/notifications.ex cloud/priv/static/app.js; do
  shasum "$D/$f"; git -C /Volumes/SATECHI/github/barkpark show "origin/main:$f" | shasum; done
```
Both pairs must match (`88d0575e…`, `0ac3e77e…`) before any reading is quoted.
