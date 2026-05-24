# Seed the `composite-demo-p23` paper for P2.3 (barkpark-wxxa) — one block per
# implemented v2 COMPOSITE field type, each with valid inline CONFIG + a sample
# value. Run with:  mix run priv/repo/seed_composite_demo_p23.exs
#
# Value shapes (research): composite %{sub=>val} · arrayOf [el,…] ·
# codelist "code" · localizedText %{lang=>text}.

alias Barkpark.Content

dataset = "production"
slug = "composite-demo-p23"

blocks = [
  %{
    "id" => "intro",
    "type" => "paragraph",
    "content" => [
      %{"type" => "text", "value" => "P2.3 composite field-type demo. One block per implemented v2 composite."}
    ]
  },

  # composite → %{sub => val}. Inline config: `fields` = subfield descriptors.
  %{
    "id" => "fb-composite",
    "type" => "composite",
    "label" => "Price",
    "fields" => [
      %{"name" => "amount", "title" => "Amount", "type" => "string"},
      %{"name" => "currency", "title" => "Currency", "type" => "string"},
      %{"name" => "includesTax", "title" => "Includes Tax", "type" => "boolean"}
    ],
    "value" => %{"amount" => "299", "currency" => "NOK", "includesTax" => true}
  },

  # arrayOf → [el,…]. Inline config: `ordered` + `of` element descriptor.
  %{
    "id" => "fb-array",
    "type" => "arrayOf",
    "label" => "Keywords",
    "ordered" => true,
    "of" => %{"name" => "keyword", "type" => "string"},
    "value" => ["history", "norway", "maritime"]
  },

  # codelist → "code". Inline config: `codelistId` + pinned `version`.
  %{
    "id" => "fb-codelist",
    "type" => "codelist",
    "label" => "Audience (ONIX List 28)",
    "codelistId" => "onixedit:audience",
    "version" => 73,
    "value" => "01"
  },

  # localizedText → %{lang => text}. Inline config: `languages` + `format` +
  # `fallbackChain`.
  %{
    "id" => "fb-localized",
    "type" => "localizedText",
    "label" => "Blurb",
    "languages" => ["nob", "eng"],
    "format" => "plain",
    "fallbackChain" => ["nob", "eng"],
    "value" => %{"nob" => "En kort omtale.", "eng" => "A short blurb."}
  }
]

{:ok, paper} = Content.upsert_paper(%{slug: slug, dataset: dataset, blocks: blocks})

IO.puts("Seeded paper #{paper.doc_id} (dataset=#{dataset}) with #{length(blocks)} blocks.")
IO.puts("Block types: " <> Enum.map_join(blocks, ", ", & &1["type"]))
IO.puts("URL: /studio/#{dataset}/paper/#{slug}")
