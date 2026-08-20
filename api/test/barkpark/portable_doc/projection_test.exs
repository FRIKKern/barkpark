defmodule Barkpark.PortableDoc.ProjectionTest do
  @moduledoc """
  Exp-P2 (barkpark-emxg) — the bound/free block model + project-on-write,
  tested PURELY (no DB). Confirms the partition rule, that a bound block
  projects its value to content[fieldName], that free blocks fold into
  content["body"] (JSON + rendered HTML), and that the lazy synthesis
  round-trip is byte-equal.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Projection, Synthesis}

  describe "bound?/1 + partition/2" do
    test "a field-block WITH a non-blank fieldName is bound; everything else free" do
      bound = %{"id" => "b1", "type" => "field-string", "fieldName" => "title", "value" => "Hi"}
      free_para = %{"id" => "p1", "type" => "paragraph", "content" => []}
      blank_name = %{"id" => "b2", "type" => "field-slug", "fieldName" => "", "value" => "x"}
      no_name = %{"id" => "b3", "type" => "field-slug", "value" => "y"}

      assert Projection.bound?(bound)
      refute Projection.bound?(free_para)
      refute Projection.bound?(blank_name)
      refute Projection.bound?(no_name)

      {bound_list, free_list} = Projection.partition([bound, free_para, blank_name, no_name])
      assert bound_list == [bound]
      assert free_list == [free_para, blank_name, no_name]
    end
  end

  describe "read_blocks/1" do
    test "prefers a present top-level block list, including an empty list" do
      nested = [%{"id" => "nested", "type" => "paragraph"}]

      assert Projection.read_blocks(%{
               "blocks" => [],
               "body" => %{"blocks" => nested}
             }) == []
    end

    test "falls back to the projected body block list" do
      nested = [%{"id" => "nested", "type" => "paragraph"}]

      assert Projection.read_blocks(%{"body" => %{"blocks" => nested}}) == nested
    end

    test "accepts a bare body block array" do
      blocks = [%{"id" => "bare", "type" => "divider"}]
      assert Projection.read_blocks(%{"body" => blocks}) == blocks
    end

    test "adapts a non-blank legacy Markdown body" do
      assert [%{"type" => "heading", "text" => "Legacy"} | _] =
               Projection.read_blocks(%{"body" => "# Legacy\n\nStill readable."})

      assert Projection.read_blocks(%{"body" => "  \n"}) == nil
    end

    test "returns nil when neither representation contains a block list" do
      assert Projection.read_blocks(%{}) == nil
      assert Projection.read_blocks(%{"blocks" => "invalid", "body" => %{}}) == nil
    end
  end

  describe "project/3 — the sole writer of content[fieldName] + content[\"body\"]" do
    test "each bound block projects value to content[fieldName]; free blocks → body" do
      blocks = [
        %{"id" => "t", "type" => "field-string", "fieldName" => "title", "value" => "My Post"},
        %{"id" => "s", "type" => "field-slug", "fieldName" => "slug", "value" => "my-post"},
        %{
          "id" => "i",
          "type" => "field-image",
          "fieldName" => "featuredImage",
          "value" => "/x.jpg"
        },
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Hello body."}]
        }
      ]

      content = Projection.project(%{"blocks" => blocks, "rev" => 3}, blocks)

      assert content["title"] == "My Post"
      assert content["slug"] == "my-post"
      assert content["featuredImage"] == "/x.jpg"

      # body is a first-class %{"blocks", "html"} — only the FREE paragraph.
      assert content["body"]["blocks"] == [List.last(blocks)]
      assert is_binary(content["body"]["html"])
      assert content["body"]["html"] =~ "Hello body."

      # Unrelated content keys survive untouched.
      assert content["blocks"] == blocks
      assert content["rev"] == 3
    end

    test "projecting an empty block list yields an empty body and no field keys" do
      content = Projection.project(%{}, [])
      assert content["body"] == %{"blocks" => [], "html" => ""}
      refute Map.has_key?(content, "title")
    end

    test "a boolean bound block projects a real boolean, not a string" do
      blocks = [
        %{"id" => "f", "type" => "field-boolean", "fieldName" => "featured", "value" => true}
      ]

      content = Projection.project(%{}, blocks)
      assert content["featured"] == true
    end

    test "project/4 clears the orphan index entry when a bound field is unbound" do
      bound = %{
        "id" => "b1",
        "type" => "arrayOf",
        "fieldName" => "aliases",
        "of" => %{"type" => "string"},
        "value" => ["a", "b"]
      }

      # Unbind = the same block with fieldName cleared (the patch-block fieldName→nil
      # shape; patch.ex keeps the key present-but-nil so bound?/1 reads it FREE).
      freed = Map.put(bound, "fieldName", nil)
      content = %{"aliases" => ["a", "b"]}

      out = Projection.project(content, [bound], [freed], %{})

      # The orphaned index entry is dropped...
      refute Map.has_key?(out, "aliases")
      # ...and the now-free block lands in the body.
      body_blocks = get_in(out, ["body", "blocks"]) || []
      assert Enum.any?(body_blocks, &(&1["id"] == "b1"))
    end

    test "project/4 is byte-identical to project/3 when the bound set is unchanged" do
      blocks = [%{"id" => "b1", "type" => "field-string", "fieldName" => "title", "value" => "X"}]
      assert Projection.project(%{}, blocks, blocks, %{}) == Projection.project(%{}, blocks)
    end
  end

  describe "content[\"preview\"] — stamped alongside content[\"body\"] when opted in" do
    test "NO :preview render_opt ⇒ NO stamp (the A2 gate)" do
      blocks = [
        %{"id" => "t", "type" => "field-string", "fieldName" => "title", "value" => "My Post"},
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Lead prose."}]
        }
      ]

      # Projection callers that don't opt in (sheets/forms/proposals scaffolds,
      # doctrine backfill) must not stamp a degraded manifest: it would
      # overwrite a rich card on re-save and shadow the reader's read-time
      # fallback, which only recomputes when content["preview"] is absent.
      content = Projection.project(%{}, blocks)

      refute Map.has_key?(content, "preview")
      # body projection is unaffected by the gate
      assert content["body"]["html"] =~ "Lead prose."
    end

    test "a minimal :preview opt map stamps a valid degraded manifest" do
      blocks = [
        %{"id" => "t", "type" => "field-string", "fieldName" => "title", "value" => "My Post"},
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Lead prose."}]
        }
      ]

      preview = Projection.project(%{}, blocks, blocks, %{preview: %{}})["preview"]

      # The projected content[title] flows into the manifest; body prose becomes
      # the description; no media_resolver ⇒ nil image, still a valid card.
      assert preview["title"] == "My Post"
      assert preview["description"] == "Lead prose."
      assert preview["image"] == nil
      assert is_map(preview["extensions"])
    end

    test "the injected :preview render_opt drives type/url/image" do
      resolver = fn "/media/files/" <> _ ->
        %{
          "url" => "/media/renditions/x/og",
          "width" => 1200,
          "height" => 630,
          "type" => "image/jpeg"
        }
      end

      blocks = [
        %{"id" => "h", "type" => "heading", "level" => 1, "role" => "title", "text" => "Hello"},
        %{
          "id" => "f",
          "type" => "image",
          "role" => "featured",
          "src" => "/media/files/a/h.png",
          "alt" => "Art"
        }
      ]

      render_opts = %{
        preview: %{media_resolver: resolver, url: "/papers/hello", doc_type: "paper"}
      }

      preview = Projection.project(%{}, blocks, blocks, render_opts)["preview"]

      assert preview["type"] == "paper"
      assert preview["url"] == "/papers/hello"
      assert preview["image"]["url"] == "/media/renditions/x/og"
      assert preview["image"]["alt"] == "Art"
    end

    test "is recomputed on every project — no drift from the block list" do
      v1 = [%{"id" => "h", "type" => "heading", "role" => "title", "text" => "First"}]
      v2 = [%{"id" => "h", "type" => "heading", "role" => "title", "text" => "Renamed"}]
      opts = %{preview: %{doc_type: "paper"}}

      assert Projection.project(%{}, v1, v1, opts)["preview"]["title"] == "First"
      assert Projection.project(%{}, v2, v2, opts)["preview"]["title"] == "Renamed"
    end

    test "the extra :preview render_opt key does not leak into the rendered body html" do
      blocks = [
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Body."}]
        }
      ]

      render_opts = %{preview: %{doc_type: "paper", url: "/papers/x"}}

      content = Projection.project(%{}, blocks, blocks, render_opts)
      refute content["body"]["html"] =~ "preview"
      refute content["body"]["html"] =~ "doc_type"
    end
  end

  describe "Synthesis.synthesize/3 — lazy in-memory synthesis, byte-equal round-trip" do
    @layout [
      %{"kind" => "field", "name" => "title"},
      %{"kind" => "field", "name" => "slug"},
      %{"kind" => "field", "name" => "featuredImage"},
      %{"kind" => "region", "name" => "body"}
    ]

    @fields [
      %{"name" => "title", "type" => "string"},
      %{"name" => "slug", "type" => "slug"},
      %{"name" => "featuredImage", "type" => "image"},
      %{"name" => "body", "type" => "richText"}
    ]

    test "synthesizes bound field-blocks + a body paragraph, and round-trips byte-equal" do
      # A LEGACY post: classic content keys, body as a plain richText string,
      # NO content["blocks"]. (title folded in by the caller as content["title"].)
      legacy = %{
        "title" => "Legacy Title",
        "slug" => "legacy-title",
        "featuredImage" => "/hero.png",
        "body" => "The original prose."
      }

      blocks = Synthesis.synthesize(@layout, legacy, @fields)

      # One bound block per field that had a value, in layout order, then body.
      assert [title_b, slug_b, img_b, body_b] = blocks
      assert title_b["fieldName"] == "title" and title_b["type"] == "field-string"
      assert slug_b["fieldName"] == "slug" and slug_b["type"] == "field-slug"
      assert img_b["fieldName"] == "featuredImage" and img_b["type"] == "field-image"
      assert body_b["type"] == "paragraph"
      refute Map.has_key?(body_b, "fieldName")

      # THE no-rewrite invariant: project the synthesized blocks → the bound
      # field values are byte-equal to the originals.
      projected = Projection.project(%{}, blocks)
      assert projected["title"] == legacy["title"]
      assert projected["slug"] == legacy["slug"]
      assert projected["featuredImage"] == legacy["featuredImage"]
      # body text survives the string → paragraph → html reproduction.
      assert projected["body"]["html"] =~ "The original prose."
    end

    test "a field absent from content is skipped (stays absent after project)" do
      legacy = %{"title" => "Only Title"}
      blocks = Synthesis.synthesize(@layout, legacy, @fields)
      projected = Projection.project(%{}, blocks)

      assert projected["title"] == "Only Title"
      refute Map.has_key?(projected, "slug")
      refute Map.has_key?(projected, "featuredImage")
      assert projected["body"] == %{"blocks" => [], "html" => ""}
    end

    test "an already-projected body map reuses its free blocks verbatim" do
      free = [
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "x"}]}
      ]

      content = %{"title" => "T", "body" => %{"blocks" => free, "html" => "<x>"}}
      blocks = Synthesis.synthesize(@layout, content, @fields)
      # The body region reuses the stored blocks (not a re-wrapped string).
      assert List.last(blocks) == List.last(free)
    end
  end
end
