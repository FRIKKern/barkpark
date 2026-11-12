defmodule BarkparkWeb.Live.ChromeDatasetBoundDefaultTest do
  @moduledoc """
  A Studio page whose URL path names no dataset reads the dataset the chrome
  picks for it. For a token minted with an explicit dataset that pick is the
  token's own dataset: never the `production` default, and never a `?dataset=`
  the caller adds. The same rule the media controller applies when a request
  names none.

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

    # The plug refuses the query on a scoped page load. A socket join names
    # its own URL and runs no plug, so the chrome must not take the query.
    test "a socket join that adds ?dataset= stays on its own dataset", ctx do
      conn = admin_conn(ctx.conn, ctx.ws, dataset_bound: true)
      path = "#{ctx.base}/tickets"

      assert get(conn, "#{path}?dataset=#{@default}").status == 403

      # The join URL is the dead render's own; add the query to it, as a
      # client that names its own URL on connect can.
      dead = get(conn, path)
      forged = %{dead | query_string: "dataset=#{@default}"}
      {:ok, view, _} = Phoenix.LiveViewTest.__live__(forged, nil, [])
      html = render(view)

      refute html =~ @default_ticket
      assert html =~ @own_ticket
      assert dataset_of(view) == @own
    end

    test "the flat inbox with ?dataset= stays on its own dataset", ctx do
      conn = admin_conn(ctx.conn, ctx.ws, dataset_bound: true)

      {:ok, view, _} = live(conn, "/studio/tickets?dataset=#{@default}")
      html = render(view)

      refute html =~ @default_ticket
      assert html =~ @own_ticket
      assert dataset_of(view) == @own
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

    test "the flat inbox still takes ?dataset=", %{conn: conn, ws: ws} do
      {:ok, view, _} = live(admin_conn(conn, ws, []), "/studio/tickets?dataset=#{@own}")

      assert dataset_of(view) == @own
      assert render(view) =~ @own_ticket
    end

    # A list or a map is not a dataset name. It used to become the `:dataset`
    # assign and crash the mount in the top menu.
    for {shape, query} <- [{"list", "dataset[]=x"}, {"map", "dataset[a]=x"}] do
      test "a ?dataset= that is a #{shape} mounts on the default dataset", %{conn: conn, ws: ws} do
        {:ok, view, _} = live(admin_conn(conn, ws, []), "/studio/tickets?#{unquote(query)}")

        assert dataset_of(view) == @default
        assert render(view) =~ @default_ticket
      end
    end
  end
end
