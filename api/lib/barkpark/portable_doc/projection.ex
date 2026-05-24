defmodule Barkpark.PortableDoc.Projection do
  @moduledoc """
  The bound/free block model + project-on-write — the heart of Portable Doc +
  Expectations (Exp-P2, barkpark-emxg).

  A document's `content["blocks"]` is ONE ordered list of two kinds of block:

    * **BOUND** — a field-block (any `field-*` block, or a v2 `composite` /
      `arrayOf` / `codelist` / `localizedText` block) carrying an extra
      `"fieldName"` key. A bound block is tied to a schema field. It is NOT part
      of the body — it PROJECTS into `content[fieldName]`, a derived,
      always-in-sync index that existing Classic queries read unchanged.

    * **FREE** — any block WITHOUT a `"fieldName"` key (rich text, headings,
      images, dividers, …). Free blocks fold into a first-class
      `content["body"] = %{"blocks" => free_blocks, "html" => rendered}`.

  ## Representation (the chosen shape)

  A bound block is an existing field-block PLUS one extra string key,
  `"fieldName"`:

      %{"id" => "b1", "type" => "field-string", "fieldName" => "title",
        "value" => "Hello"}

  This reuses every existing field-block editor and `Render.compose_block/1`
  clause verbatim — a bound block is just a field-block with one more key, so
  it still round-trips through all five patch ops unchanged (`fieldName` is
  carried like any other key). A block WITHOUT `fieldName` is free.

  The partition is purely the presence of a non-blank string `"fieldName"`:
  `bound?/1`. Everything else is free.

  ## Project-on-write — the single source of truth

  `project/3` is the SOLE writer of `content[fieldName]` and `content["body"]`.
  It walks the block list ONCE:

    * every bound block → `content[fieldName] = projected_value(block)`
    * all free blocks  → `content["body"] = %{"blocks" => free, "html" => …}`

  Nothing else may write those keys — that is the no-drift guarantee. The walk
  is folded into the write path in `Content.apply_paper_block_op/3` and
  `Content.upsert_paper/1`, so any op or whole-doc write re-derives the index
  from the blocks it just persisted.

  Pure: `project/3` performs no Repo access and never mutates its input — it
  returns a new `content` map. HTML rendering is delegated to
  `Barkpark.PortableDoc.Render.render_blocks/2`; the caller supplies the same
  `render_opts` it already builds for `body_html`.
  """

  alias Barkpark.PortableDoc.Render

  @typedoc "A portable-doc block — a string-keyed map."
  @type block :: %{required(String.t()) => term()}
  @type content :: %{required(String.t()) => term()}

  @doc """
  True when `block` is a BOUND field-block — it carries a non-blank string
  `"fieldName"`. Any other block (no `fieldName`, blank, or non-string) is FREE.
  """
  @spec bound?(block()) :: boolean()
  def bound?(%{"fieldName" => name}) when is_binary(name) and name != "", do: true
  def bound?(_block), do: false

  @doc """
  Partition a block list into `{bound, free}` preserving order within each side.

  A bound block carries a non-blank string `"fieldName"`; everything else is
  free. Order within each list mirrors the source order.
  """
  @spec partition([block()]) :: {[block()], [block()]}
  def partition(blocks) when is_list(blocks) do
    Enum.split_with(blocks, &bound?/1)
  end

  @doc """
  The classic value a bound block projects into `content[fieldName]`.

  For every field-block the editable datum is `block["value"]` and that is
  exactly the classic-field persistence shape (a string for
  string/slug/text/select/datetime/color/image/reference, a real boolean for
  field-boolean, a structured map/list for composite/arrayOf/localizedText, a
  scalar code for codelist). So projection is a verbatim copy of `"value"` —
  no transformation, no loss. A bound block with no `"value"` projects `nil`,
  which clears the index entry for that field.
  """
  @spec projected_value(block()) :: term()
  def projected_value(block) when is_map(block), do: Map.get(block, "value")

  @doc """
  Project a freshly-written block list into `content`, the SOLE writer of
  `content[fieldName]` (one per bound block) and `content["body"]` (all free
  blocks as `%{"blocks" => …, "html" => …}`).

  `content` is the document's current content map (so unrelated keys —
  `blocks`, `body_html`, `rev`, provenance — survive). `blocks` is the new
  block list. `render_opts` is forwarded to `Render.render_blocks/2` for the
  body HTML (pass `%{}` for a pure, Repo-free render).

  Returns the updated `content` map. Pure: no Repo, no mutation of inputs.
  """
  @spec project(content(), [block()], map()) :: content()
  def project(content, blocks, render_opts \\ %{})
      when is_map(content) and is_list(blocks) do
    {bound, free} = partition(blocks)

    content
    |> project_bound_fields(bound)
    |> Map.put("body", project_body(free, render_opts))
  end

  # Fold each bound block into content[fieldName] = projected value. Last writer
  # wins on a duplicated fieldName (two bound blocks for the same field — an
  # editor anomaly, not a normal shape); the later block in document order wins,
  # matching a single left-to-right walk.
  defp project_bound_fields(content, bound) do
    Enum.reduce(bound, content, fn block, acc ->
      Map.put(acc, block["fieldName"], projected_value(block))
    end)
  end

  @doc """
  Build the `content["body"]` value from the FREE block list:
  `%{"blocks" => free_blocks, "html" => Render.render_blocks(free_blocks, opts)}`.

  Exposed so the read/query path and synthesis can construct the same shape.
  """
  @spec project_body([block()], map()) :: %{String.t() => term()}
  def project_body(free_blocks, render_opts \\ %{}) when is_list(free_blocks) do
    %{
      "blocks" => free_blocks,
      "html" => Render.render_blocks(free_blocks, render_opts)
    }
  end
end
