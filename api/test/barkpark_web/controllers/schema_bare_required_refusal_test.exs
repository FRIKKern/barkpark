defmodule BarkparkWeb.SchemaBareRequiredRefusalTest do
  @moduledoc """
  Owner ruling #48 (task-09b145e53c43fd58): schema apply refuses the bare
  `required: true` spelling with a message naming `validation.required`.

  Before, `{name: title, type: string, required: true}` was stored and echoed
  back with `required?: true`, but `Content.Validation` reads the rule only
  from `validation.required`, so a document published with the field empty.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.SchemaDefinition

  @dataset "test"
  @token "barkpark-test-bare-required"

  setup do
    {:ok, _} =
      Auth.create_token(
        @token,
        "bare-required",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp apply_schema(conn, fields, name \\ "bare_req_widget") do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/schemas/#{@dataset}",
      Jason.encode!(%{
        "name" => name,
        "title" => "Bare Required Widget",
        "visibility" => "public",
        "fields" => fields
      })
    )
  end

  test "a top-level required: true is refused with a 422 naming validation.required",
       %{conn: conn} do
    resp = apply_schema(conn, [%{"name" => "title", "type" => "string", "required" => true}])

    assert resp.status == 422, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "validation_failed"
    text = inspect(body["error"])
    assert text =~ "title"
    assert text =~ "validation.required"

    assert {:error, :not_found} = Content.get_schema("bare_req_widget", @dataset)
  end

  test "the bare key inside a composite or an arrayOf member is named by its path",
       %{conn: conn} do
    resp =
      apply_schema(conn, [
        %{
          "name" => "seo",
          "type" => "composite",
          "fields" => [%{"name" => "title", "type" => "string", "required" => true}]
        },
        %{
          "name" => "rows",
          "type" => "arrayOf",
          "of" => %{
            "type" => "composite",
            "fields" => [%{"name" => "label", "type" => "string", "required" => false}]
          }
        }
      ])

    assert resp.status == 422, resp.resp_body
    text = resp.resp_body
    assert text =~ "seo.title"
    assert text =~ "rows[].label"
  end

  test "validation.required is accepted, echoed as required? and enforced", %{conn: conn} do
    resp =
      apply_schema(conn, [
        %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
        %{"name" => "note", "type" => "string"}
      ])

    assert resp.status == 201, resp.resp_body
    fields = Jason.decode!(resp.resp_body)["fields"]
    req = Map.new(fields, &{&1["name"], &1["required?"]})
    assert req == %{"title" => true, "note" => false}

    assert {:error, %{"title" => ["Required"]}} =
             Content.validate_document("bare_req_widget", nil, %{}, @dataset)
  end

  test "an unrelated update to a stored row with the bare key is not blocked" do
    # A legacy row written before the refusal (inserted without the changeset
    # guard). Updating its title alone leaves `fields` unchanged.
    {:ok, row} =
      Content.upsert_schema(
        %{"name" => "legacy_bare", "title" => "Legacy", "visibility" => "public", "fields" => []},
        @dataset
      )

    {:ok, _} =
      row
      |> Ecto.Changeset.change(
        fields: [%{"name" => "title", "type" => "string", "required" => true}]
      )
      |> Barkpark.Repo.update()

    assert {:ok, _} =
             Content.upsert_schema(%{"name" => "legacy_bare", "title" => "Legacy 2"}, @dataset)

    # And the echo no longer claims a rule nothing checks.
    {:ok, schema} = Content.get_schema("legacy_bare", @dataset)
    [field] = Content.serialize_schema_for_sdk(schema).fields
    assert field["required?"] == false
  end

  test "bare_required_paths/2 reports nothing for a clean field list" do
    assert SchemaDefinition.bare_required_paths(
             [%{"name" => "a", "type" => "string", "validation" => %{"required" => true}}],
             []
           ) == []
  end
end
