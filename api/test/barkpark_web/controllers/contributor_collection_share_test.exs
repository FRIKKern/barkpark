defmodule BarkparkWeb.ContributorCollectionShareTest do
  @moduledoc """
  task-e867294fdbcf6f55: a published media collection's share link is what
  anonymous visitors see, so a `contributor` (draft-only) seat may not turn it
  on or off. `Share.write_share_link/4` published the folder with opts that
  dropped `:caller_context`, so the seat gate passed. A member shares and
  revokes as before.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Media.Storage.Collections
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  setup do
    {:ok, ws_id: TenancyFixtures.default_workspace_id!()}
  end

  defp seated(ws_id, role) do
    raw = "ccs-#{role}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ccs #{role}", @dataset, ["read", "write"], ws_id)

    Membership
    |> Repo.get_by!(principal_id: token.id, principal_type: "api_token", workspace_id: ws_id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()

    raw
  end

  defp as(raw),
    do:
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

  defp folder!(ws_id) do
    {:ok, folder} = Collections.create_folder("Shared", @dataset, workspace_id: ws_id)
    folder.doc_id |> Content.published_id()
  end

  defp share_link(id, ws_id) do
    {:ok, doc} = Content.get_document(id, "mediaCollection", @dataset, workspace_id: ws_id)
    (doc.content || %{})["shareLink"]
  end

  defp drafts(id, ws_id),
    do: Content.get_document("drafts." <> id, "mediaCollection", @dataset, workspace_id: ws_id)

  defp refused!(conn) do
    body = json_response(conn, 403)
    assert body["error"]["reason"] == "publish_not_permitted", inspect(body)
  end

  test "a contributor may not share a published collection, nor leave a draft fork", %{
    ws_id: ws_id
  } do
    id = folder!(ws_id)
    contributor = seated(ws_id, "contributor")

    refused!(as(contributor) |> post("/v1/media/#{@dataset}/collections/#{id}/share", "{}"))
    assert share_link(id, ws_id) in [nil, %{}]
    assert {:error, _} = drafts(id, ws_id)
  end

  test "a contributor may not revoke a published collection's share", %{ws_id: ws_id} do
    id = folder!(ws_id)
    member = seated(ws_id, "member")
    contributor = seated(ws_id, "contributor")

    assert json_response(
             as(member) |> post("/v1/media/#{@dataset}/collections/#{id}/share", "{}"),
             200
           )

    before = share_link(id, ws_id)
    assert before

    refused!(as(contributor) |> delete("/v1/media/#{@dataset}/collections/#{id}/share"))
    assert share_link(id, ws_id) == before
  end

  test "a member shares and revokes as before", %{ws_id: ws_id} do
    id = folder!(ws_id)
    member = seated(ws_id, "member")

    assert json_response(
             as(member) |> post("/v1/media/#{@dataset}/collections/#{id}/share", "{}"),
             200
           )

    assert share_link(id, ws_id)

    assert json_response(
             as(member) |> delete("/v1/media/#{@dataset}/collections/#{id}/share"),
             200
           )
  end
end
