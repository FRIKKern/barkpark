defmodule BarkparkWeb.Studio.DeskSingletonRootTest do
  @moduledoc """
  B13: the desk's root draws Barkpark's singletons as the TanStack Studio's
  root does: under a "Settings" divider, each a row that opens its one
  document by the type's own segment (`/_desk/<type>`), the root and the
  document and no list between. The divider and its rows come from the desk
  structure (`Barkpark.Structure`'s Settings group, `singleton: true`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "dsr_prefs"
  @root ~s([data-pane-index="0"])

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Shop prefs",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => @type_name, "title" => "The shop"},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dsr-token-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "dsr", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  test "the root draws the singletons under a Settings divider, each a row", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)

    assert has_element?(view, ~s(#{@root}[data-pane="types"]))
    assert has_element?(view, @root <> " div.desk-divider", "Settings")
    refute has_element?(view, @root <> " a[data-desk-row]", "Settings")

    row = @root <> ~s( a[data-desk-row][href="#{base}/#{@type_name}"])
    assert has_element?(view, row, "Shop prefs")
    assert has_element?(view, row <> " .pane-item-chevron")

    # The divider is no row: nothing in it to focus.
    html = view |> element(@root <> " div.desk-divider") |> render()
    refute html =~ "tabindex"
    refute html =~ "<a"
  end

  test "the row opens the document right of the root, no list between", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)
    view |> element(@root <> ~s( a[href="#{base}/#{@type_name}"])) |> render_click()
    render_async(view, 5_000)

    assert_patched(view, "#{base}/#{@type_name}")
    assert view |> render() |> then(&Regex.scan(~r/data-pane-index="(\d+)"/, &1)) |> length() == 2
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="doc"]))
  end

  test "an old link through the Settings list opens the document the same", %{
    conn: conn,
    base: base
  } do
    view = open(conn, "#{base}/settings;#{@type_name}")
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="doc"]))
    refute has_element?(view, ~s([data-pane-index="2"]))

    view = open(conn, "#{base}/settings")
    assert has_element?(view, @root)
    refute has_element?(view, ~s([data-pane-index="1"]))
  end
end
