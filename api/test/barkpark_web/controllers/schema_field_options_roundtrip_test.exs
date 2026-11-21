defmodule BarkparkWeb.SchemaFieldOptionsRoundtripTest do
  # A field's options are kept as given: the Studio reads keys the server never does (a slug's
  # options.slugify names its slug table, barkpark-studio task-15e2e504dd3c74cc). Written,
  # read through GET /v1/schemas, and written back from what was read, they stay the same,
  # and so does the schema's hash.
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.{Auth, Content, Tenancy}

  test "options.slugify survives a write, GET /v1/schemas and a write of the read schema" do
    dataset = "slugrt_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-slugrt-#{System.unique_integer([:positive])}"
    ws = Tenancy.get_default_workspace()
    proj = Tenancy.get_default_project()
    Auth.create_token(token, "dev", dataset, ["read", "write", "admin"], ws.id)
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
    scope = [workspace_id: ws.id, project_id: proj.id]
    opts = %{"source" => "tittel", "slugify" => "nb", "maxLength" => 96}

    fields = [
      %{"name" => "tittel", "type" => "string"},
      %{"name" => "slug", "type" => "slug", "options" => opts}
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "side", "title" => "Side", "fields" => fields},
        dataset,
        scope
      )

    read = fn ->
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/v1/schemas/#{dataset}/side")
      |> json_response(200)
      |> Map.fetch!("schema")
    end

    slug_options = fn schema ->
      Enum.find(schema["fields"], &(&1["name"] == "slug"))["options"]
    end

    pulled = read.()
    assert slug_options.(pulled) == opts

    {:ok, _} = Content.upsert_schema(Map.drop(pulled, ["id", "schemaHash"]), dataset, scope)
    again = read.()
    assert slug_options.(again) == opts
    assert again["schemaHash"] == pulled["schemaHash"]
  end
end
