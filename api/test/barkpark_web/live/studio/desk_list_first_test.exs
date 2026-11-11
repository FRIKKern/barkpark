defmodule BarkparkWeb.Studio.DeskListFirstTest do
  @moduledoc """
  R12: a desk list's first page is in the page's first (dead) render, and
  the connected mount does not read it again when nothing changed: the dead
  render's read is handed over (`BarkparkWeb.Studio.ConnectHandoff`). A
  document written in between is a miss, and the list reads it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ConnectHandoff

  @dataset "production"
  @type_name "dlf_post"

  setup %{conn: conn} do
    prior = Application.get_env(:barkpark, :studio_connect_handoff)
    Application.put_env(:barkpark, :studio_connect_handoff, true)
    on_exit(fn -> Application.put_env(:barkpark, :studio_connect_handoff, prior) end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "dlf-#{suffix}", name: "First render"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "dlf-token-" <> Ecto.UUID.generate()
    default_ws = Tenancy.get_default_workspace()

    {:ok, token} =
      Auth.create_token(raw, "dlf", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "First posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    for {id, title} <- [{"dlf-a", "Alpha first"}, {"dlf-b", "Beta first"}] do
      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "status" => "published"},
          @dataset,
          scope
        )
    end

    me = self()
    handler = "desk-list-first-#{suffix}"

    :telemetry.attach_many(
      handler,
      [[:barkpark, :studio, :connect_handoff], [:barkpark, :desk, :pane_load]],
      fn
        [:barkpark, :studio, :connect_handoff], _, meta, _ -> send(me, {:handoff, meta.result})
        [:barkpark, :desk, :pane_load], _, meta, _ -> send(me, {:read, meta.kind, meta.source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{@type_name}",
     scope: scope}
  end

  @row ~s([data-pane-index="1"] a[data-desk-row])

  defp rows(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(@row)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Every list read reported so far, and by whom.
  defp list_reads(acc \\ []) do
    receive do
      {:read, :list, source} -> list_reads([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the first render holds the list's rows", %{conn: conn, path: path} do
    html = conn |> get(path) |> html_response(200)

    assert Enum.any?(rows(html), &(&1 =~ "Alpha first")),
           "no rows in the first render: #{inspect(rows(html))}"

    assert Enum.any?(rows(html), &(&1 =~ "Beta first"))
  end

  test "the connected mount takes the first render's rows and reads the list no more", %{
    conn: conn,
    path: path
  } do
    {:ok, view, html} = live(conn, path)
    assert Enum.any?(rows(html), &(&1 =~ "Alpha first"))

    render_async(view, 5_000)
    assert_received {:handoff, :hit}
    assert has_element?(view, @row, "Alpha first")
    assert has_element?(view, @row, "Beta first")

    # One read, in the first render; none once connected.
    assert list_reads() == [:first]
  end

  test "a document written between the first render and the connect is read", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    conn = get(conn, path)
    assert html_response(conn, 200) =~ "Alpha first"

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "dlf-c", "title" => "Gamma written meanwhile", "status" => "published"},
        @dataset,
        scope
      )

    :sys.get_state(ConnectHandoff)
    {:ok, view, _html} = live(conn)
    render_async(view, 5_000)

    assert_received {:handoff, :stale}
    assert has_element?(view, @row, "Gamma written meanwhile")
    assert list_reads() == [:first, :pane]
  end
end
