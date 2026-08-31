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

    test "HTML in an UNMATCHED run is escaped (XSS via author field text)" do
      doc = %FakeDoc{doc_id: "d1", title: "<img src=x onerror=alert(1)> elixir"}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}
      result = Highlighter.highlight_documents([doc], parsed, %{})
      title = result["d1"]["title"]
      # The author's tag is neutralised; only the highlighter's own <mark> tags
      # are real markup.
      refute title =~ "<img"
      assert title =~ "&lt;img src=x onerror=alert(1)&gt;"
      assert title =~ "<mark>elixir</mark>"
    end

    test "HTML inside a MATCHED segment is escaped, not emitted as markup" do
      doc = %FakeDoc{doc_id: "d1", title: "<script>alert(1)</script>"}
      parsed = %{terms: ["<script>"], phrases: [], prefixes: []}
      result = Highlighter.highlight_documents([doc], parsed, %{})
      title = result["d1"]["title"]
      refute title =~ "<script>"
      assert title =~ "<mark>&lt;script&gt;</mark>"
    end

    test "ampersands in field text are escaped" do
      doc = %FakeDoc{doc_id: "d1", title: "AT&T elixir"}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}
      result = Highlighter.highlight_documents([doc], parsed, %{})
      assert result["d1"]["title"] == "AT&amp;T <mark>elixir</mark>"
    end
  end

  # AXI R3: brief-card snippets — a bounded plain-text window around the first
  # match, sealed through the SAME visibility path as highlights
  # (visible_highlight_fields → Envelope.field_readable?/3).
  describe "snippet_documents/5 (AXI R3 brief snippets)" do
    test "a readable description yields a bounded window around the first match" do
      filler = String.duplicate("lorem ipsum dolor sit amet consectetur ", 30)
      text = filler <> "the alphabeacon signal fires here " <> filler

      doc = %FakeDoc{
        doc_id: "d1",
        type: "post",
        title: "No needle in this title",
        content: %{"description" => text}
      }

      parsed = %{terms: ["alphabeacon"], phrases: [], prefixes: []}
      # Schema declares `description` with no visibility flags ⇒ public.
      schema = %{"fields" => [%{"name" => "description"}]}
      schema_fun = fn "post" -> schema end

      result =
        Highlighter.snippet_documents([doc], parsed, %{}, CallerContext.anonymous(), schema_fun)

      snippet = result["d1"]
      assert is_binary(snippet)
      assert snippet =~ "alphabeacon"
      # Both sides were cut, so both carry an ellipsis; the window is bounded.
      assert String.starts_with?(snippet, "…")
      assert String.ends_with?(snippet, "…")
      assert String.length(snippet) <= 162
    end

    test "title is the first snippet field and needs no schema" do
      doc = %FakeDoc{doc_id: "d1", type: "post", title: "Alphabeacon guide", content: %{}}
      parsed = %{terms: ["alphabeacon"], phrases: [], prefixes: []}

      result = Highlighter.snippet_documents([doc], parsed, %{})

      # Short text ⇒ the whole (original-case) title, no ellipses, no <mark>.
      assert result["d1"] == "Alphabeacon guide"
    end

    test "a schema-PRIVATE field never contributes a snippet — nil caller fails closed" do
      doc = %FakeDoc{
        doc_id: "d1",
        type: "post",
        title: "Plain title",
        content: %{"description" => "the alphabeacon secret payload"}
      }

      parsed = %{terms: ["alphabeacon"], phrases: [], prefixes: []}
      schema = %{"fields" => [%{"name" => "description", "private" => true}]}
      schema_fun = fn "post" -> schema end

      for caller <- [nil, CallerContext.anonymous(), CallerContext.from_user("u1")] do
        result = Highlighter.snippet_documents([doc], parsed, %{}, caller, schema_fun)
        assert result["d1"] == nil
      end
    end

    test "no schema ⇒ content.* snippet dropped (fail-closed); admin bypasses" do
      doc = %FakeDoc{
        doc_id: "d1",
        type: "post",
        title: "Plain title",
        content: %{"description" => "the alphabeacon hidden text"}
      }

      parsed = %{terms: ["alphabeacon"], phrases: [], prefixes: []}

      # No schema resolver ⇒ visibility unknown ⇒ no content.* snippet.
      assert Highlighter.snippet_documents([doc], parsed, %{}, CallerContext.anonymous())["d1"] ==
               nil

      admin = %CallerContext{principal_type: :api_token, is_admin: true}
      assert Highlighter.snippet_documents([doc], parsed, %{}, admin)["d1"] =~ "alphabeacon"
    end

    test "non-binary content values (blocks/maps) are skipped, never crash" do
      doc = %FakeDoc{
        doc_id: "d1",
        type: "post",
        title: "Plain title",
        content: %{"body" => [%{"type" => "paragraph", "text" => "alphabeacon"}]}
      }

      parsed = %{terms: ["alphabeacon"], phrases: [], prefixes: []}
      admin = %CallerContext{principal_type: :api_token, is_admin: true}

      assert Highlighter.snippet_documents([doc], parsed, %{}, admin)["d1"] == nil
    end

    test "no needles ⇒ nil snippet" do
      doc = %FakeDoc{doc_id: "d1", type: "post", title: "Anything", content: %{}}

      assert Highlighter.snippet_documents([doc], %{terms: [], phrases: [], prefixes: []}, %{})[
               "d1"
             ] == nil
    end
  end

  # AXI b3: brief hit cards reuse the sealed highlights map, but highlight_text
  # marks up the ENTIRE field — a schema-configured `content.body` highlight
  # would echo a full field per hit. clamp_brief_highlights/1 windows each
  # already-sealed highlight so a brief card can never re-inflate.
  describe "clamp_brief_highlights/1 (brief re-inflation guard)" do
    test "windows a heavyweight marked field around the first match, keeping <mark>" do
      lead = String.duplicate("x", 5000)
      tail = String.duplicate("y", 5000)
      doc = %FakeDoc{doc_id: "d1", title: "t", content: %{"slug" => lead <> " needle " <> tail}}
      parsed = %{terms: ["needle"], phrases: [], prefixes: []}
      admin = %CallerContext{principal_type: :api_token, is_admin: true}
      config = %{"highlight_fields" => ["content.slug"]}

      full = Highlighter.highlight_documents([doc], parsed, config, admin)["d1"]
      assert byte_size(full["content.slug"]) > 10_000

      val = Highlighter.clamp_brief_highlights(full)["content.slug"]
      assert val =~ "<mark>needle</mark>"
      assert byte_size(val) <= 256
      assert String.starts_with?(val, "…")
      assert String.ends_with?(val, "…")
    end

    test "a window ending inside a long match stays balanced (appends </mark>)" do
      marked = "<mark>" <> String.duplicate("z", 400) <> "</mark>"
      val = Highlighter.clamp_brief_highlights(%{"content.body" => marked})["content.body"]

      assert String.starts_with?(val, "<mark>")
      assert String.contains?(val, "</mark>")
      assert String.ends_with?(val, "…")
      assert byte_size(val) <= 256
    end

    test "HTML entities are never split by the window cut" do
      amps = String.duplicate("&", 400)
      doc = %FakeDoc{doc_id: "d1", title: "t", content: %{"slug" => amps <> " needle"}}
      parsed = %{terms: ["needle"], phrases: [], prefixes: []}
      admin = %CallerContext{principal_type: :api_token, is_admin: true}
      config = %{"highlight_fields" => ["content.slug"]}

      full = Highlighter.highlight_documents([doc], parsed, config, admin)["d1"]
      val = Highlighter.clamp_brief_highlights(full)["content.slug"]

      # Every `&` in the window is a whole `&amp;` entity — no dangling `&am`.
      assert Regex.run(~r/&(?!amp;|lt;|gt;|quot;|#39;)/, val) == nil
      # Bounded: the window is ~160 VISIBLE units; entities are multi-byte so the
      # byte size is larger than a plain window, but still can't re-inflate to the
      # full field (400 entities ≈ 2 KB) — a comfortable per-field cap.
      assert byte_size(val) <= 1024
      assert byte_size(val) < byte_size(full["content.slug"])
    end

    test "a short marked field passes through unchanged (no ellipsis)" do
      assert Highlighter.clamp_brief_highlights(%{"title" => "<mark>hi</mark> there"}) ==
               %{"title" => "<mark>hi</mark> there"}
    end

    test "an empty highlights map clamps to an empty map" do
      assert Highlighter.clamp_brief_highlights(%{}) == %{}
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

    # task-5cf80a99ecd52bf2: `media_field_text/3` used to have a clause per
    # KNOWN field name (title/original_name/filename/tags) and NOTHING else —
    # a `highlight_fields` entry that is not one of those names (e.g. a
    # config value written before write-time validation existed, or any
    # already-corrupted row) raised `FunctionClauseError`. That crash landed
    # on the NEXT search request, not the write that introduced the bad
    # value — a stored-config denial of service. This is the READ-side half
    # of the fix (defence in depth: rows corrupted BEFORE the write-time
    # validation landed still exist and must degrade, not crash).
    test "an unrecognized highlight_fields entry degrades to no highlight, never raises" do
      file = %FakeFile{id: 99, original_name: "photo.jpg", filename: "photo.jpg"}
      parsed = %{terms: ["photo"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["filename", "cliverbs-media-marker"]}

      result = Highlighter.highlight_media([file], parsed, config, %{})

      assert result["99"]["filename"] == "<mark>photo</mark>.jpg"
      refute Map.has_key?(result["99"], "cliverbs-media-marker")
    end

    test "an unrecognized field as the ONLY configured field still returns (not raises)" do
      file = %FakeFile{id: 100, original_name: "photo.jpg", filename: "photo.jpg"}
      parsed = %{terms: ["photo"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["cliverbs-media-marker"]}

      result = Highlighter.highlight_media([file], parsed, config, %{})

      assert result["100"] == %{}
    end
  end
end
