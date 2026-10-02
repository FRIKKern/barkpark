defmodule Barkpark.Content.NamedObjectTypesTest do
  @moduledoc """
  Gyldendal parity E3.6 (task-5064727fdda5a5df): a composite declared ONCE per
  dataset as `kind: "object"` is referenced by type name from document schemas
  and inlined at read time; an unknown or cyclic type name is refused at apply.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Schema
  alias Barkpark.Content.Validation
  alias Barkpark.Structure
  alias Barkpark.Tenancy

  @dataset "production"

  @seo_fields [
    %{
      "name" => "title",
      "title" => "Tittel",
      "type" => "string",
      "description" => "Tittelen i søkeresultater."
    },
    %{
      "name" => "description",
      "title" => "Beskrivelse",
      "type" => "text",
      "validation" => %{
        "max" => 300,
        "level" => "warning",
        "message" => "Beskrivelsen bør være under 300 tegn."
      }
    },
    %{
      "name" => "image",
      "title" => "Bilde",
      "type" => "image",
      "options" => %{"hotspot" => true}
    },
    %{"name" => "noindex", "title" => "Skru av indeksering?", "type" => "boolean"}
  ]

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "nt-#{suffix}", name: "Named Types"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, scope: [workspace_id: ws.id, project_id: proj.id], ws: ws}
  end

  defp seo_type(scope) do
    Content.upsert_schema(
      %{
        "name" => "seo",
        "kind" => "object",
        "title" => "SEO og sosiale medier",
        "fields" => @seo_fields
      },
      @dataset,
      scope
    )
  end

  defp publication(scope, extra \\ %{}) do
    Content.upsert_schema(
      Map.merge(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "groups" => [
            %{"name" => "content", "title" => "Innhold", "default" => true},
            %{"name" => "settings", "title" => "Innstillinger"}
          ],
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string", "group" => "content"},
            %{
              "name" => "seo",
              "title" => "SEO og sosiale medier",
              "type" => "seo",
              "group" => "settings",
              "description" => "Overstyr tittel, beskrivelse og bilde for deling."
            }
          ]
        },
        extra
      ),
      @dataset,
      scope
    )
  end

  test "an object type applies, and a document schema referencing it reads back with the composite inlined",
       %{scope: scope} do
    assert {:ok, %{kind: "object"}} = seo_type(scope)
    assert {:ok, _} = publication(scope)

    {:ok, schema} = Content.get_schema("publication", @dataset, scope)
    seo = Enum.find(schema.fields, &(&1["name"] == "seo"))

    assert seo["type"] == "composite"
    assert seo["namedType"] == "seo"
    assert Enum.map(seo["fields"], & &1["name"]) == ["title", "description", "image", "noindex"]
    # the reference's own words win over the object type's
    assert seo["title"] == "SEO og sosiale medier"
    assert seo["group"] == "settings"
    assert seo["description"] =~ "Overstyr"

    # the STORED row is untouched: the raw read still says type "seo"
    {:ok, raw} = Schema.get_schema_raw("publication", @dataset, scope)
    assert Enum.find(raw.fields, &(&1["name"] == "seo"))["type"] == "seo"

    # resolve_schema (the Studio's read) and list_schemas inline the same way
    {:ok, resolved} = Content.resolve_schema("publication", @dataset, scope)
    assert Enum.find(resolved.fields, &(&1["name"] == "seo"))["type"] == "composite"

    listed = Content.list_schemas(@dataset, scope) |> Enum.find(&(&1.name == "publication"))
    assert Enum.find(listed.fields, &(&1["name"] == "seo"))["type"] == "composite"
  end

  test "an unknown type name is refused at apply, naming it", %{scope: scope} do
    assert {:error, changeset} =
             publication(scope, %{
               "fields" => [%{"name" => "seo", "title" => "SEO", "type" => "seo"}]
             })

    assert {msg, _} = changeset.errors[:fields]
    assert msg =~ ~s(unknown field type "seo")
    assert msg =~ "apply the object type first"

    # validate_only answers the same verdict without writing
    assert {:error, %Ecto.Changeset{}} =
             Schema.validate_schema(
               %{
                 "name" => "publication",
                 "title" => "Utgivelse",
                 "fields" => [%{"name" => "x", "type" => "nope"}]
               },
               @dataset,
               scope
             )

    assert {:error, :not_found} = Schema.get_schema_raw("publication", @dataset, scope)
  end

  test "a cycle between object types is refused, and the inliner never loops", %{scope: scope} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "a",
          "kind" => "object",
          "title" => "A",
          "fields" => [%{"name" => "x", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "b",
          "kind" => "object",
          "title" => "B",
          "fields" => [%{"name" => "a", "type" => "a"}]
        },
        @dataset,
        scope
      )

    # a would now contain b which contains a
    assert {:error, changeset} =
             Content.upsert_schema(
               %{
                 "name" => "a",
                 "kind" => "object",
                 "title" => "A",
                 "fields" => [%{"name" => "b", "type" => "b"}]
               },
               @dataset,
               scope
             )

    assert {msg, _} = changeset.errors[:fields]
    assert msg =~ "cycle"

    # a self-reference is the shortest cycle
    assert {:error, _} =
             Content.upsert_schema(
               %{
                 "name" => "c",
                 "kind" => "object",
                 "title" => "C",
                 "fields" => [%{"name" => "c", "type" => "c"}]
               },
               @dataset,
               scope
             )
  end

  test "the object type never sits on the desk, and the API catalogue carries its kind", %{
    scope: scope,
    ws: ws
  } do
    {:ok, _} = seo_type(scope)
    {:ok, _} = publication(scope)

    root = Structure.build(@dataset, workspace_id: ws.id)
    names = root |> flatten_type_names() |> MapSet.new()
    assert MapSet.member?(names, "publication")
    refute MapSet.member?(names, "seo")

    %{schemas: schemas} = Content.list_schemas_for_sdk(@dataset, scope)
    assert Enum.find(schemas, &(&1.name == "seo")).kind == "object"
    assert Enum.find(schemas, &(&1.name == "publication")).kind == "document"
  end

  test "validation sees the named type exactly as it sees the same composite inline", %{
    scope: scope
  } do
    {:ok, _} = seo_type(scope)
    {:ok, _} = publication(scope)
    {:ok, named} = Content.get_schema("publication", @dataset, scope)

    inline = %{
      named
      | fields:
          Enum.map(named.fields, fn
            %{"name" => "seo"} = f ->
              f
              |> Map.delete("namedType")
              |> Map.put("type", "composite")
              |> Map.put("fields", @seo_fields)

            f ->
              f
          end)
    }

    content = %{
      "title" => "Snow Angels",
      "seo" => %{"description" => String.duplicate("x", 301), "noindex" => "yes"}
    }

    # Identical verdicts: the resolved named type IS a composite to the validator.
    # (Walking warning rules INSIDE a composite is a separate, pre-existing gap —
    # inline composites do not surface them either; noted for the friction log.)
    assert Validation.check(content, "Snow Angels", named) ==
             Validation.check(content, "Snow Angels", inline)

    assert Validation.validate(content, "Snow Angels", named) ==
             Validation.validate(content, "Snow Angels", inline)
  end

  defp flatten_type_names(node) when is_map(node) do
    own = Map.get(node, :type_name)
    kids = Map.get(node, :items) || []
    Enum.reject([own | Enum.flat_map(kids, &flatten_type_names/1)], &is_nil/1)
  end

  defp flatten_type_names(_), do: []
end
