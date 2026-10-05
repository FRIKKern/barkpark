defmodule BarkparkWeb.Studio.StudioSharedPluginSchemaTest do
  @moduledoc """
  A member of a workspace other than Default opens a `mediaAsset` in Studio
  (task-be5eaec4a5b9e524). The schema is the Media plugin's shared row
  (`workspace_id` NULL); before it existed the editor answered "No schema for
  mediaAsset is installed in this dataset".
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Bootstrap

  @dataset "production"

  # Plugins-off: installs the Media plugin's mediaAsset schema.
  @moduletag :requires_plugins

  setup %{conn: conn} do
    {default_ws, default_project} = ensure_default_scope!()

    {:ok, 2} =
      Bootstrap.install_for_plugin(
        %{name: "media", module: Barkpark.Plugins.Media},
        {default_ws.id, default_project.id}
      )

    ws = create_workspace!("shared-schema-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @dataset)
    opts = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "doc_id" => "cover-asset",
          "title" => "Cover",
          "content" => %{"altText" => %{"eng" => "A dog"}}
        },
        @dataset,
        opts
      )

    {:ok, conn: member_conn(conn, ws), ws: ws, proj: proj}
  end

  defp member_conn(conn, ws) do
    raw = "shared-schema-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "shared-schema",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp asset_path(ctx),
    do: "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/#{@dataset}/studio/mediaAsset/cover-asset"

  test "the mediaAsset editor opens with its alt text field", ctx do
    {:ok, view, html} = live(ctx.conn, asset_path(ctx))
    refute html =~ "No schema for"

    html = view |> element(~s(button[phx-value-group="metadata"])) |> render_click()
    assert html =~ "Alt text"
    assert html =~ "A dog"
  end

  test "control: without the shared row the same page has no schema", ctx do
    from(s in SchemaDefinition,
      where: s.name == "mediaAsset" and is_nil(s.workspace_id) and is_nil(s.dataset_id)
    )
    |> Repo.delete_all()

    {:ok, _view, html} = live(ctx.conn, asset_path(ctx))
    assert html =~ "No schema for"
  end
end
