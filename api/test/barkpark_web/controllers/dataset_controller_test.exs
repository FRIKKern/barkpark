defmodule BarkparkWeb.DatasetControllerTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo, Tenancy}
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
             "http" => %{"method" => "DELETE", "path_template" => "/v1/datasets/:name"},
             "scoped_prefix" => "/w/:workspace_slug/p/:project_slug",
             "args" => [%{"name" => "name", "required" => true}]
           } = cmd
  end
end
