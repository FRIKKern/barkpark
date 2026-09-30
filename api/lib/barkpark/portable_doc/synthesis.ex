defmodule Barkpark.PortableDoc.Synthesis do
  @moduledoc """
  Lazy in-memory synthesis of a block list for a LEGACY document that has no
  `content["blocks"]` yet (Exp-P2, barkpark-emxg, step 2.5).

  On the first Beta-open of such a document, the paper surface needs a block list to
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
  #
  # v1 leaf types map to a `field-*` block; the four v2 nested types
  # (composite / arrayOf / codelist / localizedText) use a block type EQUAL to
  # the field type itself (the identity mapping — see `Render.compose_block/1`,
  # which has `%{"type" => "composite"}` etc. clauses, no `field-` prefix).
  @field_block_types %{
    "string" => "field-string",
    "slug" => "field-slug",
    "text" => "field-text",
    "richText" => "field-text",
    "number" => "field-number",
    "boolean" => "field-boolean",
    "datetime" => "field-datetime",
    "color" => "field-color",
    "select" => "field-select",
    "reference" => "field-reference",
    "image" => "field-image",
    "composite" => "composite",
    "arrayOf" => "arrayOf",
    "codelist" => "codelist",
    "localizedText" => "localizedText",
    # v1 Sanity-style containers (task-cd9aefaf2f6068d6): an `array` rides the
    # v2 arrayOf editor and an `object` the composite editor, with their element
    # shape translated in v1_config/1. Falling back to field-string painted
    # ["a","b"] as the text "ab" and let one keystroke write a string over a list.
    "array" => "arrayOf",
    "object" => "composite"
  }

  @default_field_block_type "field-string"

  @doc """
  The block type a bound block carries for a given schema field TYPE.

  v1 leaf types map to a `field-*` block (e.g. `"string"` → `"field-string"`,
  `"image"` → `"field-image"`); the four v2 nested types use the identity
  mapping (`"composite"` → `"composite"`, matching `Render.compose_block/1`).
  Unknown / `nil` types fall back to `#{@default_field_block_type}` — the value
  still round-trips through projection verbatim.

  This is the single source of truth for the schema-type → block-type mapping,
  shared by `synthesize/3`, `scaffold/4`, and
  `Content.available_expected_fields/2` (the Expectation-aware slash menu).
  """
  @spec field_block_type(String.t() | nil) :: String.t()
  def field_block_type(field_type),
    do: Map.get(@field_block_types, field_type, @default_field_block_type)

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
    field_by_name = field_index(fields)

    layout
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      case entry do
        %{"kind" => "field", "name" => name} ->
          synth_field_block(name, content, field_by_name, idx)

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
  defp synth_field_block(name, content, field_by_name, idx) do
    case Map.fetch(content, name) do
      {:ok, value} ->
        field = Map.get(field_by_name, name, %{})

        case bound_block_shape(field, value) do
          {:ok, block_type, config} ->
            [
              Map.merge(
                %{
                  "id" => synth_id("f", name, idx),
                  "type" => block_type,
                  "fieldName" => name,
                  "value" => value
                },
                config
              )
            ]

          # A v1 container whose shape no field-block can show truthfully (a
          # mixed-type array, a non-string list, a value of the wrong kind) is
          # left OUT of the block list: the stored value stays untouched and is
          # never painted as a mangled string or overwritten through a wrong editor.
          :unrepresentable ->
            []
        end

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

  defp field_index(fields) do
    Enum.reduce(fields, %{}, fn f, acc ->
      name = f["name"] || f[:name]
      if is_binary(name), do: Map.put(acc, name, f), else: acc
    end)
  end

  # Schema fields arrive string-keyed from plugin JSON / DB rows but may be
  # atom-keyed from in-memory builders — mirror the dual access the name/type
  # index always used. The atom fallback is guarded: a key with no existing
  # atom (e.g. "codelistId" in a release that never declared it) is just nil.
  defp fget(f, key), do: Map.get(f, key) || Map.get(f, safe_atom(key))

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # The four v2 nested block types render through `PaperFieldBlock`, whose
  # `build_field/1` reads the structural config OFF THE BLOCK ("of" /
  # "fields" / "codelistId" / "languages"…). A bound block synthesized
  # without that config loses the element shape: an arrayOf-of-composite
  # degrades to string rows and ArrayField's `leaf_input` crashes the
  # LiveView calling `to_string/1` on the row maps (first hit: the task
  # schema's `acceptance_criteria` in the Beta editor). Carry the schema
  # field's structural keys (+ a human label) onto the block verbatim.
  # v1 `field-*` blocks are untouched — empty merge.
  defp v2_block_config("composite", f) do
    %{"label" => block_label(f), "fields" => fget(f, "fields") || []}
  end

  defp v2_block_config("arrayOf", f) do
    %{
      "label" => block_label(f),
      "of" => fget(f, "of") || %{"type" => "string"},
      "ordered" => fget(f, "ordered") == true
    }
  end

  defp v2_block_config("codelist", f) do
    %{
      "label" => block_label(f),
      "codelistId" => fget(f, "codelistId"),
      "version" => fget(f, "version")
    }
  end

  defp v2_block_config("localizedText", f) do
    %{
      "label" => block_label(f),
      "languages" => fget(f, "languages") || [],
      "format" => fget(f, "format") || "plain",
      "fallbackChain" => fget(f, "fallbackChain") || []
    }
  end

  defp v2_block_config(_block_type, _f), do: %{}

  defp block_label(f), do: fget(f, "title") || fget(f, "name") || ""

  # {:ok, block_type, config} for the bound block a field + value becomes, or
  # :unrepresentable for a v1 container no field-block shows truthfully.
  defp bound_block_shape(field, value) do
    type = fget(field, "type")
    block_type = field_block_type(type)

    case type do
      "array" ->
        with {:ok, of} <- v1_element(fget(field, "of")),
             true <- v1_list_fits?(of, value) do
          {:ok, block_type,
           %{
             "label" => block_label(field),
             "of" => of,
             "ordered" => fget(field, "ordered") == true
           }}
        else
          _ -> :unrepresentable
        end

      "object" ->
        with {:ok, subfields} <- v1_fields(fget(field, "fields")),
             true <- is_map(value) do
          {:ok, block_type, %{"label" => block_label(field), "fields" => subfields}}
        else
          _ -> :unrepresentable
        end

      _ ->
        {:ok, block_type, v2_block_config(block_type, field)}
    end
  end

  # Element types an arrayOf row edits as text without changing the stored type.
  @v1_text_elements ~w(string text slug url email)

  # A v1 `of` is a LIST of allowed member types (Sanity style). Exactly one
  # text-like or object member translates to the v2 element descriptor; a
  # mixed list or any other member type has no truthful editor.
  defp v1_element([member]) when is_map(member), do: v1_element(member)

  defp v1_element(member) when is_map(member) do
    case Map.get(member, "type") || Map.get(member, :type) do
      t when t in @v1_text_elements ->
        {:ok, %{"type" => "string"}}

      "object" ->
        with {:ok, fields} <- v1_fields(Map.get(member, "fields") || Map.get(member, :fields)) do
          {:ok, %{"type" => "composite", "fields" => fields}}
        end

      _ ->
        :error
    end
  end

  defp v1_element(_), do: :error

  # A v1 object's subfields as composite subfields: text-like leaves only (a
  # nested container has no truthful leaf input here).
  defp v1_fields([_ | _] = fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn f, {:ok, acc} ->
      name = is_map(f) && (Map.get(f, "name") || Map.get(f, :name))
      type = is_map(f) && (Map.get(f, "type") || Map.get(f, :type))

      if is_binary(name) and type in @v1_text_elements do
        title = Map.get(f, "title") || Map.get(f, :title) || name
        {:cont, {:ok, acc ++ [%{"name" => name, "title" => title, "type" => "string"}]}}
      else
        {:halt, :error}
      end
    end)
  end

  defp v1_fields(_), do: :error

  # The stored list must already be the element shape the editor writes back.
  defp v1_list_fits?(%{"type" => "string"}, value) when is_list(value),
    do: Enum.all?(value, &is_binary/1)

  defp v1_list_fits?(%{"type" => "composite"}, value) when is_list(value),
    do: Enum.all?(value, &is_map/1)

  defp v1_list_fits?(_of, _value), do: false

  # Deterministic, collision-free synthetic ids so a re-synthesis of the same
  # doc yields identical block ids (idempotent in-memory open).
  defp synth_id(prefix, name, idx), do: "synth-#{prefix}-#{name}-#{idx}"

  # ── Exp-P3.1 — Create-from-Expectation scaffold ──────────────────────────
  #
  # `scaffold/3` is `synthesize/3`'s create-time sibling. Where synthesis
  # reproduces blocks for a LEGACY doc that already has values (skipping fields
  # with no stored value), scaffold INSTANTIATES the Expectation for a BRAND-NEW
  # document: ONE bound field-block per `field` layout entry (always present,
  # even with an empty value), valued from `values` (provided content / row
  # title) → `prefill` → empty, plus the body region's free blocks (a single
  # empty paragraph placeholder when the new doc carries no body).
  #
  # The result feeds `Projection.project/3` so `content[fieldName]` +
  # `content["body"]` are derived from the same blocks that were just built.
  # Pure: no Repo, no mutation of inputs.

  @doc """
  Build the initial block list for a new Expectation-bearing document.

  Arguments mirror `synthesize/3`:

    * `layout`  — the schema's resolved Expectation layout (Exp-P1).
    * `values`  — a string-keyed map of any caller-provided field values for the
      new doc (the create attrs' `content` merged with the row `title` under
      `"title"`). Wins over `prefill`.
    * `prefill` — the schema's resolved Expectation `prefill` scaffold (Exp-P1):
      the create-time floor for field values.
    * `fields`  — the schema's `fields` list, for picking the `field-*` block
      type per bound field.

  Returns an ordered block list: one BOUND field-block per `field` entry (in
  layout order, always emitted), with the body region's free blocks at the
  `region` marker. Field value priority: `values[name]` → `prefill[name]` →
  `""` (empty). A field-boolean with no value defaults to `false`.
  """
  @spec scaffold([map()], map(), map(), [map()]) :: [block()]
  def scaffold(layout, values, prefill, fields)
      when is_list(layout) and is_map(values) and is_map(prefill) and is_list(fields) do
    field_by_name = field_index(fields)

    layout
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      case entry do
        %{"kind" => "field", "name" => name} ->
          scaffold_field_block(name, values, prefill, field_by_name, idx)

        %{"kind" => "region", "name" => region} ->
          scaffold_body_blocks(Map.get(values, region), idx)

        _ ->
          []
      end
    end)
  end

  # One bound field-block per field layout entry, ALWAYS emitted (unlike
  # synthesis, which skips value-less fields). The value is resolved from the
  # provided values, then prefill, then an empty default by block type.
  # Carries the same v2 structural config as synthesis — a scaffolded
  # arrayOf/composite block must know its element shape too.
  defp scaffold_field_block(name, values, prefill, field_by_name, idx) do
    field = Map.get(field_by_name, name, %{})
    block_type = field_block_type(fget(field, "type"))
    value = scaffold_value(name, values, prefill, block_type, fget(field, "type"))

    case bound_block_shape(field, value) do
      {:ok, block_type, config} ->
        [
          Map.merge(
            %{
              "id" => synth_id("f", name, idx),
              "type" => block_type,
              "fieldName" => name,
              "value" => value
            },
            config
          )
        ]

      :unrepresentable ->
        []
    end
  end

  defp scaffold_value(name, values, prefill, block_type, field_type) do
    cond do
      Map.has_key?(values, name) -> Map.get(values, name)
      Map.has_key?(prefill, name) -> Map.get(prefill, name)
      block_type == "field-boolean" -> false
      field_type == "array" -> []
      field_type == "object" -> %{}
      true -> ""
    end
  end

  # The body region for a brand-new doc. An already-projected body map → reuse
  # its blocks (a create that carried an explicit body). A non-empty string →
  # one paragraph free-block. Empty/absent → a single EMPTY paragraph
  # placeholder so the block editor opens with a writable body region.
  defp scaffold_body_blocks(%{"blocks" => blocks}, _idx) when is_list(blocks), do: blocks

  defp scaffold_body_blocks(text, idx) when is_binary(text) and text != "" do
    [
      %{
        "id" => synth_id("body", "p", idx),
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    ]
  end

  defp scaffold_body_blocks(_other, idx) do
    [%{"id" => synth_id("body", "p", idx), "type" => "paragraph", "content" => []}]
  end

  # ── Exp-P3.2 — Classic-save bound-only patch (the data-loss guard) ────────

  @doc """
  Patch ONLY the bound-block values in `blocks` from a `field => value` map,
  leaving every FREE block and the overall block ORDER byte-identical.

  This is the Classic-save reroute for a block-bearing document (Exp-P3.2): the
  submitted Classic form is a flat field map, but the document's source of truth
  is its block list. Rather than overwrite `content` from the field map (which
  would drop free blocks and `content["blocks"]` entirely — the data-loss bug),
  the caller maps each submitted field to the matching bound block and patches
  just that block's `"value"`. A field with no matching bound block is ignored
  (Classic baseline keys like `"status"` are not bound). A bound block whose
  field is absent from `values` is left untouched.

  Returns the new block list — same length, same order, free blocks `===` the
  originals. Pure: no Repo, no mutation of inputs.
  """
  @spec patch_bound_values([block()], map()) :: [block()]
  def patch_bound_values(blocks, values) when is_list(blocks) and is_map(values) do
    Enum.map(blocks, fn block ->
      name = block["fieldName"]

      if is_binary(name) and name != "" and Map.has_key?(values, name) do
        Map.put(block, "value", Map.get(values, name))
      else
        block
      end
    end)
  end
end
