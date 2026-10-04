defmodule Barkpark.Content.CanonicalShapeWritesFlagTest do
  @moduledoc """
  The instance flag `:canonical_shape_writes` (env
  `BARKPARK_CANONICAL_SHAPE_WRITES`) gates the canonical value-shape WRITES
  of owner rulings #42/#43/#44. Off (the shipped default), a Studio save keeps
  each field's stored shape and the convert tasks refuse `apply: true`; on,
  Studio writes the canonical shapes. Reads accept both shapes either way.

  Synchronous: it flips an application-wide flag for its own duration.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{CanonicalShapes, Forms}
  alias Barkpark.Content.ShapeMigrations.{BareReferences, StringSlugs}

  @ds "shape-flag"
  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "author", "type" => "reference"},
    %{"name" => "editors", "type" => "arrayOf", "of" => %{"type" => "reference"}}
  ]
  @schema %{fields: @fields}
  @ref_ada %{"_ref" => "ada", "_type" => "reference"}

  setup do
    before = Application.get_env(:barkpark, :canonical_shape_writes)
    on_exit(fn -> Application.put_env(:barkpark, :canonical_shape_writes, before) end)

    {:ok, _} =
      Content.upsert_schema(%{"name" => "flagpost", "title" => "Post", "fields" => @fields}, @ds)

    :ok
  end

  defp flag(on?), do: Application.put_env(:barkpark, :canonical_shape_writes, on?)

  defp doc!(id, content) do
    {:ok, doc} =
      Content.create_document(
        "flagpost",
        %{"doc_id" => id, "title" => "T", "content" => content},
        @ds
      )

    doc
  end

  defp save!(doc, params) do
    {:ok, saved, _} = Forms.upsert_draft(doc, "flagpost", @schema, params, @ds)
    saved
  end

  test "the flag ships off; off turns the canonical write off" do
    assert File.read!(Path.join(File.cwd!(), "config/config.exs")) =~
             "config :barkpark, canonical_shape_writes: false"

    flag(false)
    refute CanonicalShapes.writes_enabled?()
    refute CanonicalShapes.canonical_write?("flagpost")
  end

  describe "flag off" do
    setup do
      flag(false)
      :ok
    end

    test "a resave keeps bare ids bare and {_ref} objects as objects" do
      bare = doc!("fl-bare", %{"author" => "ada", "editors" => ["bob"]})
      form = bare |> Forms.doc_to_form(@schema) |> Map.put("title", "After")
      saved = save!(bare, form)
      assert saved.title == "After"
      assert saved.content["author"] == "ada"
      assert saved.content["editors"] == ["bob"]

      obj = doc!("fl-obj", %{"author" => @ref_ada})

      form =
        obj |> Forms.doc_to_form(@schema) |> Map.merge(%{"title" => "After", "author" => "bob"})

      assert save!(obj, form).content["author"] == %{"_ref" => "bob", "_type" => "reference"}
    end

    test "a new pick is stored as the id the picker posted" do
      assert save!(doc!("fl-new", %{}), %{"title" => "T", "author" => "ada"}).content["author"] ==
               "ada"
    end

    test "the convert refuses to apply; the dry run still reports" do
      doc!("fl-census", %{"author" => "ada"})
      assert Enum.any?(BareReferences.dry_run(), &(&1.doc_id == "drafts.fl-census"))

      assert_raise ArgumentError, ~r/BARKPARK_CANONICAL_SHAPE_WRITES/, fn ->
        BareReferences.run(apply: true)
      end

      assert {:ok, %{content: %{"author" => "ada"}}} =
               Content.get_document("drafts.fl-census", "flagpost", @ds)
    end
  end

  describe "flag on" do
    setup do
      flag(true)
      :ok
    end

    test "a resave writes {_ref}" do
      bare = doc!("fo-bare", %{"author" => "ada"})
      form = bare |> Forms.doc_to_form(@schema) |> Map.put("title", "After")
      assert save!(bare, form).content["author"] == @ref_ada
    end
  end

  describe "slugs (owner ruling #43)" do
    setup do
      fields = [%{"name" => "title", "type" => "string"}, %{"name" => "slug", "type" => "slug"}]

      {:ok, _} =
        Content.upsert_schema(%{"name" => "flagslug", "title" => "S", "fields" => fields}, @ds)

      {:ok, doc} =
        Content.create_document(
          "flagslug",
          %{"doc_id" => "fs-str", "title" => "T", "content" => %{"slug" => "old-slug"}},
          @ds
        )

      %{slug_schema: %{fields: fields}, slug_doc: doc}
    end

    test "flag off: a plain-string slug stays a string; an edit stays a string; apply is refused",
         %{slug_schema: schema, slug_doc: doc} do
      flag(false)
      form = doc |> Forms.doc_to_form(schema) |> Map.put("title", "After")
      {:ok, saved, _} = Forms.upsert_draft(doc, "flagslug", schema, form, @ds)
      assert saved.content["slug"] == "old-slug"

      {:ok, edited, _} =
        Forms.upsert_draft(saved, "flagslug", schema, Map.put(form, "slug", "new-slug"), @ds)

      assert edited.content["slug"] == "new-slug"
      assert_raise ArgumentError, fn -> StringSlugs.run(apply: true) end
    end

    test "flag on: a plain-string slug is rewritten as {current}",
         %{slug_schema: schema, slug_doc: doc} do
      flag(true)
      form = doc |> Forms.doc_to_form(schema) |> Map.put("title", "After")
      {:ok, saved, _} = Forms.upsert_draft(doc, "flagslug", schema, form, @ds)
      assert saved.content["slug"] == %{"_type" => "slug", "current" => "old-slug"}
    end
  end
end
