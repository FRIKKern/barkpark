defmodule BarkparkWeb.Live.ChromeDatasetBoundDefaultTest do
  @moduledoc """
  A Studio page whose URL names no dataset reads the dataset the chrome picks
  for it. For a token minted with an explicit dataset that pick is the token's
  own dataset, never the `production` default: the same rule the media
  controller applies when a request names none.

  Shown on the two scoped pages that read documents by that pick: the Tickets
  inbox and workspace Settings.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Plugins.Tickets.Thread

  @own "bound-own"
  @default "production"
  @own_ticket "TICKET-IN-THE-BOUND-DATASET"
  @default_ticket "TICKET-IN-PRODUCTION"

  setup %{conn: conn} do
    ws = create_workspace!("chrome-bound-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")

    for {ds, subject} <- [{@own, @own_ticket}, {@default, @default_ticket}] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
      register_ticket_schema!(ds, workspace_id: ws.id)

      key = %{id: "key-#{ds}", name: "Kari", workspace_id: ws.id, dataset: ds}
      {:ok, _} = Thread.create(key, %{subject: subject, body: "hello"})
    end

    {:ok, conn: conn, ws: ws, base: "/w/#{ws.slug}/p/default/studio"}
  end

  defp register_ticket_schema!(dataset, scope) do
    for schema_def <- Barkpark.Plugins.Tickets.register_schemas([]) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  # A workspace admin seat, signed into the Studio with the token.
  defp admin_conn(conn, ws, opts) do
    raw = "chrome-bound-tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "chrome bound", @own, ["read", "write", "admin"], ws.id, opts)

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp dataset_of(view), do: :sys.get_state(view.pid).socket.assigns[:dataset]

  describe "a dataset-bound token on a page whose URL names no dataset" do
    test "the Tickets inbox lists its own dataset's tickets", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(admin_conn(conn, ws, dataset_bound: true), "#{base}/tickets")
      html = render(view)

      refute html =~ @default_ticket
      assert html =~ @own_ticket
      assert dataset_of(view) == @own
    end

    test "workspace Settings reads its own dataset", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(admin_conn(conn, ws, dataset_bound: true), "#{base}/settings")

      assert dataset_of(view) == @own
    end

    test "naming the other dataset in the query is refused on the page load (the plug)", ctx do
      conn = admin_conn(ctx.conn, ctx.ws, dataset_bound: true)

      assert get(conn, "#{ctx.base}/tickets?dataset=#{@default}").status == 403
    end
  end

  describe "an unbound token (control)" do
    test "the Tickets inbox still lists production", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(admin_conn(conn, ws, []), "#{base}/tickets")
      html = render(view)

      assert dataset_of(view) == @default
      assert html =~ @default_ticket
      refute html =~ @own_ticket
    end
  end
end
