defmodule BarkparkWeb.ListenDatedPathTest do
  @moduledoc """
  task-e5af22d327a92a44: `@sanity/client`'s `listen()` opens
  `<apiHost>/v<apiVersion>/data/listen/<dataset>` at the client's own dated
  apiVersion (`2025-02-19`, `2021-03-25`, `X`). Only `/v1` existed, so it 404'd.
  The dated path is the same stream behind the same gates.
  """
  use BarkparkWeb.ConnCase, async: true

  @router BarkparkWeb.Router

  test "every apiVersion routes to the /v1 listen action" do
    for version <- ["1", "2025-02-19", "2021-03-25", "X"] do
      path = "/w/acme/p/site/v#{version}/data/listen/production"
      info = Phoenix.Router.route_info(@router, "GET", path, "localhost")
      assert {info.plug, info.plug_opts} == {BarkparkWeb.ListenController, :listen}, path
    end
  end

  test "the dated path keeps the /v1 path's credential gate" do
    {:ok, ws} = Barkpark.Tenancy.create_workspace(%{slug: "listen-dated", name: "Listen dated"})
    {:ok, _} = Barkpark.Tenancy.create_project(ws, %{slug: "site", name: "Site"})

    statuses =
      for version <- ["1", "2025-02-19"] do
        scoped_conn()
        |> get("/w/listen-dated/p/site/v#{version}/data/listen/production")
        |> Map.fetch!(:status)
      end

    # No credential: refused the same way on both, never a 404.
    assert [same, same] = statuses
    assert same in [401, 403]
  end
end
