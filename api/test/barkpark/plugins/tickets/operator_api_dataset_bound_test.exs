defmodule Barkpark.Plugins.Tickets.OperatorApiDatasetBoundTest do
  @moduledoc """
  The operator inbox API (`/v1/tickets/inbox`, `/:id/answer`, `/:id/close`)
  takes `?dataset=`, else a default. For a token minted with an explicit
  dataset that default is the token's own dataset, never `production`: the
  request-level fence only compares a dataset the request names. Same rule as
  the Studio inbox (`StudioChrome.chrome_dataset/2`).
  """
  use BarkparkWeb.ConnCase, async: false

  # The Tickets plugin's routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Plugins.Tickets.Thread

  @own "bound-own"
  @prod "production"

  setup do
    ws = create_workspace!("tickets-bound-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")

    tickets =
      for {ds, subject} <- [{@prod, "TICKET-IN-PRODUCTION"}, {@own, "TICKET-IN-BOUND-OWN"}],
          into: %{} do
        {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)

        for schema_def <- Barkpark.Plugins.Tickets.register_schemas([]) do
          attrs =
            schema_def
            |> Map.from_struct()
            |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
            |> Map.new(fn {k, v} -> {to_string(k), v} end)

          {:ok, _} = Content.upsert_schema(attrs, ds, workspace_id: ws.id)
        end

        key = %{id: "key-#{ds}", name: "Kari", workspace_id: ws.id, dataset: ds}
        {:ok, ticket} = Thread.create(key, %{subject: subject, body: "hello"})
        {ds, Content.published_id(ticket.doc_id)}
      end

    {:ok, ws: ws, tickets: tickets}
  end

  defp bearer(ws, opts) do
    raw = "tickets-bound-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "tickets bound", @own, ["read", "write", "admin"], ws.id, opts)

    scoped_conn() |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp stored(ws, id, dataset) do
    {:ok, ticket} = Thread.get_for_operator(id, dataset, workspace_id: ws.id)
    ticket
  end

  describe "a dataset-bound token naming no dataset" do
    test "lists its own dataset's tickets, not production's", %{ws: ws} do
      body = bearer(ws, dataset_bound: true) |> get("/v1/tickets/inbox") |> response(200)

      assert body =~ "TICKET-IN-BOUND-OWN"
      refute body =~ "TICKET-IN-PRODUCTION"
    end

    test "cannot read, answer or close a production ticket", %{ws: ws, tickets: tickets} do
      id = tickets[@prod]
      before = stored(ws, id, @prod)

      assert bearer(ws, dataset_bound: true) |> get("/v1/tickets/inbox/#{id}") |> response(404)

      assert bearer(ws, dataset_bound: true)
             |> put_req_header("content-type", "application/json")
             |> post("/v1/tickets/#{id}/answer", Jason.encode!(%{body: "from the bound token"}))
             |> response(404)

      assert bearer(ws, dataset_bound: true) |> post("/v1/tickets/#{id}/close") |> response(404)

      assert stored(ws, id, @prod).content == before.content
    end

    test "answers a ticket of its own dataset", %{ws: ws, tickets: tickets} do
      assert bearer(ws, dataset_bound: true)
             |> put_req_header("content-type", "application/json")
             |> post("/v1/tickets/#{tickets[@own]}/answer", Jason.encode!(%{body: "hi"}))
             |> response(200)
    end
  end

  # A ticket key is a second way to write tickets: the key carries a dataset
  # and every ticket made with it lands there (task-d43ee29a26676189).
  describe "minting a ticket key with no dataset named" do
    defp mint_key(conn) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/v1/plugins/tickets/keys", Jason.encode!(%{name: "Kari"}))
      |> json_response(201)
    end

    defp create_ticket(raw_key) do
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/tickets", Jason.encode!(%{subject: "FROM-THE-KEY", body: "hello"}))
      |> response(201)
    end

    defp inbox(ws, dataset) do
      bearer(ws, []) |> get("/v1/tickets/inbox?dataset=#{dataset}") |> response(200)
    end

    test "a dataset-bound token's key is for its own dataset, and so are its tickets", %{ws: ws} do
      minted = bearer(ws, dataset_bound: true) |> mint_key()
      assert minted["key"]["dataset"] == @own

      create_ticket(minted["raw"])
      assert inbox(ws, @own) =~ "FROM-THE-KEY"
      refute inbox(ws, @prod) =~ "FROM-THE-KEY"
    end

    test "an unbound token's key is still for production (control)", %{ws: ws} do
      minted = bearer(ws, []) |> mint_key()
      assert minted["key"]["dataset"] == @prod

      create_ticket(minted["raw"])
      assert inbox(ws, @prod) =~ "FROM-THE-KEY"
    end
  end

  test "an unbound token naming no dataset still gets production (control)", %{ws: ws} do
    body = bearer(ws, []) |> get("/v1/tickets/inbox") |> response(200)

    assert body =~ "TICKET-IN-PRODUCTION"
    refute body =~ "TICKET-IN-BOUND-OWN"
  end
end
