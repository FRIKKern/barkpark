# Seed the `codelist-demo-p2b` paper for Polish-2 (barkpark-5srz) — the codelist
# field block made fully usable in the in-Studio paper editor. Two codelist
# blocks, each pointing at a REAL registered OnixEdit codelist (the dev seed
# populates the OnixEdit lists), plus an intro paragraph:
#
#   * a FLAT codelist  → onixedit:list_15 ("Title type", 16 flat entries) →
#     renders CodelistField's native <select>; value "01" resolves in View to
#     its English label.
#   * a TREE codelist  → onixedit:thema (~9k hierarchical entries) with
#     variant:"tree" → PaperFieldBlock hosts the stateful TreeCodelistField
#     (expand / select / search); value "FBA" resolves to its label.
#
# Run with:  mix run priv/repo/seed_codelist_demo_p2b.exs

alias Barkpark.Content

dataset = "production"
slug = "codelist-demo-p2b"

blocks = [
  %{
    "id" => "intro",
    "type" => "paragraph",
    "content" => [
      %{
        "type" => "text",
        "value" =>
          "Polish-2 codelist demo. A FLAT codelist (<select>) and a TREE codelist (hierarchical picker), both bound to registered OnixEdit codelists."
      }
    ]
  },

  # FLAT codelist → "code". `plugin` is the registry discriminator (OnixEdit
  # lists live under "onixedit"). codelistId points at the small flat list 15.
  # variant defaults to "flat" (a native CodelistField <select>).
  %{
    "id" => "cl-flat",
    "type" => "codelist",
    "label" => "Title type (ONIX List 15)",
    "plugin" => "onixedit",
    "codelistId" => "onixedit:list_15",
    "version" => 73,
    "variant" => "flat",
    "value" => "01"
  },

  # TREE codelist → "code". onixedit:thema is hierarchical (~9k entries);
  # variant:"tree" makes PaperFieldBlock host the TreeCodelistField directly
  # inside its form. "FBA" is a leaf under F › FB.
  %{
    "id" => "cl-tree",
    "type" => "codelist",
    "label" => "Thema subject category",
    "plugin" => "onixedit",
    "codelistId" => "onixedit:thema",
    "version" => 73,
    "variant" => "tree",
    "value" => "FBA"
  }
]

{:ok, paper} = Content.upsert_paper(%{slug: slug, dataset: dataset, blocks: blocks})

IO.puts("Seeded paper #{paper.doc_id} (dataset=#{dataset}) with #{length(blocks)} blocks.")
IO.puts("Block types: " <> Enum.map_join(blocks, ", ", & &1["type"]))
IO.puts("URL: /studio/#{dataset}/paper/#{slug}")
