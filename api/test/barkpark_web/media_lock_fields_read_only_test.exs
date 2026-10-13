defmodule BarkparkWeb.MediaLockFieldsReadOnlyTest do
  @moduledoc """
  The media checkout lock is the server's (task-d483903133c370e1). The Media
  plugin's mediaAsset schema marks `checkedOutBy` / `checkedOutAt` as
  `"readOnly": true`, so:

    * the mutate door refuses a non-admin write that moves the lock (#21536);
    * the Studio Classic form shows them without an input, so a save never
      posts them and the stored lock survives;
    * checkout / undo-checkout still write them (server code, not a client door;
      covered in `account_session_media_write_test.exs`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Plugins.Bootstrap

  @dataset "production"
  @writer "barkpark-test-medialock-writer"
  @admin "barkpark-test-medialock-admin"
  @holder "user:holder-1"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()

    {:ok, 2} =
      Bootstrap.install_for_plugin(
        %{name: "media", module: Barkpark.Plugins.Media},
        {ws.id, project.id}
      )

    {:ok, _} = Auth.create_token(@writer, "medialock-writer", @dataset, ["read", "write"], ws.id)

    {:ok, _} =
      Auth.create_token(@admin, "medialock-admin", @dataset, ["read", "write", "admin"], ws.id)

    id = "asset-lock-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "doc_id" => id,
          "title" => "Cover",
          "content" => %{"checkedOutBy" => @holder, "checkedOutAt" => "2026-10-06T00:00:00Z"}
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

  test "a non-admin write cannot move the lock; a writable field still saves", ctx do
    resp = mutate_set(@writer, ctx.id, %{"checkedOutBy" => "user:attacker"})
    assert resp.status == 422, resp.resp_body
    assert Jason.decode!(resp.resp_body)["error"]["details"]["checkedOutBy"]
    assert stored(ctx.id, ctx.ws_id)["checkedOutBy"] == @holder

    ok = mutate_set(@writer, ctx.id, %{"description" => "A mountain"})
    assert ok.status == 200, ok.resp_body
    assert stored(ctx.id, ctx.ws_id)["checkedOutBy"] == @holder
  end

  test "an admin keeps the write", ctx do
    resp = mutate_set(@admin, ctx.id, %{"checkedOutBy" => ""})
    assert resp.status == 200, resp.resp_body
  end

  # Studio matches the server rule (#21536): display-only for a member, the
  # ordinary input for an admin, who may still change a readOnly field.
  defp metadata_tab(conn, id) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{id}"))
    view |> element(~s(button[phx-value-group="metadata"])) |> render_click()
  end

  defp member_conn(conn, ws_id) do
    raw = "medialock-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token(raw),
        label: "medialock-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Barkpark.Repo.insert()

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  test "a member sees the lock fields without an input", %{conn: conn, id: id, ws_id: ws_id} do
    html = metadata_tab(member_conn(conn, ws_id), id)

    assert html =~ ~s(data-readonly-field="checkedOutBy")
    refute html =~ ~s(name="doc[checkedOutBy]")
    refute html =~ ~s(name="doc[checkedOutAt]")
  end

  test "an admin keeps an input for a readOnly field", %{conn: conn, id: id} do
    html = metadata_tab(Plug.Test.init_test_session(conn, %{"api_token" => @admin}), id)

    assert html =~ ~s(name="doc[checkedOutBy]")
    refute html =~ ~s(data-readonly-field="checkedOutBy")
  end
end
