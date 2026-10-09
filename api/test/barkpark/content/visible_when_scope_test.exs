defmodule Barkpark.Content.VisibleWhenScopeTest do
  @moduledoc """
  task-9905a69475b1ff3b: `visibleWhen` paths walked from the document root, so a
  field inside an array item could not be hidden by a sibling in the same item
  (Sanity's `hidden: ({parent}) => …`). A predicate may now carry
  `"scope": "parent"` (the enclosing object or array item); `"document"` stays
  the default. The schema validator enum-checks the scope and refuses
  `"parent"` on a top-level field.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.FieldVisibility
  alias Barkpark.Content.SchemaDefinition

  @url_when_kind_url %{
    "field" => "kind",
    "operator" => "eq",
    "value" => "url",
    "scope" => "parent"
  }

  describe "FieldVisibility" do
    test "a parent-scoped predicate reads the enclosing item, not the document" do
      field = %{"name" => "url", "visibleWhen" => @url_when_kind_url}
      doc = %{"kind" => "doc", "links" => [%{"kind" => "url"}, %{"kind" => "doc"}]}

      assert FieldVisibility.visible?(field, doc, %{"kind" => "url"})
      refute FieldVisibility.visible?(field, doc, %{"kind" => "doc"})
    end

    test "the default scope still walks from the document root" do
      field = %{"name" => "url", "visibleWhen" => Map.delete(@url_when_kind_url, "scope")}

      assert FieldVisibility.visible?(field, %{"kind" => "url"}, %{"kind" => "doc"})
      refute FieldVisibility.visible?(field, %{"kind" => "doc"}, %{"kind" => "url"})
      # explicit "document" is the same as no scope
      field = %{field | "visibleWhen" => Map.put(@url_when_kind_url, "scope", "document")}
      assert FieldVisibility.visible?(field, %{"kind" => "url"}, %{"kind" => "doc"})
    end

    test "with no parent a parent-scoped predicate reads the document" do
      field = %{"name" => "url", "visibleWhen" => @url_when_kind_url}
      assert FieldVisibility.visible?(field, %{"kind" => "url"})
      refute FieldVisibility.visible?(field, %{"kind" => "doc"})
    end
  end

  # Ruling on task-9905a69475b1ff3b, option (b): scope changes what Studio shows,
  # not what the server checks. A required field a parent-scoped predicate hides
  # is still validated, as in Sanity; skipping it is a separate owner question.
  test "a hidden required field is still validated on the server" do
    schema = %{
      "name" => "linkset",
      "fields" => [
        links(@url_when_kind_url)
        |> put_in(["of", "fields", Access.at(1), "validation"], %{"required" => true})
      ]
    }

    content = %{"links" => [%{"kind" => "doc"}]}

    hidden? =
      not FieldVisibility.visible?(%{"visibleWhen" => @url_when_kind_url}, content, %{
        "kind" => "doc"
      })

    assert hidden?

    findings = Barkpark.Content.Validation.check_findings(content, "Links", schema)

    assert Enum.any?(findings.errors, &(&1.code == :required and &1.path =~ "url")),
           inspect(findings)
  end

  defp schema(fields), do: %{"name" => "linkset", "title" => "Link set", "fields" => fields}

  defp links(vw) do
    %{
      "name" => "links",
      "type" => "arrayOf",
      "of" => %{
        "type" => "composite",
        "fields" => [
          %{"name" => "kind", "type" => "string"},
          %{"name" => "url", "type" => "string", "visibleWhen" => vw}
        ]
      }
    }
  end

  defp errors(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Map.get(:fields, [])
  end

  describe "schema validation" do
    test "a parent scope inside an array item is accepted" do
      assert errors(schema([links(@url_when_kind_url)])) == []
      assert {:ok, _} = SchemaDefinition.parse(schema([links(@url_when_kind_url)]))
    end

    test "a parent scope on a top-level field is refused with its path" do
      top = %{"name" => "url", "type" => "string", "visibleWhen" => @url_when_kind_url}
      assert [msg] = errors(schema([%{"name" => "kind", "type" => "string"}, top]))

      assert msg =~
               ~s("url": visibleWhen "scope": "parent" needs an enclosing object or array item)

      assert {:error, {:visible_when_parent_at_top_level, "url"}} =
               SchemaDefinition.parse(schema([top]))
    end

    test "an unknown scope is refused, nested or not" do
      bad = Map.put(@url_when_kind_url, "scope", "grandparent")
      assert [msg] = errors(schema([links(bad)]))

      assert msg =~
               ~s("links[].url": visibleWhen "scope" must be "document" or "parent", got "grandparent")

      assert {:error, {:visible_when_scope_invalid, _, "grandparent"}} =
               SchemaDefinition.parse(schema([links(bad)]))
    end

    test "a parent scope inside a composite and a named array member is accepted" do
      composite = %{
        "name" => "seo",
        "type" => "composite",
        "fields" => [
          %{"name" => "kind", "type" => "string"},
          %{"name" => "url", "type" => "string", "visibleWhen" => @url_when_kind_url}
        ]
      }

      members = %{
        "name" => "items",
        "type" => "arrayOf",
        "of" => [
          %{
            "name" => "link",
            "type" => "composite",
            "fields" => [
              %{"name" => "kind", "type" => "string"},
              %{"name" => "url", "type" => "string", "visibleWhen" => @url_when_kind_url}
            ]
          }
        ]
      }

      assert errors(schema([composite, members])) == []
      assert {:ok, _} = SchemaDefinition.parse(schema([composite, members]))
    end
  end
end
