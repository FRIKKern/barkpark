defmodule Barkpark.Content.SlugShapeTest do
  @moduledoc """
  Owner ruling #43 (task-26394ff887df3261): `{current}` is the canonical slug
  shape.

  Studio stored a slug as a plain string while the starters, seeds and typed
  SDK used `{current}`, so Studio-made posts 404'd on starter sites and seeded
  slugs could not be edited in Studio. Studio now reads and writes
  `{"_type": "slug", "current": …}`; plain strings are still read and are
  rewritten on their next save. These tests load documents in BOTH shapes.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Forms, Query, SlugValue}
  alias Barkpark.Content.ShapeMigrations.StringSlugs
  alias BarkparkWeb.Studio.StudioLive.DocActions

  @ds "slug-shape"
  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "slug", "type" => "slug"}
    ]
  }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "spost",
          "title" => "Post",
          "visibility" => "public",
          "fields" => @schema.fields
        },
        @ds
      )

    :ok
  end

  defp doc!(id, content) do
    {:ok, doc} =
      Content.create_document(
        "spost",
        %{"doc_id" => id, "title" => "T", "content" => content},
        @ds
      )

    doc
  end

  defp save!(doc, params) do
    {:ok, saved, _} = Forms.upsert_draft(doc, "spost", @schema, params, @ds)
    saved
  end

  @canon %{"_type" => "slug", "current" => "my-post"}

  test "a typed or generated slug is written as {current}" do
    saved = save!(doc!("ss-new", %{}), %{"title" => "T", "slug" => "my-post"})
    assert saved.content["slug"] == @canon
  end

  test "a seeded {current} slug is editable: the form shows its text" do
    doc = doc!("ss-obj", %{"slug" => %{"_type" => "slug", "current" => "seeded", "_key" => "k"}})
    form = Forms.doc_to_form(doc, @schema)
    assert form["slug"] == "seeded"

    # Untouched: byte-identical, sibling keys included.
    untouched = save!(doc, Map.put(form, "title", "After"))
    assert untouched.content["slug"] == %{"_type" => "slug", "current" => "seeded", "_key" => "k"}

    # Edited: the text changes, the sibling keys stay.
    edited = save!(untouched, Map.put(form, "slug", "renamed"))
    assert edited.content["slug"] == %{"_type" => "slug", "current" => "renamed", "_key" => "k"}
  end

  test "a plain-string slug is read, and rewritten as {current} on the next save" do
    doc = doc!("ss-str", %{"slug" => "my-post"})
    form = Forms.doc_to_form(doc, @schema)
    assert form["slug"] == "my-post"

    assert save!(doc, Map.put(form, "title", "After")).content["slug"] == @canon
  end

  test "SlugValue and the Studio link placeholder read both shapes" do
    assert SlugValue.text("a") == "a"
    assert SlugValue.text(%{"current" => "a"}) == "a"
    assert SlugValue.text(%{"current" => ""}) == nil
    assert SlugValue.text(nil) == nil

    assert DocActions.doc_slug(%{content: %{"slug" => "a"}}) == "a"
    assert DocActions.doc_slug(%{content: %{"slug" => %{"current" => "b"}}}) == "b"
  end

  test "the census counts plain-string slugs; the dry run writes nothing" do
    doc!("ss-census-str", %{"slug" => "old"})
    doc!("ss-census-obj", %{"slug" => @canon})

    assert %{type: "spost", field: "slug", documents: 1} in StringSlugs.census()

    row = Enum.find(StringSlugs.dry_run(), &(&1.doc_id == "drafts.ss-census-str"))
    assert row.to == %{"_type" => "slug", "current" => "old"}
    refute Enum.any?(StringSlugs.dry_run(), &(&1.doc_id == "drafts.ss-census-obj"))

    assert {:ok, %{content: %{"slug" => "old"}}} =
             Content.get_document("drafts.ss-census-str", "spost", @ds)
  end

  test "a Studio-written slug is found by the starter's slug.current read; a legacy string by slug" do
    saved = save!(doc!("ss-rt", %{}), %{"title" => "T", "slug" => "round-trip"})
    assert saved.content["slug"] == %{"_type" => "slug", "current" => "round-trip"}
    {:ok, _} = Content.publish_document("ss-rt", "spost", @ds)

    legacy = doc!("ss-rt-legacy", %{"slug" => "legacy-slug"})
    {:ok, _} = Content.publish_document(Content.published_id(legacy.doc_id), "spost", @ds)

    # The blog starter's postBySlug reads `slug.current == $slug || slug == $slug`.
    assert [%{doc_id: "ss-rt"}] =
             Query.list_documents("spost", @ds, filter_map: %{"slug.current" => "round-trip"})

    assert [%{doc_id: "ss-rt-legacy"}] =
             Query.list_documents("spost", @ds, filter_map: %{"slug" => "legacy-slug"})
  end

  test "run(apply: true) converts plain-string slugs and leaves {current} slugs alone" do
    str = doc!("ss-apply-str", %{"slug" => "old"})
    obj = doc!("ss-apply-obj", %{"slug" => Map.put(@canon, "_key", "k")})

    result = StringSlugs.run(apply: true)
    assert result.applied?

    {:ok, after_str} = Content.get_document("drafts.ss-apply-str", "spost", @ds)
    assert after_str.content["slug"] == %{"_type" => "slug", "current" => "old"}
    assert after_str.rev != str.rev

    {:ok, after_obj} = Content.get_document("drafts.ss-apply-obj", "spost", @ds)
    assert after_obj.content == obj.content
    assert after_obj.rev == obj.rev

    assert StringSlugs.census() |> Enum.filter(&(&1.type == "spost")) == []
  end

  test "a plugin-owned type (FRT) keeps its plain-string slug; the convert skips it" do
    fields = [%{"name" => "title", "type" => "string"}, %{"name" => "slug", "type" => "slug"}]

    {:ok, _} =
      Content.upsert_schema(%{"name" => "ability", "title" => "Ability", "fields" => fields}, @ds)

    {:ok, doc} =
      Content.create_document(
        "ability",
        %{"doc_id" => "ss-frt", "title" => "T", "content" => %{"slug" => "missileBarrage"}},
        @ds
      )

    {:ok, saved, _} =
      Forms.upsert_draft(
        doc,
        "ability",
        %{fields: fields},
        %{"title" => "T2", "slug" => "laserBurst"},
        @ds
      )

    assert saved.content["slug"] == "laserBurst"
    refute Enum.any?(StringSlugs.dry_run(), &(&1.doc_id == "drafts.ss-frt"))

    # A user schema's slug is written as {current} in the same save path.
    user = save!(doc!("ss-user", %{}), %{"title" => "T", "slug" => "user-post"})
    assert user.content["slug"] == %{"_type" => "slug", "current" => "user-post"}
  end
end
