defmodule BarkparkWeb.Plugs.BoundDatasetResolversTest do
  @moduledoc """
  `RequireIngestToken` and `RequireBearerOrSessionToken` resolve a token too,
  and so hold its dataset binding the way `RequireToken` does
  (`BarkparkWeb.Plugs.BoundDataset.resolve/2`, task-b70064432deebe6d): a named
  other dataset is refused, and a request naming none gets the token's own.

  The ingest plug ran no fence at all: a dataset-bound admin token could name
  any dataset on the sheets and bulldocs ingest routes.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.{RequireBearerOrSessionToken, RequireIngestToken}

  @own "bound-own"

  setup do
    ws = create_workspace!("bound-resolvers-#{System.unique_integer([:positive])}")
    {:ok, ws: ws}
  end

  defp conn_as(ws, opts, params) do
    raw = "bound-resolvers-" <> Ecto.UUID.generate()
    perms = ["read", "write", "admin"]
    {:ok, _} = Auth.create_token(raw, "bound resolvers", @own, perms, ws.id, opts)

    %{Plug.Test.conn(:get, "/") | params: params}
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  for plug <- [RequireIngestToken, RequireBearerOrSessionToken] do
    describe "#{inspect(plug)}" do
      test "a dataset-bound token naming another dataset is refused", %{ws: ws} do
        conn = conn_as(ws, [dataset_bound: true], %{"dataset" => "production"})
        conn = unquote(plug).call(conn, unquote(plug).init([]))

        assert conn.halted
        assert conn.status == 403
        assert conn.resp_body =~ "dataset_not_bound"
      end

      test "a dataset-bound token naming none gets its own dataset", %{ws: ws} do
        conn = conn_as(ws, [dataset_bound: true], %{"a" => "1"})
        conn = unquote(plug).call(conn, unquote(plug).init([]))

        refute conn.halted
        assert conn.params == %{"a" => "1", "dataset" => @own}
      end

      test "an unbound token is untouched (control)", %{ws: ws} do
        for params <- [%{"a" => "1"}, %{"dataset" => "production"}] do
          conn = conn_as(ws, [], params)
          conn = unquote(plug).call(conn, unquote(plug).init([]))

          refute conn.halted
          assert conn.params == params
        end
      end
    end
  end

  test "an ingest route refuses a bound admin token that names another dataset", %{ws: ws} do
    raw = "bound-resolvers-" <> Ecto.UUID.generate()
    perms = ["read", "write", "admin"]
    {:ok, _} = Auth.create_token(raw, "bound ingest", @own, perms, ws.id, dataset_bound: true)

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get("/v1/plugins/sheets/nothing-here/export.csv?dataset=production")

    assert resp.status == 403
    assert resp.resp_body =~ "dataset_not_bound"
  end
end
