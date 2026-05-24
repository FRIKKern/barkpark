# Seed the P3.2 reorder demo paper: 5 distinguishable paragraph blocks
# ("Block A".."Block E") so the order is obvious in both the View pane and the
# Edit-mode block list. Idempotent: upsert_paper keys on {dataset, slug}.
#
#   cd api && mix run priv/repo/seed_reorder_demo_p32.exs
#
alias Barkpark.Content

slug = "reorder-demo-p32"
dataset = "production"

# Ensure the "paper" schema exists in this dataset so the desk + editor mount.
{:ok, _} =
  Content.upsert_schema(
    %{
      "name" => "paper",
      "title" => "Papers",
      "icon" => "📰",
      "visibility" => "public",
      "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
    },
    dataset
  )

blocks =
  for letter <- ~w(A B C D E) do
    %{
      "id" => "rd-#{String.downcase(letter)}",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Block #{letter}"}]
    }
  end

# Prepend a heading so the desk-list title is meaningful.
blocks = [%{"id" => "rd-h", "type" => "heading", "text" => "Reorder Demo (P3.2)", "level" => 1} | blocks]

{:ok, doc} = Content.upsert_paper(%{slug: slug, dataset: dataset, blocks: blocks})

order =
  doc.content["blocks"]
  |> Enum.map(&Map.get(&1, "id"))
  |> Enum.join(", ")

IO.puts("seeded paper #{doc.doc_id} (dataset=#{dataset}) block order: #{order}")
