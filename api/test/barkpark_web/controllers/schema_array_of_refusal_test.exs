defmodule BarkparkWeb.SchemaArrayOfRefusalTest do
  @moduledoc """
  task-33f3ce6c95c48851: a schema write refuses an `arrayOf` that does not
  say what its items are: no `of`, an `of` with no `type`, or a member of an
  `of` list with none.

  `/v1/schemas` already refused them: its controller runs
  `SchemaDefinition.parse/2` first (the control below). Every other door
  writes through `Content.upsert_schema/3` alone (workspace schema
  provisioning, the tag registry, plugin bootstrap, seeds), and stored them;
  document validation then fell back to the legacy checks for the type, and
  the editor crashed on an untyped `of` (task-04004b6d634dd535). The check is
  now in the changeset, on a changed `fields` list only: an unrelated update
  to a stored row still goes through.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @dataset "test"
  @token "barkpark-test-array-of"

  setup do
    {:ok, _} =
      Auth.create_token(
        @token,
        "array-of",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp apply_schema(conn, fields, name) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/schemas/#{@dataset}",
      Jason.encode!(%{
        "name" => name,
        "title" => "Array Of Widget",
        "visibility" => "public",
        "fields" => fields
      })
    )
  end

  defp write(fields, name),
    do:
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => "Array Of Widget",
          "visibility" => "public",
          "fields" => fields
        },
        @dataset
      )

  # Refused by the changeset, every message naming its path; nothing stored.
  defp refused(fields, name) do
    assert {:error, %Ecto.Changeset{} = cs} = write(fields, name)
    assert {:error, :not_found} = Content.get_schema(name, @dataset)
    for {:fields, {msg, _}} <- cs.errors, do: msg
  end

  test "an arrayOf with no `of` is refused, named by its path" do
    assert [msg] = refused([%{"name" => "tags", "type" => "arrayOf"}], "aof_missing")
    assert msg =~ ~s("tags")
    assert msg =~ "needs `of`"
  end

  test "an `of` with no type is refused" do
    assert [msg] =
             refused(
               [%{"name" => "words", "type" => "arrayOf", "of" => %{"name" => "w"}}],
               "aof_untyped"
             )

    assert msg =~ ~s("words")
    assert msg =~ "string `type`"
  end

  test "an `of` that is not an object, an empty list, or a member with no type" do
    assert [_] = refused([%{"name" => "a", "type" => "arrayOf", "of" => "string"}], "aof_str")
    assert [_] = refused([%{"name" => "rows", "type" => "arrayOf", "of" => []}], "aof_empty")

    assert [msg] =
             refused(
               [
                 %{
                   "name" => "rows",
                   "type" => "arrayOf",
                   "of" => [%{"name" => "a", "type" => "string"}, %{"name" => "b"}]
                 }
               ],
               "aof_member"
             )

    assert msg =~ "each member"
  end

  test "inside a composite or an array's items, named by path" do
    msgs =
      refused(
        [
          %{
            "name" => "seo",
            "type" => "composite",
            "fields" => [%{"name" => "keywords", "type" => "arrayOf"}]
          },
          %{
            "name" => "rows",
            "type" => "arrayOf",
            "of" => %{
              "type" => "composite",
              "fields" => [%{"name" => "tags", "type" => "arrayOf", "of" => %{}}]
            }
          }
        ],
        "aof_nested"
      )

    assert Enum.any?(msgs, &(&1 =~ ~s("seo.keywords")))
    assert Enum.any?(msgs, &(&1 =~ ~s("rows[].tags")))
  end

  test "control: /v1/schemas refused them already, through its parse", %{conn: conn} do
    resp = apply_schema(conn, [%{"name" => "tags", "type" => "arrayOf"}], "aof_http")
    assert resp.status == 422, resp.resp_body
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    assert {:error, :not_found} = Content.get_schema("aof_http", @dataset)
  end

  test "typed arrays apply as before", %{conn: conn} do
    resp =
      apply_schema(
        conn,
        [
          %{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}},
          %{
            "name" => "list",
            "type" => "arrayOf",
            "of" => [%{"name" => "line", "type" => "text"}]
          },
          %{
            "name" => "blocks",
            "type" => "arrayOf",
            "of" => [
              %{"name" => "cta", "type" => "composite", "fields" => []},
              %{"name" => "quote", "type" => "composite", "fields" => []}
            ]
          }
        ],
        "aof_ok"
      )

    assert resp.status == 201, resp.resp_body
  end

  # `parse/2` reads `fields` only on a composite, image or file, and `of`
  # only on an arrayOf: a bare arrayOf anywhere else is not a field it
  # parses, and the changeset agrees with it.
  for {label, field} <- [
        {"an object's fields",
         %{
           "name" => "box",
           "type" => "object",
           "fields" => [%{"name" => "inner", "type" => "arrayOf"}]
         }},
        {"a legacy array's of",
         %{
           "name" => "rows",
           "type" => "array",
           "of" => [%{"name" => "inner", "type" => "arrayOf"}]
         }},
        {"a string's stray fields",
         %{
           "name" => "word",
           "type" => "string",
           "fields" => [%{"name" => "inner", "type" => "arrayOf"}]
         }}
      ] do
    @field field
    @slug label |> String.replace(~r/[^a-z]+/, "_") |> String.trim("_")

    test "a bare arrayOf in #{label} applies through /v1/schemas and the changeset alike",
         %{conn: conn} do
      resp = apply_schema(conn, [@field], "aof_http_" <> @slug)
      assert resp.status == 201, resp.resp_body

      assert {:ok, _} = write([@field], "aof_cs_" <> @slug)
    end
  end

  test "an unrelated update to a stored row with an untyped `of` is not blocked" do
    {:ok, row} =
      Content.upsert_schema(
        %{"name" => "aof_legacy", "title" => "Legacy", "visibility" => "public", "fields" => []},
        @dataset
      )

    # Written before the refusal, past the changeset.
    {:ok, _} =
      row
      |> Ecto.Changeset.change(fields: [%{"name" => "words", "type" => "arrayOf"}])
      |> Barkpark.Repo.update()

    assert {:ok, _} =
             Content.upsert_schema(%{"name" => "aof_legacy", "title" => "Legacy 2"}, @dataset)

    assert {:error, _} =
             Content.upsert_schema(
               %{"name" => "aof_legacy", "fields" => [%{"name" => "w2", "type" => "arrayOf"}]},
               @dataset
             )
  end
end
