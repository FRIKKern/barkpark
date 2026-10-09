defmodule BarkparkWeb.MutateObjectBlockValidationTest do
  @moduledoc """
  task-839f9bebf5628c03 — barkpark-studio verifying task-152cacba913a4724 on
  guerrilla found a `richText` custom object block's declared `select` field
  (`callout.tone`, `options.list: ['info','warning','danger']`) accepting ANY
  value through `POST /v1/data/mutate`, 200, with no finding.

  Investigated against the real write door rather than assumed: the
  underlying check (`Content.Validation.object_block_findings/3`, wired into
  the v2 schema walk since #21802) already produces the right finding at the
  right path on CURRENT main — this file locks that in at the HTTP layer,
  which nothing previously did (every existing test called `Validation`
  directly, never through `POST /v1/data/mutate`). A declared object block's
  fields are validated the SAME way an ordinary object's fields are: an
  advisory on a non-enforcing dataset (the write still lands, `warnings`
  rides the 200 body), a refusal on an enforcing one (422, same path).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  @callout %{
    "name" => "callout",
    "fields" => [
      %{
        "name" => "tone",
        "type" => "select",
        "options" => %{"list" => ["info", "warning", "danger"]},
        "validation" => %{"required" => true}
      },
      %{"name" => "text", "type" => "text", "validation" => %{"required" => true}}
    ]
  }

  defp schema(dataset, scope) do
    Content.upsert_schema(
      %{
        "name" => "mobvpost",
        "title" => "MobvPost",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{
            "name" => "body",
            "type" => "richText",
            "editor" => "blocks",
            "blocks" => %{"of" => ["image", @callout]}
          }
        ]
      },
      dataset,
      scope
    )
  end

  defp mutate(conn, dataset, body) do
    mutation = %{
      "mutations" => [
        %{
          "create" => %{
            "_type" => "mobvpost",
            "doc_id" => "mobv-post-#{System.unique_integer([:positive])}",
            "title" => "T",
            "content" => %{"body" => body}
          }
        }
      ]
    }

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{dataset}", Jason.encode!(mutation))
  end

  @bad_body [
    %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]},
    %{"type" => "callout", "tone" => "loud", "text" => "Note"}
  ]

  describe "advisory on a non-enforcing dataset" do
    setup %{conn: conn} do
      ws = create_workspace!("mobv-ws-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "default")
      dataset = "production"
      {:ok, _} = schema(dataset, workspace_id: ws.id, project_id: proj.id)

      raw = "mobv-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(raw, "mobv", dataset, ["read", "write", "admin"], ws.id)

      {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw), dataset: dataset}
    end

    test "the write lands, and the finding rides `warnings` with a path into the block",
         %{conn: conn, dataset: dataset} do
      resp = mutate(conn, dataset, @bad_body)
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert [%{"operation" => "create"}] = body["results"]

      [warning] = body["warnings"]
      assert warning["code"] == "schema_validation"
      assert [finding] = warning["findings"]
      assert finding["code"] == "not_in_list"
      assert finding["path"] == "/body/1/tone"
      assert finding["params"]["allowed"] == ["info", "warning", "danger"]
    end

    test "a valid callout lands with no warnings key", %{conn: conn, dataset: dataset} do
      good_body = [%{"type" => "callout", "tone" => "info", "text" => "Note"}]
      resp = mutate(conn, dataset, good_body)
      assert resp.status == 200
      refute Map.has_key?(Jason.decode!(resp.resp_body), "warnings")
    end
  end

  describe "refusal on an enforcing dataset" do
    setup %{conn: conn} do
      dataset = "mobv_enf_#{System.unique_integer([:positive])}"

      previous = Application.get_env(:barkpark, Validation, [])
      Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
      on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

      ws = Barkpark.Tenancy.get_default_workspace()
      proj = Barkpark.Tenancy.get_default_project()
      {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
      {:ok, _} = schema(dataset, workspace_id: ws.id, project_id: proj.id)

      token = "mobv-enf-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(token, "mobv-enf", dataset, ["read", "write", "admin"], ws.id)

      {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), dataset: dataset}
    end

    test "the write is refused, 422, naming the same path", %{conn: conn, dataset: dataset} do
      resp = mutate(conn, dataset, @bad_body)
      assert resp.status == 422

      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      assert [finding] = body["error"]["findings"]
      assert finding["code"] == "not_in_list"
      assert finding["path"] == "/body/1/tone"
    end

    test "a valid callout still lands, 200", %{conn: conn, dataset: dataset} do
      good_body = [%{"type" => "callout", "tone" => "warning", "text" => "Note"}]
      resp = mutate(conn, dataset, good_body)
      assert resp.status == 200
    end
  end
end
