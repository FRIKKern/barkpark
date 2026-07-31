# identity-echo-cost — re-derivation recipes (cch wave 13 verify)

Question: is an Azure account-identity echo cheap? Was the D78 follow-up ever filed?

## 1. The console ALREADY decrypts the azure blob at render time

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '9093,9101p'
```
`build_provider_catalog("azure", provider)` → `Registry.reveal_provider_token(provider)`
→ `Jason.decode(credential)` → creds map. Reached by `GET /v1/providers/:kind/catalog`
and `/overview` (router.ex:3807 / :3815), both `Auth.require_user(conn, [])` — any team
member, no admin.

## 2. subscription_id comes out of that seam with ZERO Azure HTTP

Scratch ExUnit (written to `cloud/test/scratch_identity_echo_cost_test.exs`, run, deleted):
connect_provider(team,"azure",Jason.encode!(creds)) → list_providers → reveal_provider_token
→ Jason.decode → creds["subscription_id"]. Printed `0000-SUB-ECHO-9999`. 1 test, 0 failures.

## 3. The ARM body that verify/1 discards cannot name the account

```
git show origin/main:cloud/lib/barkpark_cloud/azure/client.ex | sed -n '183,195p;241,249p'
```
- `verify/1` returns `%{subscription_id: sub}` where `sub = Map.get(creds,"subscription_id")`
  — the value the PERSON TYPED, not a server fact.
- `resource_groups_request/2` is `.../resourcegroups?api-version=2021-04-01&$top=1` — a
  LIST of at most one resource group. A subscription with zero resource groups returns an
  empty `value` ⇒ no id, no name.
- Only four request builders exist (`token_request`, `resource_groups_request`,
  `locations_request`, `vm_sizes_request`). No subscription-detail builder, so
  `GET /subscriptions/{sub}?api-version=2020-01-01` → `displayName` (the human-readable
  name) is ONE EXTRA call, not zero:
  `git show origin/main:cloud/lib/barkpark_cloud/azure/client.ex | grep -n '_request('`

## 4. Hetzner still has no identity

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8967,8979p'
```
`hetzner_token_ok?/1` = `GET /v1/servers?per_page=1`, boolean on the status. No identifier.

## 5. The D78 follow-up WAS filed

```
bp search query '"identity echo"'
bp task get cch-bl-provider-rotation-identity-echo -o json
```
`cch-bl-provider-rotation-identity-echo` — open, priority 3, parent
`cloud-console-hardening-epic`, GH issue 6519, 0/4 criteria, wave_paper
`cloud-console-hardening-wave-6-2026-07-28`.

## 6. Suite

```
cd cloud && CC=/usr/bin/clang mix test \
  test/barkpark_cloud/azure_catalog_test.exs test/barkpark_cloud/azure_client_test.exs \
  test/barkpark_cloud/azure_pricing_test.exs test/barkpark_cloud/registry_azure_credentials_test.exs \
  test/barkpark_cloud/registry_provider_upsert_test.exs test/barkpark_cloud/registry/provider_test.exs \
  test/barkpark_cloud/web/router_providers_catalog_test.exs \
  test/barkpark_cloud/web/provider_neutral_launch_test.exs \
  test/barkpark_cloud/web/router_providers_capabilities_test.exs \
  test/barkpark_cloud/providers_capabilities_contract_test.exs
```
→ 100 tests, 0 failures. NOTE: `mix test test/barkpark_cloud/azure` (as briefed) does not
exist — "Paths given to "mix test" did not match any directory/file".
