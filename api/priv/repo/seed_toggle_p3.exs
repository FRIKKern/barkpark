# Exp-P3.2 demo seed (barkpark-g2ql). Run with:
#   MIX_ENV=dev mix run priv/repo/seed_toggle_p3.exs
#
# Seeds `toggle-demo-p3` — a `post` with a content["blocks"] list carrying:
#   * bound title / slug / featuredImage blocks (Classic edits these), and
#   * TWO free body paragraphs (the Beta-only premium-engine content).
# Open it in Studio and use the Classic <-> Beta toggle in the editor header.

alias Barkpark.Content
alias Barkpark.PortableDoc.Projection

dataset = "production"

# Ensure the `post` Expectation (explicit layout + prefill) exists.
{:ok, _} =
  Content.upsert_schema(
    %{
      "name" => "post",
      "title" => "Post",
      "visibility" => "public",
      "fields" => [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "slug", "title" => "Slug", "type" => "slug"},
        %{"name" => "featuredImage", "title" => "Featured Image", "type" => "image"},
        %{"name" => "body", "title" => "Body", "type" => "richText"}
      ],
      "layout" => [
        %{"kind" => "field", "name" => "title"},
        %{"kind" => "field", "name" => "slug"},
        %{"kind" => "field", "name" => "featuredImage"},
        %{"kind" => "region", "name" => "body"}
      ],
      "prefill" => %{"status" => "draft"}
    },
    dataset
  )

# A bound title/slug/featuredImage + 2 free body paragraphs, projected so
# content[fieldName]/content["body"] match the blocks (the byte-equal invariant).
blocks = [
  %{"id" => "b-title", "type" => "field-string", "fieldName" => "title", "label" => "Title", "value" => "Toggle Demo Post"},
  %{"id" => "b-slug", "type" => "field-slug", "fieldName" => "slug", "label" => "Slug", "value" => "toggle-demo"},
  %{"id" => "b-img", "type" => "field-image", "fieldName" => "featuredImage", "label" => "Featured Image", "value" => ""},
  %{"id" => "free-p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "First free body paragraph (premium engine)."}]},
  %{"id" => "free-p2", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "Second free body paragraph (premium engine)."}]}
]

content = Projection.project(%{"blocks" => blocks}, blocks)

{:ok, post} =
  Content.upsert_document(
    "post",
    %{"doc_id" => "toggle-demo-p3", "title" => "Toggle Demo Post", "content" => content},
    dataset
  )

IO.puts("\n=== toggle-demo-p3 (Classic <-> Beta toggle demo) ===")
IO.puts("doc_id (row)          = #{inspect(post.doc_id)}")
IO.puts("documents.title (row) = #{inspect(post.title)}")
IO.puts("content[\"blocks\"] =")

post.content["blocks"]
|> Enum.with_index()
|> Enum.each(fn {b, i} -> IO.puts("  [#{i}] #{inspect(b)}") end)

IO.puts("\nprojected fields:")
IO.puts("content[title]        = #{inspect(post.content["title"])}")
IO.puts("content[slug]         = #{inspect(post.content["slug"])}")
IO.puts("content[featuredImage]= #{inspect(post.content["featuredImage"])}")
IO.puts("content[body][html]   = #{inspect(post.content["body"]["html"])}")

IO.puts("\nOpen in Studio:  /studio/#{dataset}/post/toggle-demo-p3")
IO.puts("Toggle: editor header -> Classic / Beta segmented control")
