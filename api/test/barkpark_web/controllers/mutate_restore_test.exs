defmodule BarkparkWeb.MutateRestoreTest do
  @moduledoc """
  task-419052f535f92f4b. A gyl to staging copy through `bp export` and
  `bp import` changed 24,448 of 56,967 documents: every created document got
  its schema's `initial_values` (product `isHidden: false` and others), and
  titleless types got a title derived from `list_preview.title`. A restore
  must write the exported document as it was.

  `restore: true` on the mutate door turns both off for that request. It is
  off by default, so every other caller keeps the defaults.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  @ds "production"

  setup do
    token = "barkpark-dev-token-restore-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      "mutate-restore",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    type = "restoreprod_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Restore product",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "isHidden", "type" => "boolean"}
          ],
          "initial_values" => %{"isHidden" => false},
          "list_preview" => %{"title" => "name"}
        },
        @ds
      )

    %{token: token, type: type}
  end

  defp mutate(ctx, body) do
    ctx.conn
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@ds}", Jason.encode!(body))
  end

  defp create_body(ctx, id) do
    %{
      "mutations" => [
        %{"createOrReplace" => %{"_id" => id, "_type" => ctx.type, "name" => "Exported name"}}
      ]
    }
  end

  defp stored(ctx, id) do
    {:ok, doc} = Content.get_document("drafts." <> id, ctx.type, @ds)
    doc
  end

  test "without restore, a create gets initial values and a derived title", ctx do
    id = "restore-off-#{System.unique_integer([:positive])}"
    assert mutate(ctx, create_body(ctx, id)).status == 200

    doc = stored(ctx, id)
    assert doc.content["isHidden"] == false
    assert doc.title == "Exported name"
  end

  test "restore: true writes the document as sent", ctx do
    id = "restore-on-#{System.unique_integer([:positive])}"
    resp = mutate(ctx, Map.put(create_body(ctx, id), "restore", true))
    assert resp.status == 200
    refute Map.has_key?(Jason.decode!(resp.resp_body), "warnings")

    doc = stored(ctx, id)
    refute Map.has_key?(doc.content, "isHidden")
    assert doc.content["name"] == "Exported name"
    assert doc.title in [nil, ""]
  end

  test "a restore value that is not a boolean is refused", ctx do
    id = "restore-bad-#{System.unique_integer([:positive])}"
    resp = mutate(ctx, Map.put(create_body(ctx, id), "restore", "yes"))
    assert resp.status == 400
    assert %{"error" => %{"code" => "malformed"}} = Jason.decode!(resp.resp_body)
    assert {:error, _} = Content.get_document("drafts." <> id, ctx.type, @ds)
  end
end
