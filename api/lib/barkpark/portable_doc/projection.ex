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
      `content["body"]`, whose owned `"blocks"` and `"html"` keys are refreshed
      while any other keys in an existing body map are preserved.

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
    * all free blocks  → `content["body"]["blocks" | "html"]` are refreshed;
      unowned keys in an existing body map survive

  Nothing else may write those keys — that is the no-drift guarantee. The walk
  is folded into the write path in `Content.apply_paper_block_op/3` and
  `Content.upsert_paper/1`, so any op or whole-doc write re-derives the index
  from the blocks it just persisted.

  Pure: `project/3` performs no Repo access and never mutates its input — it
  returns a new `content` map. HTML rendering is delegated to
  `Barkpark.PortableDoc.Render.render_blocks/2`; the caller supplies the same
  `render_opts` it already builds for `body_html`.
  """

  alias Barkpark.Preview
  alias Barkpark.PortableDoc.{FromMarkdown, Render}

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
  Read the canonical block list from a Portable Doc content map.

  A present top-level `"blocks"` list remains authoritative, including an
  intentionally empty list. Historical projected documents that only retain
  the free-block projection under `content["body"]["blocks"]` fall back to that
  nested list. Any other shape has no readable block list.
  """
  @spec read_blocks(map()) :: [block()] | nil
  def read_blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks

  def read_blocks(%{"body" => %{"blocks" => blocks}}) when is_list(blocks), do: blocks

  def read_blocks(%{"body" => blocks}) when is_list(blocks), do: blocks

  def read_blocks(%{"body" => markdown}) when is_binary(markdown) do
    if String.trim(markdown) == "", do: nil, else: FromMarkdown.blocks(markdown)
  end

  def read_blocks(_content), do: nil

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
  blocks as the owned `%{"blocks" => …, "html" => …}` keys). Existing unowned
  keys in a body map are preserved; scalar and list body representations are
  replaced by the canonical projected map.

  `content` is the document's current content map (so unrelated keys —
  `blocks`, `body_html`, `rev`, provenance — survive). `blocks` is the new
  block list. `render_opts` is forwarded to `Render.render_blocks/2` for the
  body HTML (pass `%{}` for a pure, Repo-free render).

  Returns the updated `content` map. Pure: no Repo, no mutation of inputs.
  """
  @spec project(content(), [block()], map()) :: content()
  def project(content, blocks, render_opts \\ %{})
      when is_map(content) and is_list(blocks) do
    # Shim: no separate OLD block list (fresh-doc seeders / whole-content
    # replacements, AND the project/2 callers in tests — projection_test,
    # content_projection_test, content_classic_save_guard_test — which keep
    # resolving ONLY because this default-arg head stays). prior == current ⇒
    # dropped == [] ⇒ byte-identical to the pre-delta behaviour. Real write-path
    # callers that flip a block bound→free call project/4 with their pre-patch
    # block list.
    project(content, blocks, blocks, render_opts)
  end

  @doc """
  Project a freshly-written block list, clearing the orphan index entries of any
  field that was BOUND in `old_blocks` but is no longer bound in `blocks`.

  `old_blocks` is the PRE-patch block list. The dropped set is
  `prior_bound_field_names -- current_bound_field_names` — exactly the unbind
  orphans (and the old name of a rename). It MUST be threaded in: at every
  write-path caller `content["blocks"]` is already the NEW list by project-time,
  and `content[fieldName]` is indistinguishable from a Classic field key, so the
  dropped set is unrecoverable from `content` alone.

  Byte-identical to the legacy behaviour whenever the bound set is unchanged
  and the existing body has no unowned map keys. Projection owns and replaces
  body `"blocks"`/`"html"`; every other existing body-map key survives. Pure:
  map operations only.
  """
  @spec project(content(), [block()], [block()], map()) :: content()
  def project(content, old_blocks, blocks, render_opts)
      when is_map(content) and is_list(old_blocks) and is_list(blocks) and is_map(render_opts) do
    {bound, free} = partition(blocks)
    prior = for b <- old_blocks, bound?(b), do: b["fieldName"]

    projected_body = project_body(free, render_opts)

    body =
      case Map.get(content, "body") do
        existing when is_map(existing) -> Map.merge(existing, projected_body)
        _ -> projected_body
      end

    projected =
      content
      |> project_bound_fields(prior, bound)
      |> Map.put("body", body)

    # Project-on-write, part two: derive content["preview"] — the OpenGraph-shaped
    # per-document card — from the SAME block walk, right beside content["body"],
    # so its coverage + no-drift profile are identical to body's. Pure: the ONE
    # media lookup a rich image needs is an injected closure in
    # `render_opts[:preview]` (callers that hold Repo + scope build it via
    # `Barkpark.Preview.media_resolver/1`). GATED on that key: projection callers
    # that don't opt in (sheets/forms/proposals scaffolds, doctrine backfill)
    # must NOT stamp — a resolver-less re-save would overwrite a rich card AND
    # shadow the reader's read-time fallback, which only recomputes when
    # content["preview"] is absent. `Render.render_blocks/2` ignores the key.
    case Map.get(render_opts, :preview) do
      opts when is_map(opts) ->
        Map.put(projected, "preview", Preview.project(projected, blocks, opts))

      _ ->
        projected
    end
  end

  # Drop the field names that were bound in the prior block list but are no
  # longer bound (unbind orphans / the old name of a rename), THEN fold each
  # now-bound block into content[fieldName] = projected value. Last writer wins
  # on a duplicated fieldName (two bound blocks for the same field — an editor
  # anomaly, not a normal shape); the later block in document order wins,
  # matching a single left-to-right walk. `dropped == []` for any non-unbind
  # write ⇒ Map.drop([]) is a no-op ⇒ byte-identical output.
  defp project_bound_fields(content, prior_field_names, bound) do
    dropped = prior_field_names -- Enum.map(bound, & &1["fieldName"])

    content
    |> Map.drop(dropped)
    |> then(fn acc0 ->
      Enum.reduce(bound, acc0, fn block, acc ->
        Map.put(acc, block["fieldName"], projected_value(block))
      end)
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
