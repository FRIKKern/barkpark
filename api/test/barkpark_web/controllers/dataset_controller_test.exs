defmodule BarkparkWeb.DatasetControllerTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  import Ecto.Query

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Dataset

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, _} = create_document_in!(ws, project, "post", %{}, "j10-7")

    tokens =
      for {role, perms} <- [
            owner: ~w(read write admin),
            admin: ~w(read write admin),
            member: ~w(read write)
          ],
          into: %{} do
        raw = "ds-#{role}-#{System.unique_integer([:positive])}"
        {:ok, token} = Auth.create_token(raw, "ds-#{role}", "production", perms)
        {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, to_string(role), "api_token")
        {role, raw}
      end

    %{ws: ws, project: project, tokens: tokens}
  end

  defp delete_dataset(raw, ws, project, name) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> delete("/w/#{ws.slug}/p/#{project.slug}/v1/datasets/#{name}")
  end

  defp dataset?(project, slug), do: Tenancy.get_dataset(project, slug) != nil

  defp bound_owner!(ws, dataset) do
    raw = "ds-bound-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ds-bound", dataset, ~w(read write admin))
    token |> Ecto.Changeset.change(dataset_bound: true) |> Repo.update!()
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner", "api_token")
    raw
  end

  for role <- [:owner, :admin] do
    test "an #{role} deletes the dataset and gets a receipt", %{
      ws: ws,
      project: project,
      tokens: tokens
    } do
      conn = delete_dataset(tokens[unquote(role)], ws, project, "j10-7")

      assert %{"deleted" => true, "dataset" => %{"slug" => "j10-7"}, "documents" => 1} =
               json_response(conn, 200)

      refute dataset?(project, "j10-7")
    end
  end

  test "a member is refused 403 and the dataset stays", %{
    ws: ws,
    project: project,
    tokens: tokens
  } do
    conn = delete_dataset(tokens.member, ws, project, "j10-7")

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    assert dataset?(project, "j10-7")
  end

  test "an admin of another workspace is refused", %{project: project, ws: ws} do
    other = create_workspace!()
    raw = "ds-stranger-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ds-stranger", "production", ~w(read write admin))
    {:ok, _} = TenancyAuth.create_membership(other.id, token.id, "owner", "api_token")

    conn = delete_dataset(raw, ws, project, "j10-7")

    assert conn.status in [403, 404]
    assert dataset?(project, "j10-7")
  end

  test "an unknown dataset is 404", %{ws: ws, project: project, tokens: tokens} do
    conn = delete_dataset(tokens.owner, ws, project, "j10-nope")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "production is refused 409 and stays", %{ws: ws, project: project, tokens: tokens} do
    {:ok, production} = Tenancy.get_or_create_dataset(project, "production")

    conn = delete_dataset(tokens.owner, ws, project, "production")

    assert %{"error" => %{"code" => "production_dataset_protected"}} = json_response(conn, 409)
    assert Repo.get(Dataset, production.id)
  end

  test "no token is refused and the dataset stays", %{ws: ws, project: project} do
    conn = scoped_conn() |> delete("/w/#{ws.slug}/p/#{project.slug}/v1/datasets/j10-7")
    assert conn.status in [401, 403]
    assert dataset?(project, "j10-7")
  end

  test "a token bound to one dataset cannot delete another", %{ws: ws, project: project} do
    {:ok, _} = create_document_in!(ws, project, "post", %{}, "j10-8")
    raw = bound_owner!(ws, "j10-8")

    conn = delete_dataset(raw, ws, project, "j10-7")

    assert %{"error" => %{"reason" => "dataset_not_bound"}} = json_response(conn, 403)
    assert dataset?(project, "j10-7")

    assert %{"deleted" => true} = json_response(delete_dataset(raw, ws, project, "j10-8"), 200)
  end

  test "a name that cannot be a dataset slug is 404, never a 500",
       %{ws: ws, project: project, tokens: tokens} do
    {:ok, _} = Tenancy.get_or_create_dataset(project, "production")

    names = ~w(production%00 j10-7%00 Production J10-7 producti%C3%B6n %FF j10-7.json -j10 _j10)

    for name <- [String.duplicate("a", 64) | names] do
      conn = delete_dataset(tokens.owner, ws, project, name)

      assert {name, 404, "not_found"} ==
               {name, conn.status, json_response(conn, 404)["error"]["code"]}
    end

    assert dataset?(project, "production")
    assert dataset?(project, "j10-7")
  end

  test "media another dataset embeds is refused 409 naming the file",
       %{ws: ws, project: project, tokens: tokens} do
    {:ok, file} = create_media_file_in!(ws, project, %{}, "j10-7")
    body = Barkpark.Media.WhereUsed.delivery_path(file)
    {:ok, _} = create_document_in!(ws, project, "post", %{"body" => body}, "production")

    conn = delete_dataset(tokens.owner, ws, project, "j10-7")

    assert %{"error" => %{"code" => "dataset_media_referenced", "details" => details}} =
             json_response(conn, 409)

    assert [%{"media_id" => media_id, "count" => 1}] = details["media"]
    assert media_id == file.id
    assert dataset?(project, "j10-7")
  end

  test "a token bound to the deleted dataset is dead when the name comes back",
       %{ws: ws, project: project, tokens: tokens} do
    raw = bound_owner!(ws, "j10-7")

    assert %{"tokens_revoked" => 1} =
             json_response(delete_dataset(tokens.owner, ws, project, "j10-7"), 200)

    {:ok, _} = Tenancy.get_or_create_dataset(project, "j10-7")

    assert delete_dataset(raw, ws, project, "j10-7").status == 401
    assert dataset?(project, "j10-7")
  end

  test "a cached surface config of the slug is dropped with the dataset",
       %{ws: ws, project: project, tokens: tokens} do
    alias Barkpark.Search.SurfaceConfigs

    {:ok, _} = SurfaceConfigs.upsert("documents", "j10-7", %{"zeroHitStrategy" => "none"}, ws.id)
    assert %{"zero_hit_strategy" => "none"} = SurfaceConfigs.get("documents", "j10-7", ws.id)

    assert %{"swept" => %{"search_surface_config" => 1}} =
             json_response(delete_dataset(tokens.owner, ws, project, "j10-7"), 200)

    assert SurfaceConfigs.get("documents", "j10-7", ws.id)["zero_hit_strategy"] == "drop_tokens"
  end

  test "the delete lands on the workspace audit chain with the token as actor",
       %{ws: ws, project: project, tokens: tokens} do
    %{id: id} = Tenancy.get_dataset(project, "j10-7")
    token = Repo.get_by!(Barkpark.Auth.ApiToken, label: "ds-owner")

    assert json_response(delete_dataset(tokens.owner, ws, project, "j10-7"), 200)

    assert [event] =
             Repo.all(
               from e in Event, where: e.workspace_id == ^ws.id and e.action == "dataset_deleted"
             )

    assert %{subject: ^id, category: "content_mutation", actor_type: "api_token"} = event
    assert event.actor_id == to_string(token.id)
    assert %{"dataset" => "j10-7", "documents" => 1} = event.metadata
  end

  test "GET /v1/capabilities advertises dataset.delete on this route", %{tokens: tokens} do
    manifest =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{tokens.owner}")
      |> get("/v1/capabilities")
      |> json_response(200)

    cmd = Enum.find(manifest["commands"], &(&1["id"] == "dataset.delete"))

    assert %{
             "noun" => "dataset",
             "verb" => "delete",
             "auth_tier" => "scoped_admin",
             "writes" => true,
             "http" => %{"method" => "DELETE", "path_template" => "/v1/datasets/:dataset"},
             "scoped_prefix" => "/w/:workspace_slug/p/:project_slug",
             "args" => [%{"name" => "dataset", "required" => true}]
           } = cmd
  end
end
