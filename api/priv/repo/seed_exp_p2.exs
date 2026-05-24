# Exp-P2 demo seed (barkpark-emxg). Run with:
#   MIX_ENV=dev mix run priv/repo/seed_exp_p2.exs
#
# Seeds, through the REAL project-on-write path (Content.upsert_paper/1 →
# Projection.project/3):
#   * exp-post-p2 — a paper WITH a block list: bound title/slug/featuredImage +
#     a free body paragraph. Projection populates content[title/slug/
#     featuredImage/body].
#   * exp-legacy-p2 — a legacy paper with classic field values + a richText body
#     STRING and NO content["blocks"], for the lazy-synthesis demo.

alias Barkpark.Content
alias Barkpark.PortableDoc.Projection

dataset = "production"

# Ensure a post-style paper schema with the Exp-P1 layout exists so synthesis
# has fields + layout. Idempotent on (name, dataset).
{:ok, _} =
  Content.upsert_schema(
    %{
      "name" => "paper",
      "title" => "Papers",
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
      ]
    },
    dataset
  )

# ── exp-post-p2: bound + free blocks, projected on write ──
blocks = [
  %{"id" => "b-title", "type" => "field-string", "fieldName" => "title", "value" => "Portable Doc Meets Expectations"},
  %{"id" => "b-slug", "type" => "field-slug", "fieldName" => "slug", "value" => "exp-post-p2"},
  %{"id" => "b-img", "type" => "field-image", "fieldName" => "featuredImage", "value" => "/media/exp-hero.jpg"},
  %{
    "id" => "b-p1",
    "type" => "paragraph",
    "content" => [%{"type" => "text", "value" => "A document's blocks are one ordered list of bound and free blocks."}]
  },
  %{
    "id" => "b-p2",
    "type" => "paragraph",
    "content" => [%{"type" => "text", "value" => "Bound blocks project into content[fieldName]; free blocks fold into doc.body."}]
  }
]

{:ok, post} = Content.upsert_paper(%{slug: "exp-post-p2", dataset: dataset, blocks: blocks})

IO.puts("\n=== exp-post-p2 (projected) ===")
IO.puts("content[title]        = #{inspect(post.content["title"])}")
IO.puts("content[slug]         = #{inspect(post.content["slug"])}")
IO.puts("content[featuredImage]= #{inspect(post.content["featuredImage"])}")
IO.puts("content[body][blocks] = #{length(post.content["body"]["blocks"])} free block(s)")
IO.puts("content[body][html]   = #{post.content["body"]["html"]}")
IO.puts("documents.title (row) = #{inspect(post.title)}")

# ── exp-legacy-p2: classic-only doc, no blocks (synthesis target) ──
{:ok, legacy} = Content.upsert_paper(%{slug: "exp-legacy-p2", dataset: dataset, body_html: "<p>legacy html</p>"})

legacy =
  legacy
  |> Ecto.Changeset.change(
    content:
      Map.merge(legacy.content, %{
        "slug" => "exp-legacy-p2",
        "featuredImage" => "/media/legacy-hero.jpg",
        "body" => "This legacy post stored its prose as a richText string."
      })
  )
  |> Barkpark.Repo.update!()

{synth_blocks, synthesized?} = Content.resolve_blocks_for_edit(legacy, "paper", dataset)
projected = Projection.project(%{}, synth_blocks)
reloaded = Content.get_paper("exp-legacy-p2", dataset)

IO.puts("\n=== exp-legacy-p2 (lazy synthesis demo) ===")
IO.puts("synthesized?          = #{synthesized?}  (no content[blocks] stored)")
IO.puts("synth block count     = #{length(synth_blocks)}")
IO.puts("round-trip title      = #{inspect(projected["title"])} == row #{inspect(legacy.title)} ? #{projected["title"] == legacy.title}")
IO.puts("round-trip slug       = #{inspect(projected["slug"])} == #{inspect(legacy.content["slug"])} ? #{projected["slug"] == legacy.content["slug"]}")
IO.puts("round-trip image      = #{inspect(projected["featuredImage"])} == #{inspect(legacy.content["featuredImage"])} ? #{projected["featuredImage"] == legacy.content["featuredImage"]}")
IO.puts("round-trip body text  = #{projected["body"]["html"] =~ "richText string"}")
IO.puts("NO REWRITE: stored content has \"blocks\"? #{Map.has_key?(reloaded.content, "blocks")} (must be false)")
