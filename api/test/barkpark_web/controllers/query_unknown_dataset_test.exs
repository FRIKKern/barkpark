defmodule BarkparkWeb.QueryUnknownDatasetTest do
  @moduledoc """
  task-8b96938b28964500: a dataset leaf the project does not own.

  `GET /v1/data/query/nosuchds/post` answered an admin token an ordinary empty
  page (200, count 0) and an anonymous caller a generic 404 "document not
  found". So `createClient({dataset: 'nosuchds', token}).docs('post').find()`
  resolved `[]`, and a typo'd dataset read as "no content yet". Both doors now
  answer a 404 that NAMES the dataset, identically for every principal, while
  a known dataset keeps its behaviour.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @admin_token "barkpark-test-unknown-dataset-admin"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "unknown-dataset-admin", "production", [
        "read",
        "write",
        "admin"
      ])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "production",
        scope
      )

    :ok
  end

  defp admin(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  # The error body minus its per-request id.
  defp error_of(resp),
    do: resp |> json_response(404) |> Map.fetch!("error") |> Map.delete("request_id")

  defp missing, do: "nosuchds#{System.unique_integer([:positive])}"

  test "the query door: admin and anonymous both get a 404 naming the dataset", %{conn: conn} do
    ds = missing()
    path = "/v1/data/query/#{ds}/post"

    anon = get(conn, path)
    authed = conn |> admin() |> get(path)

    assert anon.status == 404
    assert authed.status == 404, "an admin used to get 200 with an empty page"

    assert error_of(authed) == error_of(anon)
    assert error_of(authed)["message"] == "dataset #{inspect(ds)} not found"
  end

  test "the doc door: admin and anonymous both get a 404 naming the dataset", %{conn: conn} do
    ds = missing()
    path = "/v1/data/doc/#{ds}/post/p1"

    anon = get(conn, path)
    authed = conn |> admin() |> get(path)

    assert anon.status == 404
    assert authed.status == 404
    assert error_of(authed) == error_of(anon)
    assert error_of(authed)["message"] == "dataset #{inspect(ds)} not found"
  end

  test "CONTROL: a known dataset still answers 200 to an admin", %{conn: conn} do
    resp = conn |> admin() |> get("/v1/data/query/production/post")
    assert resp.status == 200
  end

  test "CONTROL: a missing DOCUMENT in a known dataset keeps its plain 404", %{conn: conn} do
    resp = conn |> admin() |> get("/v1/data/doc/production/post/no-such-doc")
    assert resp.status == 404
    assert error_of(resp)["message"] == "document not found"
  end
end
