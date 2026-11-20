defmodule BarkparkWeb.BulldocsIngestQuotaOnceTest do
  @moduledoc """
  Every request on the `:ingest` pipeline is judged for quota and suspension
  exactly once when it writes and never when it reads, whether the pipeline
  judges it or the ingest controller's write gate does. The routes are read
  from the router and counted a second way, from the plugins' `:ingest` routes
  plus the `/v1/paperflow` alias.

  A write by a pinned token, and by a token with no home seated in one
  workspace, is judged once, on the workspace it lands in. An action the ingest
  controller gains later, named in no list, is judged by the gate before it runs.

  The gate's three sets are pinned to their members: the actions where a seat
  in the default workspace wins, the actions the gate judges (the router's
  writing actions, counted a second way from the plugin's route declarations),
  and the routes that can add a Paper.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Bulldocs.Web.WriteGate
  alias Barkpark.Tenancy.Quota
  alias BarkparkWeb.BulldocsIngestController
  alias BarkparkWeb.Plugs.RequireWithinQuota

  @ds "production"

  setup do
    test = self()
    id = "quota-once-#{System.unique_integer([:positive])}"

    handler = fn _event, _measure, meta, _config ->
      if self() == test, do: send(test, {:judged, meta.workspace_id})
    end

    :telemetry.attach(id, [:barkpark, :quota, :judged], handler, nil)
    on_exit(fn -> :telemetry.detach(id) end)

    ws = create_workspace!()
    create_project!(ws, "default")
    raw = "quota-once-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "quota once", @ds, ["read", "write", "admin"], ws.id)
    %{ws: ws, raw: raw}
  end

  defp authed(raw) do
    scoped_conn()
    |> Plug.Conn.put_private(:barkpark_rate_limit_scope, "quota-once-#{raw}-#{unique()}")
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp unique, do: System.unique_integer([:positive])

  # A token with no home workspace, seated as a member in `ws` only.
  defp homeless!(ws) do
    raw = "quota-once-homeless-#{unique()}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "quota once homeless",
        dataset: @ds,
        permissions: ["read", "write", "admin"],
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")
    raw
  end

  defp judged(acc \\ []) do
    receive do
      {:judged, ws_id} -> judged([ws_id | acc])
    after
      0 -> acc
    end
  end

  defp fill(path) do
    Regex.replace(~r/[:*](\w+)/, path, fn
      _, "dataset" -> @ds
      _, _name -> "quota-once-#{unique()}"
    end)
  end

  # The router's routes whose pipelines include `:ingest`, each with a filled path.
  defp ingest_routes do
    for route <- BarkparkWeb.Router.__routes__(),
        path = fill(route.path),
        verb = route.verb |> to_string() |> String.upcase(),
        %{pipe_through: pipes} <- [Phoenix.Router.route_info(BarkparkWeb.Router, verb, path, "")],
        :ingest in pipes,
        do: %{route | path: path}
  end

  # Changing a member is a decision; update this row on purpose.
  test "the gate's sets hold exactly their members" do
    seat_default =
      ~w(sync apply_op propose apply_session_op append_session_event touch_session_conversation)a

    judged =
      ~w(ingest create sync apply_op propose ingest_session apply_session_op
         append_session_event touch_session_conversation)a

    creates = ~w(ingest create sync ingest_session)a
    assert {length(seat_default), length(judged), length(creates)} == {6, 9, 4}

    assert WriteGate.seat_default_actions() == seat_default
    assert Enum.sort(judged_actions(BarkparkWeb.Router.__routes__())) == Enum.sort(judged)

    assert RequireWithinQuota.ingest_creates() ==
             for(a <- creates, do: {BulldocsIngestController, a})

    declared =
      for {_verb, _path, plug, action, opts} <-
            Barkpark.Plugins.Registry.collect_routes(%{scope: :ingest}),
          plug == BulldocsIngestController and opts[:auth] == :ingest,
          do: %{plug: plug, plug_opts: action}

    assert length(judged_actions(declared)) == 9
  end

  # The actions of ingest controller `routes` that the gate judges.
  defp judged_actions(routes) do
    for %{plug: BulldocsIngestController, plug_opts: action} <- routes,
        BulldocsIngestController.judges_own_quota?(action),
        uniq: true,
        do: action
  end

  test "every route on the :ingest pipeline is judged once when it writes, never on a read", c do
    routes = ingest_routes()

    plugin =
      for {_verb, _path, _plug, _action, opts} <-
            Barkpark.Plugins.Registry.collect_routes(%{scope: :ingest}),
          is_list(opts) and opts[:auth] == :ingest,
          do: 1

    alias_routes = for %{path: "/v1/paperflow" <> _} <- BarkparkWeb.Router.__routes__(), do: 1

    assert routes != []
    assert length(routes) == length(plugin) + length(alias_routes)

    wrong =
      for route <- routes,
          expected = if(route.verb in [:get, :head], do: [], else: [c.ws.id]),
          dispatch(authed(c.raw), @endpoint, route.verb, route.path, %{}),
          (got = judged()) != expected,
          do: {route.verb, route.path, route.plug, route.plug_opts, got}

    assert wrong == [], "judged other than once per write: #{inspect(wrong, pretty: true)}"
  end

  test "each write is judged once, on the workspace it lands in", c do
    seat = create_workspace!()
    create_project!(seat, "default")

    for {raw, ws} <- [{c.raw, c.ws}, {homeless!(seat), seat}] do
      slug = "quota-once-#{unique()}"
      body = %{"slug" => slug, "title" => "Once", "blocks" => []}
      resp = dispatch(authed(raw), @endpoint, :post, "/v1/plugins/bulldocs/papers", body)
      assert judged() == [ws.id], resp.resp_body
    end
  end

  test "an ingest controller action named in no list is judged by the gate before it runs", c do
    conn =
      c.raw
      |> authed()
      |> bypass_through(BarkparkWeb.Router, [:ingest])
      |> post("/v1/plugins/bulldocs/papers", %{})

    assert judged() == []
    {:ok, _} = Quota.suspend(c.ws, "quota once")
    conn = Plug.Conn.assign(conn, :current_workspace, Repo.reload!(c.ws))

    conn = BulldocsIngestController.call(conn, :planted_write)

    assert conn.halted

    assert {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]} ==
             {403, "workspace_suspended"}

    assert judged() == [c.ws.id]
  end
end
