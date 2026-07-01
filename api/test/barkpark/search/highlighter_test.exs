defmodule Barkpark.Search.HighlighterTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.CallerContext
  alias Barkpark.Search.Highlighter

  # Minimal struct stand-ins — Highlighter only reads named fields.
  defmodule FakeDoc do
    defstruct [:doc_id, :title, :content, :type]
  end

  defmodule FakeFile do
    defstruct [:id, :original_name, :filename]
  end

  # WS-B LOW-11: content.* highlight fields bypass the Envelope redaction
  # boundary (e.g. content.slug). They must be dropped for a non-authorized
  # caller, kept only for an admin.
  describe "content.* highlight fields visibility (WS-B LOW-11)" do
    test "non-admin caller does NOT get a content.* highlight" do
      doc = %FakeDoc{doc_id: "d1", title: "Hi", content: %{"slug" => "secret-slug"}}
      parsed = %{terms: ["secret"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["title", "content.slug"]}

      for caller <- [nil, CallerContext.anonymous(), CallerContext.from_user("u1")] do
        result = Highlighter.highlight_documents([doc], parsed, config, caller)
        refute Map.has_key?(result["d1"], "content.slug")
      end
    end

    test "admin caller keeps a content.* highlight" do
      doc = %FakeDoc{doc_id: "d1", title: "Hi", content: %{"slug" => "secret-slug"}}
      parsed = %{terms: ["secret"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["title", "content.slug"]}
      admin = %CallerContext{principal_type: :api_token, is_admin: true}

      result = Highlighter.highlight_documents([doc], parsed, config, admin)
      assert result["d1"]["content.slug"] == "<mark>secret</mark>-slug"
    end
  end

  # LOW regression fix: the highlighter must drop ONLY the content.* fields the
  # caller may not see per the type's schema field visibility — not over-redact
  # the caller's own public fields. Reuses Envelope.field_readable?/3.
  describe "content.* highlight visibility per schema (LOW over-redaction fix)" do
    setup do
      doc = %FakeDoc{
        doc_id: "d1",
        type: "post",
        title: "secret title",
        content: %{"slug" => "secret-slug"}
      }

      parsed = %{terms: ["secret"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["title", "content.slug"]}
      %{doc: doc, parsed: parsed, config: config}
    end

    test "a PUBLIC content.* field's highlight SURVIVES for a non-admin", %{
      doc: doc,
      parsed: parsed,
      config: config
    } do
      # Schema declares `slug` with no visibility flags ⇒ public.
      schema = %{"fields" => [%{"name" => "slug"}]}
      schema_fun = fn "post" -> schema end

      result =
        Highlighter.highlight_documents(
          [doc],
          parsed,
          config,
          CallerContext.anonymous(),
          schema_fun
        )

      assert result["d1"]["content.slug"] == "<mark>secret</mark>-slug"
      # Non-content field is always unaffected by content.* redaction.
      assert result["d1"]["title"] == "<mark>secret</mark> title"
    end

    test "a PRIVATE content.* field's highlight is DROPPED for a non-admin", %{
      doc: doc,
      parsed: parsed,
      config: config
    } do
      schema = %{"fields" => [%{"name" => "slug", "private" => true}]}
      schema_fun = fn "post" -> schema end

      for caller <- [CallerContext.anonymous(), CallerContext.from_user("u1")] do
        result = Highlighter.highlight_documents([doc], parsed, config, caller, schema_fun)
        refute Map.has_key?(result["d1"], "content.slug")
        # The caller's own visible (non-content) field still highlights.
        assert result["d1"]["title"] == "<mark>secret</mark> title"
      end
    end

    test "no schema ⇒ content.* dropped (fail-closed) for a non-admin", %{
      doc: doc,
      parsed: parsed,
      config: config
    } do
      # No schema resolver ⇒ visibility unknown ⇒ drop content.* (conservative),
      # while non-content fields (title) are unaffected.
      result =
        Highlighter.highlight_documents([doc], parsed, config, CallerContext.anonymous())

      refute Map.has_key?(result["d1"], "content.slug")
      assert result["d1"]["title"] == "<mark>secret</mark> title"
    end
  end

  describe "highlight_documents/3" do
    test "wraps matching term in <mark> tags" do
      doc = %FakeDoc{doc_id: "d1", title: "Elixir is great", content: %{}}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      assert result["d1"]["title"] == "<mark>elixir</mark> is great"
    end

    test "returns no entry for title when no needle matches" do
      doc = %FakeDoc{doc_id: "d1", title: "Something else", content: %{}}
      parsed = %{terms: ["phoenix"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      assert result["d1"] == %{}
    end

    test "matching is case-insensitive, replaces preserving needle case" do
      doc = %FakeDoc{doc_id: "d2", title: "ELIXIR and Elixir", content: %{}}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})
      highlighted = result["d2"]["title"]

      assert highlighted =~ "<mark>elixir</mark>"
    end

    test "handles nil title without crashing (field omitted from result)" do
      doc = %FakeDoc{doc_id: "d3", title: nil, content: %{}}
      parsed = %{terms: ["test"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      refute Map.has_key?(result["d3"], "title")
    end

    test "highlights phrase needles as well as terms" do
      doc = %FakeDoc{doc_id: "d4", title: "exact phrase here", content: %{}}
      parsed = %{terms: [], phrases: ["exact phrase"], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      assert result["d4"]["title"] == "<mark>exact phrase</mark> here"
    end

    test "a backslash-digit needle is highlighted, not consumed as a capture ref" do
      doc = %FakeDoc{doc_id: "d1", title: "foo \\1 bar"}
      parsed = %{terms: ["\\1"], phrases: [], prefixes: []}
      result = Highlighter.highlight_documents([doc], parsed, %{})
      assert result["d1"]["title"] == "foo <mark>\\1</mark> bar"
    end

    test "needles matching inside an inserted <mark> tag do not nest" do
      doc = %FakeDoc{doc_id: "d1", title: "x mark"}
      parsed = %{terms: ["x", "mark"], phrases: [], prefixes: []}
      result = Highlighter.highlight_documents([doc], parsed, %{})
      assert result["d1"]["title"] == "<mark>x</mark> <mark>mark</mark>"
    end
  end

  describe "highlight_media/4" do
    test "highlights filename when it contains the needle" do
      file = %FakeFile{id: 42, original_name: "photo.jpg", filename: "elixir-logo.png"}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}

      result = Highlighter.highlight_media([file], parsed, %{}, %{})

      assert result["42"]["filename"] == "<mark>elixir</mark>-logo.png"
    end

    test "uses doc title when file is matched with title field config" do
      file = %FakeFile{id: 7, original_name: "img.png", filename: "img.png"}
      fake_doc = %FakeDoc{doc_id: "d1", title: "Elixir Book", content: %{}}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["title"]}

      result = Highlighter.highlight_media([file], parsed, config, %{7 => fake_doc})

      assert result["7"]["title"] == "<mark>elixir</mark> Book"
    end
  end
end
