defmodule BarkparkWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BarkparkWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BarkparkWeb.Endpoint

      use BarkparkWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BarkparkWeb.ConnCase
    end
  end

  @doc """
  The scoped-canonical form of a Studio path (P3 of Scoped-by-URL).

  The flat `/studio/:dataset/...` URLs 302 to
  `/w/:ws/p/:proj/d/:dataset/studio/...` since the P3 cutover (and the
  /d/ canonical move), so LiveView tests mount the scoped form directly.
  Pass the `/d/:dataset/studio[/...]` tail. Seeds the Default
  workspace/project idempotently (the scoped route 404s on an unseeded
  tenancy — the flat surface used to tolerate that silently).

      live(conn, scoped_studio("/d/production/studio/post/p1"))
  """
  def scoped_studio(path) when is_binary(path) do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    "/w/#{ws.slug}/p/#{project.slug}" <> path
  end

  @rate_limit_scope_key :barkpark_rate_limit_test_scope

  @doc """
  THE ONLY WAY A TEST SHOULD MINT A CONN FOR A RATE-LIMITED ROUTE.

  `Phoenix.ConnTest.build_conn/0` returns a conn with no private data, and
  `BarkparkWeb.Plugs.RateLimit` reads `:barkpark_rate_limit_scope` out of
  `conn.private` to suffix the bucket key. A conn without it therefore shares
  ONE process-wide bucket with every other unscoped conn in the run — and for
  the routes under `pipeline :user_auth` (`/v1/auth/*`, `/v1/access/claim`)
  that bucket is `ip:127.0.0.1`, because those callers have no verifiable
  identity BY DESIGN. That is not a limiter bug: the shared per-IP budget IS
  the brute-force control on login, and giving those routes private buckets
  would hand every attacker their own. It is a TEST-CONSTRUCTION bug, and it
  reddened main for 2.5 hours (#15677 -> revert #15722): 12 bare `build_conn()`
  calls in `webauthn_controller_test.exs` and 7 in `access_controller_test.exs`
  pooled into one 60/min write bucket and the suite throttled itself.

  The scope is per TEST PROCESS, not per call, so two conns built inside one
  test still share a bucket and a test CAN still prove that the limiter limits.
  `BarkparkWeb.Plugs.RateLimitTestConnScopeTest` is the tripwire that keeps a
  bare `build_conn()` from coming back on a metered anonymous route.
  """
  def scoped_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_private(:barkpark_rate_limit_scope, rate_limit_test_scope())
  end

  @doc """
  This test process's rate-limit scope, minted once and memoised. ExUnit runs
  `setup` and the test body in the SAME process, so every `scoped_conn/0` in one
  test agrees, and no two tests ever do.
  """
  def rate_limit_test_scope do
    case Process.get(@rate_limit_scope_key) do
      scope when is_binary(scope) ->
        scope

      _ ->
        scope = Integer.to_string(System.unique_integer([:positive, :monotonic]))
        Process.put(@rate_limit_scope_key, scope)
        scope
    end
  end

  setup tags do
    Barkpark.DataCase.setup_sandbox(tags)
    # Restore the `:barkpark, :plugins` env to its unset boot baseline so a
    # leaked load-order list from a sibling test can't hide plugins from the
    # collectors this test exercises. See `Barkpark.DataCase.reset_plugins_env/0`.
    Barkpark.DataCase.reset_plugins_env()

    {:ok, conn: scoped_conn()}
  end
end
