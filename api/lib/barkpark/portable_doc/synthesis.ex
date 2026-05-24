defmodule Barkpark.PortableDoc.Synthesis do
  @moduledoc """
  Lazy in-memory synthesis of a block list for a LEGACY document that has no
  `content["blocks"]` yet (Exp-P2, barkpark-emxg, step 2.5).

  On the first Beta-open of such a document, paperflow needs a block list to
  drive the bound/free editor — but nothing should be PERSISTED until the user
  makes the first edit. `synthesize/3` builds that block list purely in memory
  from:

    1. the schema's resolved Expectation `layout` (Exp-P1), which orders the
       fields and marks the trailing `body` region, and
    2. the document's existing `content[fieldName]` values + the row `title`,
       which fill the bound field-blocks, and
    3. the document's existing body — see "How legacy posts store body" below.

  ## How legacy posts store body

  In Barkpark's classic model a post's prose lives under `content["body"]` as a
  `richText` value (a v1 leaf — see `SchemaDefinition.parse_field_type/3`). In
  practice that value is a plain string (the classic Studio editor's
  `build_content/2` stores the form param verbatim) — most seeded posts have no
  body at all. So synthesis reproduces the body region as:

    * already a projected body map `%{"blocks" => [...], ...}` → reuse its
      blocks verbatim (a doc previously projected by `Projection.project/3`);
    * a non-empty string → one `paragraph` free-block carrying that text;
    * empty / absent → an empty body region (no free blocks).

  ## The no-rewrite invariant

  Synthesis must NOT change content. The round-trip
  `synthesize → Projection.project` must yield bound `content[fieldName]` values
  byte-equal to the originals and a body whose text is preserved. The caller
  persists the synthesized blocks ONLY when the first op lands — until then the
  stored row is untouched.

  Pure: no Repo access, no mutation of inputs. The schema's layout is resolved
  by the caller (via `Content.resolve_expectation/1`) and passed in.
  """

  @type block :: %{required(String.t()) => term()}

  # Map each top-level field's declared schema type → the field-block type a
  # bound block should carry. Falls back to field-string for unknown/typeless
  # fields (still round-trips: value is copied verbatim).
  @field_block_types %{
    "string" => "field-string",
    "slug" => "field-slug",
    "text" => "field-text",
    "richText" => "field-text",
    "boolean" => "field-boolean",
    "datetime" => "field-datetime",
    "color" => "field-color",
    "select" => "field-select",
    "reference" => "field-reference",
    "image" => "field-image"
  }

  @doc """
  Synthesize an in-memory block list for a legacy document.

  Arguments:

    * `layout`  — the schema's resolved Expectation layout (a list of
      `%{"kind" => "field"|"region", "name" => …}` maps; see Exp-P1).
    * `content` — the document's stored `content` map (string-keyed). The row
      `title` is folded in by the caller via `content["title"]` when the schema
      lists a `title` field (post does); see `Content` synthesis wrapper.
    * `fields`  — the schema's `fields` list (each `%{"name", "type", …}`),
      used to pick the right `field-*` block type per bound field.

  Returns an ordered block list: one bound field-block per `field` layout entry
  whose value exists in `content`, then the body region's free blocks at the
  `region` marker position.
  """
  @spec synthesize([map()], map(), [map()]) :: [block()]
  def synthesize(layout, content, fields)
      when is_list(layout) and is_map(content) and is_list(fields) do
    type_by_name = field_type_index(fields)

    layout
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      case entry do
        %{"kind" => "field", "name" => name} ->
          synth_field_block(name, content, type_by_name, idx)

        %{"kind" => "region", "name" => region} ->
          synth_body_blocks(Map.get(content, region), idx)

        _ ->
          []
      end
    end)
  end

  # One bound field-block for a layout field entry, IF the doc has a value for
  # it. A field with no stored value is skipped (synthesizing an empty bound
  # block would project an empty value back, which is a no-op, but skipping
  # keeps the synthesized list minimal and the round-trip exact: a field that
  # was absent stays absent after project, never written as nil/"").
  defp synth_field_block(name, content, type_by_name, idx) do
    case Map.fetch(content, name) do
      {:ok, value} ->
        block_type = Map.get(@field_block_types, Map.get(type_by_name, name), "field-string")

        [
          %{
            "id" => synth_id("f", name, idx),
            "type" => block_type,
            "fieldName" => name,
            "value" => value
          }
        ]

      :error ->
        []
    end
  end

  # The body region's free blocks, reproduced from however the legacy doc stored
  # its prose. See moduledoc "How legacy posts store body".
  defp synth_body_blocks(%{"blocks" => blocks}, _idx) when is_list(blocks), do: blocks

  defp synth_body_blocks(text, idx) when is_binary(text) and text != "" do
    [
      %{
        "id" => synth_id("body", "p", idx),
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    ]
  end

  defp synth_body_blocks(_other, _idx), do: []

  defp field_type_index(fields) do
    Enum.reduce(fields, %{}, fn f, acc ->
      name = f["name"] || f[:name]
      type = f["type"] || f[:type]
      if is_binary(name), do: Map.put(acc, name, type), else: acc
    end)
  end

  # Deterministic, collision-free synthetic ids so a re-synthesis of the same
  # doc yields identical block ids (idempotent in-memory open).
  defp synth_id(prefix, name, idx), do: "synth-#{prefix}-#{name}-#{idx}"
end
