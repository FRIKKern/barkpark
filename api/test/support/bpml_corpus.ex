defmodule Barkpark.BpmlCorpus do
  @moduledoc """
  Papers for the BPML pull and push checks, written by this repo's writers in
  the test database, plus the stored shapes older writers and outside
  producers left in the corpus.

    * `shapes/0`: stored shapes printer.ex's comments count in the corpus, and
      the shapes a review probed. Today's writers do not all produce them, so
      `papers!/0` stores them raw, as the rows they were found in.
    * block goldens (`priv/portable_doc/goldens/blocks`), appended through the
      block-ops door (`Content.apply_paper_block_ops/4`), the editor's write
      path;
    * a Markdown document through `FromMarkdown` (GFM table alignment, a task
      list, a nested list), stored by `Content.upsert_paper/1`;
    * the template seed (`Template.maybe_seed/3`), stored by `upsert_paper/1`.

  A Paper whose writer refuses it is left out, and `papers!/0` names it.
  """

  alias Barkpark.{Content, LabelFixtures, Repo}
  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.FromMarkdown

  defp t(v), do: %{"type" => "text", "value" => v}
  defp para(content), do: %{"type" => "paragraph", "content" => content}

  @doc "`{name, block}` for each stored shape; `papers!/0` gives each an id."
  @spec shapes() :: [{String.t(), map()}]
  def shapes do
    [
      {"template title", hd(Template.template_blocks("Templated title"))},
      {"role", Map.put(para([t("Lede.")]), "role", "lede")},
      {"block _key", Map.put(para([t("Keyed.")]), "_key", "k1")},
      {"text _key", para([Map.put(t("Keyed run."), "_key", "s1")])},
      {"object mark bold", para([Map.put(t("b"), "marks", [%{"type" => "bold"}])])},
      {"object mark italic", para([Map.put(t("i"), "marks", [%{"type" => "italic"}])])},
      {"object mark code", para([Map.put(t("c"), "marks", [%{"type" => "code"}])])},
      {"bare mark bold", para([Map.put(t("b"), "marks", ["bold"])])},
      {"bare mark italic", para([Map.put(t("i"), "marks", ["italic"])])},
      {"bare mark code", para([Map.put(t("c"), "marks", ["code"])])},
      {"typed node in a text value",
       para([%{"type" => "text", "value" => %{"type" => "code", "value" => "x"}}])},
      {"number text value", para([%{"type" => "text", "value" => 42}])},
      {"marks nil", para([Map.put(t("a"), "marks", nil)])},
      {"bare strings only", para(["a ", "b"])},
      {"bare string beside a node", para(["raw ", t("node")])},
      {"single inline node as content", %{"type" => "paragraph", "content" => t("solo")}},
      {"code node", para([t("run "), %{"type" => "code", "value" => "mix"}])},
      {"strong node", para([%{"type" => "strong", "children" => [t("b")]}])},
      {"strong node holding a value",
       para([%{"type" => "strong", "children" => [t("seen")], "value" => "HIDDEN"}])},
      {"strong node holding marks",
       para([%{"type" => "strong", "children" => [t("seen")], "marks" => ["em"]}])},
      {"em node holding a link mark",
       para([%{"type" => "em", "children" => [t("seen")], "marks" => ["k1"]}])},
      {"strong node holding an href",
       para([%{"type" => "strong", "children" => [t("seen")], "href" => "/x"}])},
      {"empty text with a link mark", para([t("a"), Map.merge(t(""), %{"marks" => ["k1"]})])},
      {"empty text with a decorator", para([t("a"), Map.merge(t(""), %{"marks" => ["strong"]})])},
      {"heading level string", %{"type" => "heading", "level" => "2", "text" => "H"}},
      {"heading content-keyed", %{"type" => "heading", "level" => 2, "content" => [t("H")]}},
      {"heading align", %{"type" => "heading", "level" => 2, "text" => "H", "align" => "center"}},
      {"list item bare string", %{"type" => "list", "items" => ["a"]}},
      {"list item text map", %{"type" => "list", "items" => [%{"text" => "a"}]}},
      {"list item checked false",
       %{"type" => "list", "items" => [%{"content" => [t("a")], "checked" => false}]}},
      {"list item checked true",
       %{"type" => "list", "items" => [%{"content" => [t("a")], "checked" => true}]}},
      {"checklist",
       %{
         "type" => "list",
         "task" => true,
         "items" => [%{"content" => [t("a")], "checked" => true}]
       }},
      {"ordered list start",
       %{"type" => "list", "ordered" => true, "start" => 3, "items" => [[t("a")]]}},
      {"nested list item",
       %{
         "type" => "list",
         "items" => [
           %{"content" => [t("a")], "children" => [%{"type" => "list", "items" => [[t("b")]]}]}
         ]
       }},
      {"table head header cells",
       %{"type" => "table", "header" => [%{"header" => "H"}], "rows" => [[[t("c")]]]}},
      {"table head content cells",
       %{"type" => "table", "headers" => [%{"content" => [t("H")]}], "rows" => [[[t("c")]]]}},
      {"table head bare string", %{"type" => "table", "head" => ["H"], "rows" => [[[t("c")]]]}},
      {"table row bare string", %{"type" => "table", "head" => [[t("H")]], "rows" => [["c"]]}},
      {"table cols and headCol",
       %{
         "type" => "table",
         "headCol" => true,
         "cols" => [%{"type" => "num", "width" => 3}],
         "head" => [[t("H")]],
         "rows" => [[[t("1")]]]
       }},
      {"code lang", %{"type" => "code", "lang" => "elixir", "value" => "x"}},
      {"code language key", %{"type" => "code", "language" => "elixir", "value" => "x"}},
      {"code body as list", %{"type" => "code", "code" => [t("x")]}},
      {"expandable title alias",
       %{"type" => "expandable", "title" => "S", "children" => [para([t("x")])]}},
      {"cards body alias", %{"type" => "cards", "items" => [%{"title" => "T", "body" => "B"}]}},
      {"callout title and content",
       %{"type" => "callout", "tone" => "info", "title" => "T", "content" => [t("x")]}},
      {"callout body slot",
       %{
         "type" => "callout",
         "tone" => "info",
         "slots" => %{"body" => [para([t("x")]), para([t("y")])]}
       }},
      {"step content nil",
       %{"type" => "steps", "steps" => [%{"title" => "x", "content" => nil}]}},
      {"step children []",
       %{"type" => "steps", "steps" => [%{"title" => "x", "children" => []}]}},
      {"empty step", %{"type" => "steps", "steps" => [%{"title" => "S"}]}},
      {"notes bare string", %{"type" => "notes", "items" => ["A remedy"]}},
      {"note content []", %{"type" => "note", "text" => "N", "content" => []}},
      {"byline value map", %{"type" => "byline", "items" => [%{"value" => "By me"}]}},
      {"section map variant",
       %{"type" => "section", "variant" => %{"a" => 1}, "blocks" => [para([t("x")])]}},
      {"paragraph text alias", %{"type" => "paragraph", "text" => "Alias body"}}
    ]
  end

  @markdown """
  # A converted Paper

  Some *emphasis*, **strength**, `code` and a [link](https://example.com).

  | Left | Middle | Right |
  |:-----|:------:|------:|
  | a    | b      | c     |

  - [x] done
  - [ ] to do

  - parent
    - child
      - grandchild

  1. first
  2. second
  """

  @doc """
  Writes the corpus and returns `{papers, left_out}`: `papers` is
  `[{slug, writer}]`, `left_out` is `[{name, reason}]` for what a writer refused.
  """
  @spec papers!(String.t()) :: {[{String.t(), String.t()}], [{String.t(), term()}]}
  def papers!(prefix \\ "bpml-corpus") do
    shapes =
      for {name, block} <- shapes(),
          do: {"#{prefix}-shape-#{slug(name)}", "stored shape", [block]}

    goldens =
      for path <-
            Path.wildcard(
              Path.expand("../../priv/portable_doc/goldens/blocks/*.golden.json", __DIR__)
            )
            |> Enum.sort(),
          %{"input" => block} = Jason.decode!(File.read!(path)) do
        {"#{prefix}-golden-#{Path.basename(path, ".golden.json")}", "block ops", [block]}
      end

    written =
      Enum.map(shapes, fn {slug, writer, blocks} -> {slug, writer, raw!(slug, blocks)} end) ++
        Enum.map(goldens, fn {slug, writer, blocks} -> {slug, writer, ops!(slug, blocks)} end) ++
        [
          {"#{prefix}-markdown", "FromMarkdown + upsert_paper",
           upsert!("#{prefix}-markdown", FromMarkdown.blocks(@markdown))},
          {"#{prefix}-template", "Template.maybe_seed + upsert_paper",
           upsert!(
             "#{prefix}-template",
             Template.maybe_seed([para([t("Body.")])], nil, %{
               "template" => true,
               "title" => "Seeded"
             })
           )}
        ]

    {for({slug, writer, :ok} <- written, do: {slug, writer}),
     for({slug, _writer, {:error, reason}} <- written, do: {slug, reason})}
  end

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp upsert!(slug, blocks) do
    case Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A stored shape, written as the row an older writer left: the Paper is
  # created by `upsert_paper/1`, then its blocks (with the ids every write path
  # mints) are set on the row.
  defp raw!(slug, blocks) do
    with :ok <- upsert!(slug, [para([t("Seed.")])]) do
      paper = Content.get_paper(slug)
      blocks = Barkpark.PortableDoc.BlockIds.ensure_persisted_block_ids(blocks)
      content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
      paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
      :ok
    end
  end

  # A Paper whose blocks arrive through the block-ops door, one append each.
  defp ops!(slug, blocks) do
    with :ok <- upsert!(slug, [para([t("Seed.")])]),
         {:ok, _} <-
           Content.apply_paper_block_ops(
             slug,
             Enum.map(blocks, &%{"op" => "append-block", "block" => &1})
           ) do
      :ok
    end
  end
end
