defmodule BarkparkWeb.Studio.DeskListHeaderButtonsTest do
  @moduledoc """
  A list pane's Create new (+) and List options (…) are icon buttons like the
  document header's, not bare browser buttons (feel walk 2026-11-13: grey 2 px
  outset boxes, 13x20 px, spread across the header in both themes).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.Style

  @dataset "production"
  @type_name "dlhb_post"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Header posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(@type_name, %{"doc_id" => "dlhb-one", "title" => "One"}, @dataset)

    raw = "dlhb-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "dlhb", @dataset, ["read", "write", "admin"], ws.id)
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  @header ~s([data-pane-index="1"] .pane-header)

  test "Create new and List options wear the header's icon-button look", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)

    create = @header <> ~s( button.dk-create-new.dk-doc-menu-button.icon-btn)
    options = @header <> ~s( button.dk-list-options.dk-doc-menu-button.icon-btn)

    assert has_element?(view, create <> ~s([data-tip="Create new document"] svg))
    assert has_element?(view, options <> ~s([data-tip="Show more"]))
    # The tip is the desk's own; a title would draw the browser's beside it.
    refute has_element?(view, create <> "[title]")
    refute has_element?(view, options <> "[title]")
  end

  test "the two sit together at the header's right, the first pushed there" do
    css = Style.sheet(%{}) |> rendered_to_string()
    assert css =~ ".dk .dk-create-new, .dk .dk-list-options { margin-left: auto;"
    assert css =~ ".dk .dk-create-new + .dk-list-options { margin-left: 0; }"
  end
end
