defmodule BarkparkWeb.Studio.MediaLiveEditMetadataTest do
  @moduledoc """
  The Media tab's asset panel can open an asset's details (task-aab4c14b96bc3af1).

  `bp-asset-explorer` shows "Edit metadata" (alt text, caption) only when the
  element carries `data-open-path`; the Media tab never passed it. It is passed
  only where the mediaAsset schema is installed, so the button never leads to
  "Studio could not open this document".
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    raw = "media-edit-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "media-edit",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  defp open_path(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("bp-asset-explorer")
    |> LazyHTML.attribute("data-open-path")
  end

  test "with the mediaAsset schema installed, the explorer can open an asset's document",
       %{conn: conn} do
    # The real production schema, as media_asset_alt_text_test.exs reads it.
    {:ok, _} =
      Path.join([:code.priv_dir(:barkpark), "plugins", "media", "schemas", "media_asset.json"])
      |> File.read!()
      |> Jason.decode!()
      |> Content.upsert_schema(@dataset)

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/media"))

    assert open_path(html) == [scoped_studio("/d/#{@dataset}/studio/mediaAsset")]
  end

  # A workspace other than Default reads the Media plugin's SHARED mediaAsset
  # row (workspace_id NULL, task-be5eaec4a5b9e524), so its Media tab offers
  # Edit metadata too.
  test "outside Default, the shared schema offers Edit metadata", %{conn: conn} do
    {default_ws, default_project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, 2} =
      Barkpark.Plugins.Bootstrap.install_for_plugin(
        %{name: "media", module: Barkpark.Plugins.Media},
        {default_ws.id, default_project.id}
      )

    {ws, proj, conn} = other_workspace(conn)

    assert {:ok, %{workspace_id: nil}} =
             Content.resolve_schema("mediaAsset", @dataset,
               workspace_id: ws.id,
               project_id: proj.id
             )

    {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media")

    assert open_path(html) == ["/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/mediaAsset"]
  end

  test "without any mediaAsset schema, the explorer offers no Edit metadata", %{conn: conn} do
    # The app's boot installs the shared row outside the sandbox; drop it here.
    Barkpark.Repo.delete_all(
      from(s in Barkpark.Content.SchemaDefinition,
        where: s.name == "mediaAsset" and is_nil(s.workspace_id)
      )
    )

    {ws, proj, conn} = other_workspace(conn)

    assert :error =
             Content.resolve_schema("mediaAsset", @dataset,
               workspace_id: ws.id,
               project_id: proj.id
             )

    {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media")

    assert open_path(html) == []
  end

  defp other_workspace(conn) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Barkpark.Tenancy.create_workspace(%{slug: "me-#{suffix}", name: "Other Media WS"})

    {:ok, proj} = Barkpark.Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "media-edit-ws-#{suffix}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "media-edit-ws", @dataset, ["read", "write"], ws.id)

    {ws, proj, Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end
end
