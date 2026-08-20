# cch-w70 S5 elixir-ground — re-derivation recipe (verify @ d020382028)

Baseline: origin/main d020382028 (prod-serving). Worktree compile needs `CC=/usr/bin/clang` (the `cc` alias shadows the compiler).

## Green baselines (run-proof behind D848's surgery map)

    cd cloud && CC=/usr/bin/clang MIX_ENV=test \
      mix test test/barkpark_cloud/web/router_sites_destroy_failures_test.exs
    # => 2 tests, 0 failures  (one emits a DELIBERATE crash_envelope 500 log line — the FK-regression test)

    cd cloud && CC=/usr/bin/clang MIX_ENV=test \
      mix test test/barkpark_cloud/site_cascade_census_test.exs
    # => 7 tests, 0 failures  (census: 3 FKs referencing sites, all confdeltype=c)

## Delete-route text anchors (lib/barkpark_cloud/web/router.ex @ d020382)

    grep -n "delete \"/v1/sites/:id\"\|Registry.delete_site\|W67 S2 / D820" lib/barkpark_cloud/web/router.ex
    # 7104  delete "/v1/sites/:id" do
    # 7111-7127  HARD-MATCH D820 comment block  (D848 cites stale 7077-7095; digest corrected to 7111-7127)
    # 7127  {:ok, _} = Registry.delete_site(site)   <-- the strict match

Registry.delete_site/1 body (lib/barkpark_cloud/registry.ex:713):

    def delete_site(%Site{} = site) do
      _ = deregister_content_webhook(site)
      Repo.delete(site)          # bare struct, NO constraint declared -> RAISES Ecto.ConstraintError on RESTRICT
    end

## The nested-case answer (S5's one mechanical unknown) — CONFIRMED, with a caveat

Outer `case teardown_result do` has arms: `:ok ->`, `{:error,status,detail,code} ->` (sibling relay,
router.ex ~7150), `{:error,status,detail} ->`. The sibling relay arm matches teardown_result, NOT
delete_site's return — it is UNREACHABLE from inside the `:ok ->` arm. So the typed error needs its
own NESTED case inside `:ok ->`:

    :ok ->
      case Registry.delete_site(site) do
        {:ok, _} -> <audit + push_events + json 200 {ok:true,status:"deleted",slug}>
        {:error, ...} -> json(conn, 500, %{ok: false, error: "registration_not_removed", detail: <both halves>})
      end

CAVEAT (necessary-but-not-sufficient): the real inverse-orphan RAISES Ecto.ConstraintError — a `case`
cannot catch a raise. D848's mechanism is a `rescue %Ecto.ConstraintError{type: :foreign_key}` INSIDE
delete_site/1 (ecto 3.14 stores type/constraint/message only; changeset decl unavailable for 2 of 3
child tables). So BOTH edits ship together: delete_site/1 gains the rescue -> returns a tuple; the
router gains the nested case -> renders it. The nested case alone changes nothing.

## D848 test-surgery anchors — byte-accurate on main today

    grep -n "flunk(\|constraint_error?(e)\|assert status == 500\|server_error\|slug == site.slug\|refute Registry.get_site\|defp constraint_error?" \
      test/barkpark_cloud/web/router_sites_destroy_failures_test.exs
    # 153 flunk (INVERTS) | 160 constraint_error?(e) (retire) | 170 server_error (-> typed code)
    # 179 slug==site.slug (KEEP) | 184 refute get_site (KEEP) | 189-191 defp constraint_error? (retire)
    # site_cascade_census_test.exs:161 message says "500 server_error" -> stale, rewrite same PR
