# Exp-P3.1 demo seed (barkpark-ibsk). Run with:
#   MIX_ENV=dev mix run priv/repo/seed_exp_p3.exs
#
# Seeds, through the REAL create-from-Expectation path
# (Content.create_document/4 → Synthesis.scaffold/4 → Projection.project/3):
#   * exp-create-p3 — a fresh `post` created with only a title. The Expectation
#     is instantiated into content["blocks"]: bound title/slug/featuredImage in
#     layout order + the body region as a single empty paragraph placeholder.
#     Projection then derives content[title/slug/featuredImage/body].

alias Barkpark.Content

dataset = "production"

# Ensure the `post` Expectation (explicit layout + prefill) exists. Idempotent
# on (name, dataset). Mirrors the seeds.exs `post` schema's Exp-P1 layout.
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
      "prefill" => %{"status" => "draft", "featured" => false}
    },
    dataset
  )

{:ok, post} =
  Content.create_document(
    "post",
    %{"doc_id" => "exp-create-p3", "title" => "Created From Expectation"},
    dataset
  )

IO.puts("\n=== exp-create-p3 (create-from-Expectation scaffold) ===")
IO.puts("doc_id                = #{inspect(post.doc_id)}")
IO.puts("content[\"blocks\"] =")

post.content["blocks"]
|> Enum.with_index()
|> Enum.each(fn {b, i} -> IO.puts("  [#{i}] #{inspect(b)}") end)

IO.puts("\nprojected fields:")
IO.puts("content[title]        = #{inspect(post.content["title"])}")
IO.puts("content[slug]         = #{inspect(post.content["slug"])}")
IO.puts("content[featuredImage]= #{inspect(post.content["featuredImage"])}")
IO.puts("content[body]         = #{inspect(post.content["body"])}")
IO.puts("documents.title (row) = #{inspect(post.title)}")
