defmodule Barkpark.Content.ExpandTargetVocabularyTest do
  @moduledoc """
  task-acde2704bb114428 — `?expand=` reads the SAME reference-target vocabulary
  as Studio's picker: `refType`, Sanity's `to` (type strings or `%{"type" => t}`
  entries) and `refTypes`. It used to read only `refType`, so a `to`-declared
  `author` came back as the raw id, 200, with no warning.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Expand}

  @ds "expvocab"

  defp publish!(type, attrs) do
    {:ok, _} = Content.create_document(type, attrs, @ds)
    {:ok, doc} = Content.publish_document(attrs["_id"], type, @ds)
    doc
  end

  defp schema!(name, fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @ds
      )
  end

  setup do
    schema!("person", [%{"name" => "title", "type" => "string"}])
    schema!("org", [%{"name" => "title", "type" => "string"}])
    publish!("person", %{"_id" => "ada", "title" => "Ada"})
    publish!("person", %{"_id" => "bob", "title" => "Bob"})
    publish!("org", %{"_id" => "acme", "title" => "Acme"})
    :ok
  end

  # One `article` schema per declaration form: each names its target a
  # different way and must expand identically.
  @forms [
    {"refType", %{"refType" => "person"}},
    {"to strings", %{"to" => ["person"]}},
    {"to objects", %{"to" => [%{"type" => "person"}]}},
    {"refTypes", %{"refTypes" => ["person"]}}
  ]

  for {label, decl} <- @forms do
    @decl decl
    test "a single reference declared with #{label} expands a bare id AND a {_ref}" do
      type = "art_" <> Integer.to_string(:erlang.phash2(@decl))
      schema!(type, [Map.merge(%{"name" => "author", "type" => "reference"}, @decl)])

      bare = publish!(type, %{"_id" => "#{type}-bare", "title" => "t", "author" => "ada"})

      obj =
        publish!(type, %{"_id" => "#{type}-obj", "title" => "t", "author" => %{"_ref" => "ada"}})

      [e1, e2] = Expand.expand([Envelope.render(bare), Envelope.render(obj)], ["author"], @ds)

      assert %{"_id" => "ada", "title" => "Ada"} = e1["author"]
      assert %{"_id" => "ada", "title" => "Ada"} = e2["author"]
    end

    test "an arrayOf reference declared with #{label} expands every element" do
      type = "arr_" <> Integer.to_string(:erlang.phash2(@decl))
      of = Map.merge(%{"type" => "reference"}, @decl)
      schema!(type, [%{"name" => "authors", "type" => "arrayOf", "of" => of}])

      doc =
        publish!(type, %{
          "_id" => "#{type}-1",
          "title" => "t",
          "authors" => ["ada", %{"_ref" => "bob"}]
        })

      [e] = Expand.expand([Envelope.render(doc)], ["authors"], @ds)
      assert [%{"_id" => "ada"}, %{"_id" => "bob"}] = e["authors"]
    end
  end

  test "a multi-type `to` resolves each reference by the stored target's own type" do
    schema!("credit", [
      %{
        "name" => "by",
        "type" => "arrayOf",
        "of" => %{"type" => "reference", "to" => ["person", "org"]}
      }
    ])

    doc = publish!("credit", %{"_id" => "credit-1", "title" => "t", "by" => ["ada", "acme"]})

    [e] = Expand.expand([Envelope.render(doc)], ["by"], @ds)

    assert [%{"_id" => "ada", "_type" => "person"}, %{"_id" => "acme", "_type" => "org"}] =
             e["by"]
  end

  test "a target of a type the field does not name stays unexpanded" do
    schema!("only_org", [%{"name" => "owner", "type" => "reference", "to" => ["org"]}])
    doc = publish!("only_org", %{"_id" => "oo-1", "title" => "t", "owner" => "ada"})

    [e] = Expand.expand([Envelope.render(doc)], ["owner"], @ds)
    assert e["owner"] == "ada"
  end
end
