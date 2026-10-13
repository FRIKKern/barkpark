defmodule BarkparkWeb.MutatePortableTextAdvisoryTest do
  @moduledoc """
  task-2d96f71d3fe52ee7 — a Sanity Portable Text array/block
  (`_type: "block"`, `children`, `markDefs`, `listItem`) written to a
  richText field stores silently and renders broken in Studio, which reads
  PortableDoc blocks (keyed `"type"`, no underscore) only. Same
  ADVISE/ENFORCE door every other schema finding already uses: a
  non-enforcing dataset gets a `warnings` advisory naming the block and the
  write still lands; an enforcing one refuses 422.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  defp schema(dataset, scope) do
    Content.upsert_schema(
      %{
        "name" => "ptpost",
        "title" => "PtPost",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "body", "type" => "richText", "editor" => "blocks"}
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
            "_type" => "ptpost",
            "doc_id" => "pt-post-#{System.unique_integer([:positive])}",
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

  @pt_body [
    %{
      "_type" => "block",
      "_key" => "a1",
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "text" => "Hello from Sanity"}]
    }
  ]

  @portabledoc_body [
    %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]}
  ]

  describe "advisory on a non-enforcing dataset" do
    setup %{conn: conn} do
      ws = create_workspace!("pt-ws-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "default")
      dataset = "production"
      {:ok, _} = schema(dataset, workspace_id: ws.id, project_id: proj.id)

      raw = "pt-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(raw, "pt", dataset, ["read", "write", "admin"], ws.id)

      {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw), dataset: dataset}
    end

    test "the write lands, and the finding rides `warnings` naming the block",
         %{conn: conn, dataset: dataset} do
      resp = mutate(conn, dataset, @pt_body)
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert [%{"operation" => "create"}] = body["results"]

      [warning] = body["warnings"]
      assert warning["code"] == "schema_validation"
      assert [finding] = warning["findings"]
      assert finding["code"] == "portable_text_not_portabledoc"
      assert finding["path"] == "/body/0"
    end

    test "a PortableDoc block (the server's own convention) lands with no warnings key",
         %{conn: conn, dataset: dataset} do
      resp = mutate(conn, dataset, @portabledoc_body)
      assert resp.status == 200
      refute Map.has_key?(Jason.decode!(resp.resp_body), "warnings")
    end

    test "a MIX of one PortableDoc block and one PT block names only the PT one",
         %{conn: conn, dataset: dataset} do
      mixed = @portabledoc_body ++ @pt_body
      resp = mutate(conn, dataset, mixed)
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      [warning] = body["warnings"]
      assert [finding] = warning["findings"]
      assert finding["path"] == "/body/1"
    end
  end

  describe "refusal on an enforcing dataset" do
    setup %{conn: conn} do
      dataset = "pt_enf_#{System.unique_integer([:positive])}"

      previous = Application.get_env(:barkpark, Validation, [])
      Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
      on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

      ws = Barkpark.Tenancy.get_default_workspace()
      proj = Barkpark.Tenancy.get_default_project()
      {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
      {:ok, _} = schema(dataset, workspace_id: ws.id, project_id: proj.id)

      token = "pt-enf-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(token, "pt-enf", dataset, ["read", "write", "admin"], ws.id)

      {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), dataset: dataset}
    end

    test "the write is refused, 422, naming the block path", %{conn: conn, dataset: dataset} do
      resp = mutate(conn, dataset, @pt_body)
      assert resp.status == 422

      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      assert [finding] = body["error"]["findings"]
      assert finding["code"] == "portable_text_not_portabledoc"
      assert finding["path"] == "/body/0"
    end

    test "a PortableDoc block still lands, 200", %{conn: conn, dataset: dataset} do
      resp = mutate(conn, dataset, @portabledoc_body)
      assert resp.status == 200
    end
  end

  describe "the validator itself, direct — including a field WITH declared custom object blocks" do
    # task-2d96f71d3fe52ee7 — the detection must fire on BOTH `walk_field/4`
    # arms (richText with no `blocks.of` vocabulary at all, and richText
    # WITH one), since a PT block's `_type` vocabulary ("block", "image", …)
    # has no relation to this field's declared member names either way.
    test "fires even when the field declares a custom object block vocabulary" do
      schema = %{
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{
            "name" => "body",
            "type" => "richText",
            "editor" => "blocks",
            "blocks" => %{
              "of" => [
                %{"name" => "callout", "fields" => [%{"name" => "text", "type" => "text"}]}
              ]
            }
          }
        ]
      }

      result =
        Validation.check_findings(
          %{
            "body" => [
              %{"_type" => "block", "children" => [%{"_type" => "span", "text" => "x"}]}
            ]
          },
          "T",
          schema
        )

      assert [%{code: :portable_text_not_portabledoc, path: "/body/0"}] = result.errors
    end

    test "an object with _type but none of the PT signature keys is NOT flagged" do
      schema = %{
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "body", "type" => "richText", "editor" => "blocks"}
        ]
      }

      result =
        Validation.check_findings(
          %{"body" => [%{"_type" => "something_else", "foo" => "bar"}]},
          "T",
          schema
        )

      refute Enum.any?(result.errors, &(&1.code == :portable_text_not_portabledoc))
    end
  end
end
