defmodule Barkpark.Content.InitialValuesTest do
  @moduledoc """
  An explicit null where an initial value would land means "leave it empty"
  (task-d5f5a94e2e1690be). A Studio editor who clears a prefilled field as a new
  document's first edit sends the key as null; Barkpark used to store `null`
  and a Studio leaving it out got the initial value back. Absent still means
  Barkpark's (T3: an unknown zone leaves `"$today"` to Barkpark). A null where
  no initial value would land is stored as before.

  The doors: every create-family verb funnels through `Writer.create_document/4`,
  which applies initial values only when no draft row exists yet (create,
  createOrReplace, createIfNotExists, and createOrReplace with publish). Over an
  existing draft it updates, with no initial values, as before. Patches never apply
  them.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{InitialValues, Mutations}

  @ds "initial_values_null_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sak",
          "title" => "Sak",
          "visibility" => "public",
          "fields" => [
            %{"name" => "publisert", "type" => "date"},
            %{"name" => "notat", "type" => "string"},
            %{
              "name" => "meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "dato", "type" => "date"},
                %{"name" => "sak", "type" => "string"}
              ]
            }
          ],
          "initial_values" => %{
            "publisert" => "$today",
            "kind" => "nyhet",
            "meta" => %{"dato" => "$today"}
          }
        },
        @ds
      )

    :ok
  end

  test "merge: a null where an initial value would land is left out; elsewhere kept; absent filled" do
    iv = %{"a" => 1, "m" => %{"d" => 2, "e" => 3}, "l" => [1]}

    assert InitialValues.merge(iv, %{"a" => nil}) == %{"m" => %{"d" => 2, "e" => 3}, "l" => [1]}

    assert InitialValues.merge(iv, %{"m" => %{"d" => nil}}) == %{
             "a" => 1,
             "m" => %{"e" => 3},
             "l" => [1]
           }

    assert InitialValues.merge(iv, %{"x" => nil}) == Map.put(iv, "x", nil)

    assert InitialValues.merge(iv, %{"m" => %{"x" => nil}})["m"] == %{
             "d" => 2,
             "e" => 3,
             "x" => nil
           }

    # A whole object with nested initial values, sent as null: the object is left out.
    refute Map.has_key?(InitialValues.merge(iv, %{"m" => nil}), "m")
    # Lists replace; a null list where one would land is left out.
    assert InitialValues.merge(iv, %{"l" => [9]})["l"] == [9]
    refute Map.has_key?(InitialValues.merge(iv, %{"l" => nil}), "l")
    # Values win, as before.
    assert InitialValues.merge(iv, %{"a" => 5, "m" => %{"d" => 7}}) == %{
             "a" => 5,
             "m" => %{"d" => 7, "e" => 3},
             "l" => [1]
           }
  end

  defp new_id, do: "sak-#{System.unique_integer([:positive])}"

  defp stored(id) do
    {:ok, doc} = Content.get_document("drafts." <> id, "sak", @ds)
    doc.content
  end

  for verb <- ["create", "createOrReplace", "createIfNotExists"] do
    test "#{verb}: publisert null and meta.dato null are left empty; absent keys are filled; a null with no initial value is stored" do
      id = new_id()

      {:ok, _} =
        Mutations.apply_mutations(
          [
            %{
              unquote(verb) => %{
                "_id" => id,
                "_type" => "sak",
                "publisert" => nil,
                "notat" => nil,
                "meta" => %{"dato" => nil, "sak" => "s1"}
              }
            }
          ],
          @ds
        )

      content = stored(id)

      refute Map.has_key?(content, "publisert"),
             "publisert came back: #{inspect(content["publisert"])}"

      assert content["meta"] == %{"sak" => "s1"}
      assert content["kind"] == "nyhet", "an absent key still gets its initial value"

      assert Map.has_key?(content, "notat") and content["notat"] == nil,
             "a null with no initial value is stored, as before"
    end
  end

  test "createOrReplace with publish: the published document has no publisert" do
    id = new_id()

    {:ok, _} =
      Mutations.apply_mutations(
        [
          %{
            "createOrReplace" => %{"_id" => id, "_type" => "sak", "publisert" => nil},
            "publish" => true
          }
        ],
        @ds
      )

    {:ok, doc} = Content.get_document(id, "sak", @ds)
    refute Map.has_key?(doc.content, "publisert")
    assert doc.content["kind"] == "nyhet"
  end

  test "meta: null with nested initial values leaves meta out; an absent publisert is today's" do
    id = new_id()
    {:ok, _} = Content.create_document("sak", %{"doc_id" => id, "meta" => nil}, @ds)
    content = stored(id)
    refute Map.has_key?(content, "meta")
    assert content["publisert"] =~ ~r/^\d{4}-\d\d-\d\d$/
  end

  test "over an existing draft, createOrReplace updates as before: its null is stored, no initial values" do
    id = new_id()
    {:ok, _} = Content.create_document("sak", %{"doc_id" => id}, @ds)

    {:ok, _} =
      Mutations.apply_mutations(
        [%{"createOrReplace" => %{"_id" => id, "_type" => "sak", "publisert" => nil}}],
        @ds
      )

    content = stored(id)
    assert Map.has_key?(content, "publisert") and content["publisert"] == nil
    refute Map.has_key?(content, "kind")
  end
end
