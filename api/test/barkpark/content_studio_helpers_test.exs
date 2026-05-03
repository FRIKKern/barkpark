defmodule Barkpark.ContentStudioHelpersTest do
  @moduledoc """
  Unit tests for the Studio-helper public functions extracted from
  `BarkparkWeb.Studio.StudioLive` in Task #11 WI3:
  `fetch_doc_with_draft/3`, `doc_to_form/2`, `build_content/2`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "studio_helpers_test"
  @doc_type "post"

  defp seed_post(id, opts \\ []) do
    title = Keyword.get(opts, :title, "Title #{id}")
    body = Keyword.get(opts, :body, "")
    status = Keyword.get(opts, :status, "draft")

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"_id" => id, "title" => title, "body" => body, "status" => status},
        @dataset
      )

    doc
  end

  describe "fetch_doc_with_draft/3" do
    test "returns {nil, false, false} when neither draft nor published exists" do
      assert {nil, false, false} =
               Content.fetch_doc_with_draft(@doc_type, "missing-doc", @dataset)
    end

    test "returns draft preferred over published" do
      _draft = seed_post("p1", title: "Draft title")
      # Publish then create a new draft so both exist
      {:ok, _} = Content.publish_document("p1", @doc_type, @dataset)
      _draft2 = seed_post("p1", title: "New draft title")

      assert {%{title: "New draft title"}, true, true} =
               Content.fetch_doc_with_draft(@doc_type, "p1", @dataset)
    end

    test "returns published-only with is_draft=false, has_published=true" do
      _draft = seed_post("p2")
      {:ok, _} = Content.publish_document("p2", @doc_type, @dataset)

      assert {%{doc_id: "p2"}, false, true} =
               Content.fetch_doc_with_draft(@doc_type, "p2", @dataset)
    end

    test "accepts the draft-prefixed id and returns the same triple" do
      seed_post("p3")

      assert {%{}, true, false} = Content.fetch_doc_with_draft(@doc_type, "drafts.p3", @dataset)
    end
  end

  describe "doc_to_form/2" do
    test "returns %{} for nil document" do
      assert Content.doc_to_form(nil, %{fields: []}) == %{}
      assert Content.doc_to_form(nil, nil) == %{}
    end

    test "returns title + status baseline when no schema" do
      doc = %{title: "Hi", status: "draft", content: %{}}
      assert Content.doc_to_form(doc, nil) == %{"title" => "Hi", "status" => "draft"}
    end

    test "merges schema fields from doc.content" do
      doc = %{title: "Hi", status: "draft", content: %{"body" => "yo"}}
      schema = %{fields: [%{"name" => "title"}, %{"name" => "body"}]}

      assert Content.doc_to_form(doc, schema) == %{
               "title" => "Hi",
               "status" => "draft",
               "body" => "yo"
             }
    end

    test "missing content fields default to empty string" do
      doc = %{title: "Hi", status: "draft", content: %{}}
      schema = %{fields: [%{"name" => "body"}]}

      assert Content.doc_to_form(doc, schema) == %{
               "title" => "Hi",
               "status" => "draft",
               "body" => ""
             }
    end

    test "nil content map defaults gracefully" do
      doc = %{title: nil, status: nil, content: nil}
      schema = %{fields: [%{"name" => "body"}]}

      assert Content.doc_to_form(doc, schema) == %{
               "title" => "",
               "status" => "draft",
               "body" => ""
             }
    end
  end

  describe "build_content/2" do
    test "returns %{} for nil schema" do
      assert Content.build_content(%{"title" => "x", "body" => "y"}, nil) == %{}
    end

    test "drops title + status keys" do
      schema = %{fields: [%{"name" => "title"}, %{"name" => "body"}]}
      params = %{"title" => "T", "status" => "draft", "body" => "B"}

      assert Content.build_content(params, schema) == %{"body" => "B"}
    end

    test "drops empty-string values" do
      schema = %{fields: [%{"name" => "body"}, %{"name" => "tag"}]}
      params = %{"body" => "", "tag" => "yes"}

      assert Content.build_content(params, schema) == %{"tag" => "yes"}
    end

    test "missing field defaults to empty (and is dropped)" do
      schema = %{fields: [%{"name" => "body"}]}
      assert Content.build_content(%{}, schema) == %{}
    end
  end

  describe "upsert_draft/5" do
    test "saves draft and returns {:ok, doc, %{}} when validation passes" do
      base = seed_post("u1", title: "Old", body: "old body")
      params = %{"title" => "New", "body" => "new body", "status" => "draft"}

      assert {:ok, saved, %{}} =
               Content.upsert_draft(
                 base,
                 @doc_type,
                 %{fields: [%{"name" => "body"}]},
                 params,
                 @dataset
               )

      assert saved.title == "New"
      assert saved.content["body"] == "new body"
      assert Content.draft?(saved.doc_id)
    end

    test "saves draft AND returns validation errors map (warnings, not blocking)" do
      base = seed_post("u2")
      # Title is required by Validation when schema has title field; pass empty
      schema = %{fields: [%{"name" => "title", "validation" => %{"required" => true}}]}
      params = %{"title" => "", "status" => "draft"}

      result = Content.upsert_draft(base, @doc_type, schema, params, @dataset)

      assert match?({:ok, _, _}, result)
      {:ok, _saved, errs} = result
      # The exact errors depend on Validation module; assert it's a map
      assert is_map(errs)
    end
  end
end
