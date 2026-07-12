defmodule Barkpark.PreviewTest do
  @moduledoc """
  The preview manifest — one OpenGraph-shaped card per document, computed PURELY
  (no DB) from `content` + `blocks`. Confirms the image/title/description
  fallback chains, the injected media-resolver seam, the per-doctype extensions,
  and the degradation invariant (a valid card with no `:preview` opts).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Preview

  # A stub media resolver: any /media/files/<path> src → the og rendition shape,
  # mirroring Preview.media_resolver/1 but with zero Repo. External/other srcs
  # never reach it (project/3 only calls it for media paths).
  defp og_resolver do
    fn "/media/files/" <> _ = _src ->
      %{
        "url" => "/media/renditions/mf-1/og",
        "width" => 1200,
        "height" => 630,
        "type" => "image/jpeg"
      }
    end
  end

  defp paper_opts(extra \\ %{}) do
    Map.merge(%{media_resolver: og_resolver(), url: "/papers/hello", doc_type: "paper"}, extra)
  end

  defp title_block(text),
    do: %{"id" => "t", "type" => "heading", "level" => 1, "role" => "title", "text" => text}

  defp paragraph(text),
    do: %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp image_block(attrs),
    do: Map.merge(%{"id" => "img", "type" => "image"}, attrs)

  describe "core manifest shape" do
    test "always returns the six string-keyed core fields" do
      m = Preview.project(%{"title" => "Hi"}, [], paper_opts())

      assert m["title"] == "Hi"
      assert m["type"] == "paper"
      assert m["url"] == "/papers/hello"
      assert Map.has_key?(m, "description")
      assert Map.has_key?(m, "image")
      assert is_map(m["extensions"])
    end

    test "type is the RAW doctype string from opts, else content[type], else document" do
      assert Preview.project(%{}, [], %{doc_type: "sheet"})["type"] == "sheet"
      assert Preview.project(%{"type" => "task"}, [], %{})["type"] == "task"
      assert Preview.project(%{}, [], %{})["type"] == "document"
    end

    test "url comes straight from opts (relative) and is nil when absent" do
      assert Preview.project(%{}, [], %{url: "/papers/x"})["url"] == "/papers/x"
      assert Preview.project(%{}, [], %{})["url"] == nil
    end
  end

  describe "title chain — content[title] → role:title block → row title" do
    test "content[title] wins" do
      m = Preview.project(%{"title" => "From Content"}, [title_block("From Block")], %{})
      assert m["title"] == "From Content"
    end

    test "falls back to the role:title block text" do
      m = Preview.project(%{}, [title_block("From Block")], %{})
      assert m["title"] == "From Block"
    end

    test "falls back to the injected row title, else nil" do
      assert Preview.project(%{}, [], %{title: "Row Title"})["title"] == "Row Title"
      assert Preview.project(%{}, [], %{})["title"] == nil
    end

    test "a blank content[title] is skipped for the block text" do
      m = Preview.project(%{"title" => "   "}, [title_block("Real")], %{})
      assert m["title"] == "Real"
    end
  end

  describe "image chain — featured → first image → nil" do
    test "the role:featured media block resolves to the og rendition" do
      blocks = [
        title_block("T"),
        image_block(%{"role" => "featured", "src" => "/media/files/a/hero.png", "alt" => "Hero"}),
        image_block(%{"id" => "img2", "src" => "/media/files/a/other.png"})
      ]

      m = Preview.project(%{}, blocks, paper_opts())

      assert m["image"] == %{
               "url" => "/media/renditions/mf-1/og",
               "width" => 1200,
               "height" => 630,
               "type" => "image/jpeg",
               "alt" => "Hero"
             }
    end

    test "with no featured block, the FIRST image block is used" do
      blocks = [
        title_block("T"),
        image_block(%{"id" => "i1", "src" => "/media/files/a/first.png", "alt" => "First"}),
        image_block(%{"id" => "i2", "src" => "/media/files/a/second.png"})
      ]

      m = Preview.project(%{}, blocks, paper_opts())
      assert m["image"]["alt"] == "First"
      assert m["image"]["url"] == "/media/renditions/mf-1/og"
    end

    test "featured is preferred even when it appears AFTER a plain image" do
      blocks = [
        image_block(%{"id" => "plain", "src" => "/media/files/a/plain.png", "alt" => "Plain"}),
        image_block(%{
          "id" => "feat",
          "role" => "featured",
          "src" => "/media/files/a/feat.png",
          "alt" => "Feat"
        })
      ]

      assert Preview.project(%{}, blocks, paper_opts())["image"]["alt"] == "Feat"
    end

    test "an image block with a blank/missing src is skipped" do
      blocks = [
        image_block(%{"id" => "empty", "src" => "   "}),
        image_block(%{"id" => "real", "src" => "/media/files/a/real.png", "alt" => "Real"})
      ]

      assert Preview.project(%{}, blocks, paper_opts())["image"]["alt"] == "Real"
    end

    test "no image blocks → image is nil (emitters show the branded default)" do
      assert Preview.project(%{}, [title_block("T"), paragraph("body")], paper_opts())["image"] ==
               nil
    end

    test "a field-bound image block is NOT body art (skipped)" do
      blocks = [
        %{
          "id" => "fi",
          "type" => "image",
          "fieldName" => "featuredImage",
          "src" => "/media/files/a/x.png"
        }
      ]

      assert Preview.project(%{}, blocks, paper_opts())["image"] == nil
    end
  end

  describe "image — external + degraded" do
    test "an external http(s) src passes through raw with the block's own dims" do
      blocks = [
        image_block(%{
          "src" => "https://cdn.example.com/x.png",
          "alt" => "Ext",
          "width" => 800,
          "height" => 400
        })
      ]

      m = Preview.project(%{}, blocks, paper_opts())

      assert m["image"] == %{
               "url" => "https://cdn.example.com/x.png",
               "width" => 800,
               "height" => 400,
               "alt" => "Ext",
               "type" => nil
             }
    end

    test "external image with no dims carries nil width/height" do
      blocks = [image_block(%{"src" => "https://cdn.example.com/x.png", "alt" => "Ext"})]
      m = Preview.project(%{}, blocks, paper_opts())
      assert m["image"]["width"] == nil and m["image"]["height"] == nil
    end

    test "DEGRADED (no media_resolver): a media image cannot be sized → nil" do
      blocks = [image_block(%{"role" => "featured", "src" => "/media/files/a/hero.png"})]
      # No :preview opts at all — the pure degraded path.
      assert Preview.project(%{}, blocks, %{})["image"] == nil
    end

    test "DEGRADED still passes an EXTERNAL image raw (it is self-contained)" do
      blocks = [image_block(%{"src" => "https://cdn.example.com/x.png", "alt" => "Ext"})]
      assert Preview.project(%{}, blocks, %{})["image"]["url"] == "https://cdn.example.com/x.png"
    end
  end

  describe "image alt — block alt → doc title" do
    test "the featured block's alt wins" do
      blocks = [
        image_block(%{
          "role" => "featured",
          "src" => "/media/files/a/h.png",
          "alt" => "Block Alt"
        })
      ]

      assert Preview.project(%{"title" => "Doc Title"}, blocks, paper_opts())["image"]["alt"] ==
               "Block Alt"
    end

    test "falls back to the document title when the block has no alt" do
      blocks = [image_block(%{"role" => "featured", "src" => "/media/files/a/h.png"})]

      assert Preview.project(%{"title" => "Doc Title"}, blocks, paper_opts())["image"]["alt"] ==
               "Doc Title"
    end
  end

  describe "description — excerpt → first paragraph → nil, ~110 word-boundary + ellipsis" do
    test "an explicit excerpt field wins over body paragraphs" do
      m =
        Preview.project(
          %{"excerpt" => "The hand-written summary."},
          [paragraph("Body prose here.")],
          %{}
        )

      assert m["description"] == "The hand-written summary."
    end

    test "content[description] and content[summary] also count as the excerpt" do
      assert Preview.project(%{"description" => "Desc."}, [], %{})["description"] == "Desc."
      assert Preview.project(%{"summary" => "Summ."}, [], %{})["description"] == "Summ."
    end

    test "falls back to the first FREE body paragraph's plain text" do
      blocks = [title_block("T"), paragraph("First real paragraph."), paragraph("Second.")]
      assert Preview.project(%{}, blocks, %{})["description"] == "First real paragraph."
    end

    test "an INGRESS lead counts as the first paragraph (A6 — eyebrow→heading→ingress openers)" do
      ingress = %{
        "id" => "i",
        "type" => "ingress",
        "content" => [%{"type" => "text", "value" => "The standfirst lead."}]
      }

      blocks = [title_block("T"), ingress, paragraph("Later prose.")]
      assert Preview.project(%{}, blocks, %{})["description"] == "The standfirst lead."
    end

    test "nil when there is no excerpt and no paragraph" do
      assert Preview.project(%{}, [title_block("T")], %{})["description"] == nil
    end

    test "long text truncates on a word boundary at ~110 chars with an ellipsis" do
      long =
        "This is a deliberately long lead paragraph that comfortably exceeds one hundred and ten characters so the truncation logic has to cut it back to a clean word boundary."

      desc = Preview.project(%{"excerpt" => long}, [], %{})["description"]
      base = String.trim_trailing(desc, "…")

      assert String.ends_with?(desc, "…")
      # Cut back to a word boundary (no dangling partial word) so `base` is still a
      # clean prefix of the source, and the whole thing stays near the ~110 cap.
      assert String.starts_with?(long, base)
      assert String.length(desc) <= 111
      refute String.ends_with?(base, " ")
    end

    test "text at/under the cap is returned verbatim (no ellipsis)" do
      short = "A short lead."
      assert Preview.project(%{"excerpt" => short}, [], %{})["description"] == short
    end
  end

  describe "description — inline-mark children recurse (D15 garble fix)" do
    # The canonical stored inline shape (inline.ex compose_inline) wraps a marked
    # span's text under "children", NOT "content". Before the children clause,
    # node_text saw no text under a strong/em/code/link node and every marked span
    # silently vanished — the live 'Barkpahis paper… writes , a compiler' garble.
    defp text_node(value), do: %{"type" => "text", "value" => value}
    defp mark(type, children), do: %{"type" => type, "children" => children}
    defp para(nodes), do: %{"id" => "p", "type" => "paragraph", "content" => nodes}

    defp desc(nodes),
      do: Preview.project(%{}, [para(nodes)], %{})["description"]

    test "a strong span's text is included, not dropped" do
      assert desc([
               text_node("before "),
               mark("strong", [text_node("bold")]),
               text_node(" after")
             ]) ==
               "before bold after"
    end

    test "an em span's text is included" do
      assert desc([text_node("say "), mark("em", [text_node("emphasis")]), text_node(" now")]) ==
               "say emphasis now"
    end

    test "code carried as children recurses" do
      assert desc([
               text_node("call "),
               mark("code", [text_node("project/3")]),
               text_node(" here")
             ]) ==
               "call project/3 here"
    end

    test "code carried as a value leaf still reads (both shapes exist)" do
      code_value = %{"type" => "code", "value" => "compose_inline"}

      assert desc([text_node("run "), code_value, text_node(" once")]) ==
               "run compose_inline once"
    end

    test "nested strong > em recurses through both marks" do
      nested = mark("strong", [mark("em", [text_node("deep")])])
      assert desc([text_node("go "), nested, text_node(" down")]) == "go deep down"
    end

    test "a theme-system-shaped paragraph (text/strong/text/strong/text) reads clean" do
      # Reproduces the live garble class: two strong spans between plain text. With
      # the fix the spans survive and the sentence reads clean; before it, the
      # dropped spans collapsed adjacent whitespace into the tell-tale double space.
      nodes = [
        text_node("Barkpark "),
        mark("strong", [text_node("theme-system")]),
        text_node(" lets this paper describe how the compiler "),
        mark("strong", [text_node("writes CSS")]),
        text_node(", a compiler for brand tokens across every single surface.")
      ]

      d = desc(nodes)

      # Both marked spans present — the garble dropped exactly these.
      assert d =~ "theme-system"
      assert d =~ "writes CSS"
      # No collapsed double space where a span used to vanish.
      refute d =~ "  "
      # Long lead → word-boundary cut at ~110 with an ellipsis.
      assert String.ends_with?(d, "…")
      assert String.length(d) <= 111
      assert String.starts_with?(d, "Barkpark theme-system lets this paper")
    end
  end

  describe "extensions — sparse, per-doctype (D9)" do
    test "paper: published_time / authors / tags / section, only when present" do
      content = %{
        "published_time" => "2026-07-09T00:00:00Z",
        "authors" => ["Ada", "Grace"],
        "tags" => ["og", "brand"],
        "section" => "Engineering"
      }

      ext = Preview.project(content, [], %{doc_type: "paper"})["extensions"]

      assert ext == %{
               "published_time" => "2026-07-09T00:00:00Z",
               "authors" => ["Ada", "Grace"],
               "tags" => ["og", "brand"],
               "section" => "Engineering"
             }
    end

    test "paper: a single author string is normalized to a list" do
      ext = Preview.project(%{"author" => "Ada"}, [], %{doc_type: "paper"})["extensions"]
      assert ext == %{"authors" => ["Ada"]}
    end

    test "task: status / assignee / done_ratio / priority" do
      content = %{
        "lifecycle_status" => "in_progress",
        "assignee" => "worker-1",
        "done_ratio" => 0.5,
        "priority" => 1
      }

      ext = Preview.project(content, [], %{doc_type: "task"})["extensions"]

      assert ext == %{
               "status" => "in_progress",
               "assignee" => "worker-1",
               "done_ratio" => 0.5,
               "priority" => 1
             }
    end

    test "task: priority 0 (highest) is kept, not compacted away" do
      ext = Preview.project(%{"priority" => 0}, [], %{doc_type: "task"})["extensions"]
      assert ext == %{"priority" => 0}
    end

    test "sheet: tab_count from tabs/sheets list" do
      assert Preview.project(%{"tabs" => [1, 2, 3]}, [], %{doc_type: "sheet"})["extensions"] == %{
               "tab_count" => 3
             }

      assert Preview.project(%{"sheets" => [1]}, [], %{doc_type: "sheet"})["extensions"] == %{
               "tab_count" => 1
             }
    end

    test "ticket: key / state read the REAL fields key_name / status (D16)" do
      # Real ticket docs store the sender under `key_name` and the turn indicator
      # under `status` (tickets.ex) — the shipped `key`/`state` reads never matched.
      content = %{"key_name" => "acme-support", "status" => "open"}
      ext = Preview.project(content, [], %{doc_type: "ticket"})["extensions"]

      # Output keys stay key/state per D9, sourced from the real fields.
      assert ext == %{"key" => "acme-support", "state" => "open"}
    end

    test "ticket: the legacy key/state fields no longer populate the ext" do
      # A doc carrying only the old (non-existent-in-prod) field names yields an
      # empty ext — proof we read key_name/status, not key/state.
      ext =
        Preview.project(%{"key" => "X", "state" => "Y"}, [], %{doc_type: "ticket"})["extensions"]

      assert ext == %{}
    end

    test "extensions are SPARSE — absent fields are omitted, not nil" do
      ext = Preview.project(%{"tags" => ["x"]}, [], %{doc_type: "paper"})["extensions"]
      assert ext == %{"tags" => ["x"]}
      refute Map.has_key?(ext, "authors")
    end

    test "an unknown doctype has an empty extensions map" do
      assert Preview.project(%{}, [], %{doc_type: "widget"})["extensions"] == %{}
    end
  end

  describe "degradation invariant — a core-only manifest with NO opts is valid" do
    test "project/2 (default opts) returns a valid, media-less card" do
      blocks = [
        title_block("Just A Title"),
        paragraph("Some prose that becomes the description.")
      ]

      m = Preview.project(%{}, blocks)

      assert m["title"] == "Just A Title"
      assert m["type"] == "document"
      assert m["description"] == "Some prose that becomes the description."
      assert m["url"] == nil
      assert m["image"] == nil
      assert m["extensions"] == %{}
    end

    test "is pure — calling twice on the same input yields identical bytes" do
      blocks = [title_block("T"), paragraph("Body.")]

      assert Preview.project(%{"title" => "T"}, blocks, paper_opts()) ==
               Preview.project(%{"title" => "T"}, blocks, paper_opts())
    end
  end

  describe "media_resolver/1 shape (interface, no DB)" do
    test "returns nil for a non-media src" do
      assert Preview.media_resolver().("https://x/y.png") == nil
      assert Preview.media_resolver().("/some/other/path") == nil
    end
  end

  # Sobelow Config.Secrets fix (task-f76e9b7b): the preview signing secret was
  # relocated OUT of config/config.exs (where Sobelow flagged the literal) into
  # config/dev.exs + config/test.exs (both in Sobelow's config skip-list); prod
  # requires PREVIEW_JWT_SECRET via runtime.exs. This fences that relocation —
  # the merged :preview config must still carry a usable secret alongside the
  # ttl_seconds/issuer base kept in config.exs, or preview-JWT signing silently
  # breaks in this env.
  describe ":preview config after Config.Secrets relocation" do
    test "the ambient test-env :preview config still carries secret + merged base" do
      preview = Application.get_env(:barkpark, :preview)

      assert is_binary(preview[:secret]) and preview[:secret] != ""
      # ttl_seconds/issuer stay in config.exs and merge per-key at boot.
      assert preview[:ttl_seconds] == 600
      assert preview[:issuer] == "barkpark"
    end
  end
end
