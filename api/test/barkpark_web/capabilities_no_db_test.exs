defmodule BarkparkWeb.CapabilitiesNoDbTest do
  @moduledoc """
  `GET /v1/capabilities` assembles a static, in-memory manifest — it reads
  `conn.assigns[:api_token]` and touches no table. Every query an anonymous
  request issued came from `Plugs.AssignDefaultScope` in `pipeline :api`.

  Pinned here, by COUNTING Ecto's `[:barkpark, :repo, :query]` telemetry rather
  than by reading the code: an anonymous `/v1/capabilities` request costs ZERO
  queries with the default-scope cache warm, and returns a byte-identical body
  to the uncached request. The companion round-trip count for the two lookups
  themselves lives in `Barkpark.TenancyDefaultProjectRoundTripTest`.

  The invalidation cases are the point of the exercise: the cache is trivial,
  the two ways it can lie are not. A `nil` read from a pre-backfill (or
  mid-support-reset) database must never be pinned, and a write to the Default
  Workspace row must not leave a stale struct behind it.

  This is NOT a fix for the 500 class on that route (pool starvation, owned by
  `jpf-bl-oban-pool-partition`) and buys an authenticated `bp` caller nothing:
  `Plugs.OptionalToken` runs one plug EARLIER and still spends a checkout in
  `Auth.verify_token/1`.

  `async: false` deliberately: the query counter attaches a GLOBAL telemetry
  handler, and the cache it exercises is a public named ETS table.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.DefaultScopeCache

  setup do
    # config/test.exs pins the TTL to 0 (cache off) so the rest of the suite is
    # never handed a struct whose row the sandbox rolled back. These tests are
    # the ones that want it, so they arm it and disarm it again.
    previous = Application.get_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
    DefaultScopeCache.invalidate()

    on_exit(fn ->
      DefaultScopeCache.invalidate()

      case previous do
        nil -> Application.delete_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
        value -> Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, value)
      end
    end)

    :ok
  end

  defp arm_cache(ttl_ms \\ 60_000) do
    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, ttl_ms)
    DefaultScopeCache.invalidate()
  end

  # Count the Ecto queries THIS process issues while `fun` runs. Scoped to the
  # caller's pid so a stray async test or an Oban tick in the same VM cannot
  # inflate (or, worse, vacuously satisfy) the count.
  defp with_query_count(fun) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _cfg ->
        if self() == test_pid, do: send(test_pid, {:repo_query, handler_id, meta[:query]})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(handler_id, acc) do
    receive do
      {:repo_query, ^handler_id, sql} -> drain(handler_id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "anonymous GET /v1/capabilities" do
    test "issues ZERO queries once the default scope is cached", %{conn: conn} do
      arm_cache()

      # Warm the cache the way the first real request would.
      {_first, warm_queries} = with_query_count(fn -> get(conn, "/v1/capabilities") end)
      assert warm_queries != [], "the cold request must still query — otherwise this is vacuous"

      {second, queries} = with_query_count(fn -> get(conn, "/v1/capabilities") end)

      assert second.status == 200

      assert queries == [],
             "warm anonymous /v1/capabilities issued #{length(queries)} queries, expected 0:\n" <>
               Enum.join(queries, "\n")
    end

    test "the cached response is byte-identical to the uncached one", %{conn: conn} do
      Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 0)
      DefaultScopeCache.invalidate()
      uncached = get(conn, "/v1/capabilities")

      arm_cache()
      _warm = get(conn, "/v1/capabilities")
      cached = get(conn, "/v1/capabilities")

      assert uncached.status == 200
      assert cached.status == 200

      # `generated_at` is a per-response wall clock and differs between any two
      # requests, cache or no cache. It is also the ONLY key that does: the
      # ETag below is content-addressed over the manifest EXCLUDING it, so an
      # equal ETag is the real byte-stability signal and the map compare says
      # which key moved if it ever stops being true.
      assert Map.delete(Jason.decode!(cached.resp_body), "generated_at") ==
               Map.delete(Jason.decode!(uncached.resp_body), "generated_at")

      assert get_resp_header(cached, "etag") == get_resp_header(uncached, "etag")
      assert get_resp_header(cached, "etag") != []

      assert byte_size(cached.resp_body) == byte_size(uncached.resp_body),
             "the payload changed size — a cache must not alter the manifest"
    end
  end

  describe "invalidation — no pinned nil, no pinned stale row" do
    test "a nil from a pre-backfill DB is never cached" do
      arm_cache()
      counter = :counters.new(1, [])

      loader = fn ->
        :counters.add(counter, 1, 1)
        nil
      end

      assert DefaultScopeCache.fetch(:default_workspace, loader) == nil
      assert DefaultScopeCache.fetch(:default_workspace, loader) == nil
      assert DefaultScopeCache.fetch(:default_workspace, loader) == nil

      assert :counters.get(counter, 1) == 3,
             "nil was cached: the loader ran #{:counters.get(counter, 1)} times, expected 3"
    end

    test "a workspace settings write busts the cache" do
      arm_cache()

      before = Tenancy.get_default_workspace()
      assert before.id
      # Warm: a second read must be served from the cache.
      {_ws, queries} = with_query_count(&Tenancy.get_default_workspace/0)
      assert queries == []

      theme = Enum.find(Tenancy.known_themes(), &(&1 != Tenancy.workspace_theme(before)))
      refute is_nil(theme), "need a second known theme to make this test non-vacuous"
      {:ok, _} = Tenancy.set_workspace_theme(before, theme)

      {after_write, queries} = with_query_count(&Tenancy.get_default_workspace/0)

      assert queries != [], "the write did not bust the cache — the read was still served stale"
      assert Tenancy.workspace_theme(after_write) == theme
    end

    test "creating a workspace busts the cache — the default slug is a claimable seat" do
      arm_cache()
      _warm = Tenancy.get_default_workspace()

      {:ok, _other} =
        Tenancy.create_workspace(%{
          slug: "seat-race-#{System.unique_integer([:positive])}",
          name: "Seat Race"
        })

      {_ws, queries} = with_query_count(&Tenancy.get_default_workspace/0)
      assert queries != [], "create_workspace/1 left a stale default-scope cache entry"
    end
  end
end
