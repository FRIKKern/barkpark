defmodule BarkparkWeb.MediaAssetSystemFieldsReadOnlyTest do
  @moduledoc """
  An asset's file fields are the server's (task-08b6c963d72ce983). The
  mediaAsset schema marks `mediaFileId`, `fileInfo`, `bp_asset_kind`,
  `bp_processing_status`, `bp_cdn_status` and `bp_external_processing`
  `"readOnly": true`: a member who could edit `fileInfo.url` could break the
  asset for every document that uses it. Their writers (upload, processing,
  CDN, the processing callback) are server code with no caller context, which
  `Barkpark.Content.ReadOnlyFields` never refuses; the media suites cover them.

  The editor also opens on Metadata (alt text, caption), the reason a member
  presses "Edit metadata", instead of the file internals.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Plugins.Bootstrap

  @dataset "production"
  @writer "barkpark-test-assetsys-writer"
  @admin "barkpark-test-assetsys-admin"
  @file_info %{
    "url" => "/media/files/a.jpg",
    "path" => "a.jpg",
    "mimeType" => "image/jpeg",
    "size" => "10",
    "originalName" => "a.jpg",
    "width" => "1",
    "height" => "1"
  }
  @system ~w(mediaFileId fileInfo bp_asset_kind bp_processing_status bp_cdn_status bp_external_processing)

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()

    {:ok, 2} =
      Bootstrap.install_for_plugin(
        %{name: "media", module: Barkpark.Plugins.Media},
        {ws.id, project.id}
      )

    {:ok, _} = Auth.create_token(@writer, "assetsys-writer", @dataset, ["read", "write"], ws.id)

    {:ok, _} =
      Auth.create_token(@admin, "assetsys-admin", @dataset, ["read", "write", "admin"], ws.id)

    id = "asset-sys-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "doc_id" => id,
          "title" => "Cover",
          "content" => %{
            "mediaFileId" => "f-1",
            "fileInfo" => @file_info,
            "bp_asset_kind" => "image",
            "bp_processing_status" => "ready"
          }
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    %{id: id, ws_id: ws.id}
  end

  defp mutate_set(token, id, set) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [%{"patch" => %{"id" => id, "type" => "mediaAsset", "set" => set}}]
      })
    )
  end

  defp stored(id, ws_id) do
    {:ok, doc} =
      Content.get_document("drafts." <> id, "mediaAsset", @dataset, workspace_id: ws_id)

    doc.content
  end

  defp member_conn(conn, ws_id) do
    raw = "assetsys-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token(raw),
        label: "assetsys-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Barkpark.Repo.insert()

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, id), do: live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{id}"))

  defp file_tab(view), do: view |> element(~s(button[phx-value-group="file"])) |> render_click()

  test "a non-admin write cannot move a file field; resending the stored value passes", ctx do
    moved = Map.put(@file_info, "url", "https://elsewhere.example/x.jpg")
    resp = mutate_set(@writer, ctx.id, %{"fileInfo" => moved})
    assert resp.status == 422, resp.resp_body
    assert Jason.decode!(resp.resp_body)["error"]["details"]["fileInfo"]
    assert stored(ctx.id, ctx.ws_id)["fileInfo"] == @file_info

    status = mutate_set(@writer, ctx.id, %{"bp_processing_status" => "failed"})
    assert status.status == 422, status.resp_body

    same = mutate_set(@writer, ctx.id, %{"fileInfo" => @file_info, "description" => "Fjell"})
    assert same.status == 200, same.resp_body
  end

  test "an admin keeps the write", ctx do
    resp = mutate_set(@admin, ctx.id, %{"bp_processing_status" => "failed"})
    assert resp.status == 200, resp.resp_body
  end

  test "the editor opens on Metadata", %{conn: conn, id: id, ws_id: ws_id} do
    {:ok, _view, html} = open(member_conn(conn, ws_id), id)

    assert html =~
             ~r/aria-selected="true"[^>]*phx-value-group="metadata"|phx-value-group="metadata"[^>]*aria-selected="true"/

    assert html =~ ~s(name="doc[altText])
  end

  test "a member sees the file fields without an input", %{conn: conn, id: id, ws_id: ws_id} do
    {:ok, view, _} = open(member_conn(conn, ws_id), id)
    html = file_tab(view)

    for name <- @system do
      assert html =~ ~s(data-readonly-field="#{name}"), "#{name} is not shown display-only"
      refute html =~ ~s(name="doc[#{name}]), "#{name} still has an input"
    end
  end

  # The form posts no system field for a member; the save must keep them, not
  # read their absence as a removal (which the server would also refuse).
  test "a member's Classic save keeps the file fields", %{conn: conn, id: id, ws_id: ws_id} do
    {:ok, view, _} = open(member_conn(conn, ws_id), id)

    view
    |> form("#editor-form", doc: %{"description" => "Et fjell"})
    |> render_change()

    content = stored(id, ws_id)
    assert content["description"] == "Et fjell"
    assert content["fileInfo"] == @file_info
    assert content["mediaFileId"] == "f-1"
    assert content["bp_processing_status"] == "ready"
  end

  test "an admin keeps the inputs", %{conn: conn, id: id} do
    {:ok, view, _} = open(Plug.Test.init_test_session(conn, %{"api_token" => @admin}), id)
    html = file_tab(view)

    assert html =~ ~s(name="doc[fileInfo].url")
    assert html =~ ~s(name="doc[bp_processing_status]")
  end
end
