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
  The scoped-canonical form of a flat Studio path (P3 of Scoped-by-URL).

  The flat `/studio/:dataset/...` URLs 302 to
  `/w/:ws/p/:proj/studio/:dataset/...` since the P3 cutover, so LiveView
  tests mount the scoped form directly. Seeds the Default workspace/project
  idempotently (the scoped route 404s on an unseeded tenancy — the flat
  surface used to tolerate that silently).

      live(conn, scoped_studio("/studio/production/post/p1"))
  """
  def scoped_studio(path) when is_binary(path) do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    "/w/#{ws.slug}/p/#{project.slug}" <> path
  end

  setup tags do
    Barkpark.DataCase.setup_sandbox(tags)
    # Restore the `:barkpark, :plugins` env to its unset boot baseline so a
    # leaked load-order list from a sibling test can't hide plugins from the
    # collectors this test exercises. See `Barkpark.DataCase.reset_plugins_env/0`.
    Barkpark.DataCase.reset_plugins_env()
    :ets.delete_all_objects(:barkpark_rate_limiter)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
