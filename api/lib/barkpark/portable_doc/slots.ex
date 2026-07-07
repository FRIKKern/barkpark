defmodule Barkpark.PortableDoc.Slots do
  @moduledoc """
  The PortableDoc **slot vocabulary** — a pure, DOM-free, Content-free reader for a
  WIDGET block's typed slots (paper `portabledoc-doctrine`, STEP 3; charter D1).

  ## The slot model

  A **widget** declares one or more typed **slots**. A slot is a NAMED,
  arity-bounded list of **element-tier** blocks (charter D1 — slots accept ELEMENTS
  ONLY; never widgets, never sections; recursion stays a section-tier concern). The
  canonical persisted shape when a widget is *materialized* to slots is:

      %{"type" => "callout", "tone" => _, "title"? => _, "collapsible"? => _,
        "collapsed"? => _, "slots" => %{"body" => [<element>, …]}}

  **Callout** is the arity-1, single-slot reference instance: it declares exactly one
  slot, `%{name: "body", tier: :element, count: {:exactly, 1}}`.

  ## Backward-compat default (the crux)

  The legacy callout `%{"type" => "callout", "content" => [<inline>…]}` IS the compat
  encoding of a `body` slot holding ONE implicit `paragraph` element whose `content`
  is that inline array. `slot_elements/2` synthesizes that paragraph when no `slots`
  key is present, so a legacy doc reads through the slot API unchanged.

  The load-bearing invariant that makes byte-identity PROVABLE is
  `callout_body_inline/1` — the inline array of the single body element (from the
  slot's lone paragraph, or from legacy `content`). Both encodings yield the SAME
  inline array ⟹ `Render.Compose` emits the SAME single `PdText` ⟹ identical
  reader / TUI / email bytes. The callout widget FLATTENS its single-paragraph body
  slot to INLINE — it never composes the body element as a block `<p>` (that would add
  a wrapper + a 12pt margin and break parity). "Render the body slot inline" is the
  callout widget's own layout contract, distinct from a future `card` widget that
  stacks its body slot as real blocks.

  ## Wire decision

  For callout the body is losslessly inline-encodable, so THIS build keeps `content`
  as the persisted wire form and treats `slots` as an ADDITIVE, OPTIONAL key that is
  normalized to/from `content`. `normalize_widget/1` is idempotent and keeps
  `content` and `slots.body[0].content` in sync (dual-write) if `slots` is ever
  persisted. That is precisely why callout is the correct REFERENCE slot: it proves
  the slot MODEL (declaration + typed container + node-view slot editing + validate
  gate) WITHOUT forcing a cross-runtime wire change. A future `card` widget — whose
  media/title/body/action slots have no legacy inline encoding — is where a genuinely
  new persisted `slots` key + slot-aware `pdrender.go`/email renderers land; the model
  shape is identical, callout is its arity-1 single-slot instance.

  ## Layering

  Mirrors `Barkpark.PortableDoc.Constraints` style: no `Content`/DB dependency, plain
  block maps in, plain data / calm error strings out. Never raises on malformed input.

  Until `Barkpark.PortableDoc.Tiers` lands (STEP 1/2), this module carries a MINIMAL
  element|widget|section classifier (`tier/1`) that the D1 gate reuses. When Tiers
  lands, `tier/1` should delegate to it.
  """

  @typedoc "The three structural tiers a block can occupy."
  @type tier :: :element | :widget | :section

  @typedoc "A widget's declaration of one typed slot."
  @type slot_decl :: %{
          name: String.t(),
          tier: tier(),
          count: Barkpark.PortableDoc.Constraints.count()
        }

  # Minimal tier classifier (Tiers not yet landed — see @moduledoc). WIDGETS declare
  # slots; SECTIONS recurse; everything else is an ELEMENT (the slot-legal tier).
  # `card` is listed ahead of its implementation so the D1 gate already rejects a
  # nested card the day that widget lands.
  @widget_types ~w(callout card)
  @section_types ~w(section)

  @doc """
  The structural tier of a block: `:widget` (declares slots), `:section` (recurses),
  else `:element`. A non-map or type-less block classifies as `:element` (it carries
  no slots and is legal slot content), so legacy docs never gain a new error.
  """
  @spec tier(term()) :: tier()
  def tier(block) do
    case type_of(block) do
      t when t in @widget_types -> :widget
      t when t in @section_types -> :section
      _ -> :element
    end
  end

  @doc """
  The slot declarations for a widget block. Callout declares exactly one `body` slot
  of element tier and arity `{:exactly, 1}`. A non-widget block declares no slots.
  """
  @spec slot_decls(term()) :: [slot_decl()]
  def slot_decls(%{"type" => "callout"}),
    do: [%{name: "body", tier: :element, count: {:exactly, 1}}]

  def slot_decls(_), do: []

  @doc """
  The element-tier children of the named slot. Returns `block["slots"][name]` when a
  `slots` map carries it, else the legacy synthesis: for a callout `body` slot, a
  single implicit `paragraph` element wrapping the legacy `content` inline array.
  Unknown slots (and non-callout blocks) synthesize `[]`.
  """
  @spec slot_elements(term(), String.t()) :: [map()]
  def slot_elements(block, name) do
    case block do
      %{"slots" => %{^name => list}} when is_list(list) -> list
      _ -> legacy_slot(block, name)
    end
  end

  # The legacy fallback: a callout's `body` slot is its `content` wrapped as ONE
  # implicit paragraph. Any other slot synthesizes empty (defensive).
  defp legacy_slot(%{"type" => "callout"} = block, "body"),
    do: [%{"type" => "paragraph", "content" => Map.get(block, "content") || []}]

  defp legacy_slot(_block, _name), do: []

  @doc """
  The inline array of a callout's single body element — from the slot's lone
  paragraph when materialized, or from legacy `content`. THE load-bearing invariant:
  both encodings of the same body yield the SAME inline array, so `Render.Compose`
  emits a byte-identical `PdText`. Always a list (nil-safe).
  """
  @spec callout_body_inline(term()) :: [map()]
  def callout_body_inline(block) do
    case slot_elements(block, "body") do
      [first | _] when is_map(first) -> Map.get(first, "content") || []
      _ -> []
    end
  end

  @doc """
  Normalize a widget block to its canonical dual form, keeping `content` and
  `slots.body[0].content` in sync (dual-write). Idempotent
  (`normalize_widget(normalize_widget(x)) == normalize_widget(x)`) and lossless in
  both directions (a content-form and a slot-form callout with the same body
  normalize to the identical map).

  Empty-body fidelity: when the body inline array is empty, BOTH keys are omitted —
  the callout precedent (`compose` maybe_put drops an empty body). A non-widget block
  passes through untouched.

  NOTE: this is a persistence-side utility. It is NOT on the read/compose path —
  existing papers keep their `content` bytes on disk untouched (no forced backfill);
  the reader synthesizes the body slot from `content` via `slot_elements/2`.
  """
  @spec normalize_widget(term()) :: term()
  def normalize_widget(%{"type" => "callout"} = block) do
    inline = callout_body_inline(block)

    block
    |> Map.delete("content")
    |> Map.delete("slots")
    |> put_callout_body(inline)
  end

  def normalize_widget(block), do: block

  # Empty body: omit both keys (precedent). Non-empty: dual-write content + slots.
  defp put_callout_body(block, []), do: block

  defp put_callout_body(block, inline) do
    block
    |> Map.put("content", inline)
    |> Map.put("slots", %{"body" => [%{"type" => "paragraph", "content" => inline}]})
  end

  @doc """
  The D1 gate: every slot child of a widget must classify as tier `:element`. Returns
  `[]` for a conforming (or non-widget) block, else calm, specific error strings.

  A legacy callout (body synthesized from `content`) yields `[]` — its implicit
  paragraph is an element. A callout whose `body` slot holds a nested widget (e.g. a
  callout) or a section yields a non-empty list. Never raises.
  """
  @spec slot_type_errors(term()) :: [String.t()]
  def slot_type_errors(block) do
    block
    |> slot_decls()
    |> Enum.flat_map(fn %{name: name} ->
      block
      |> slot_elements(name)
      |> Enum.flat_map(&child_tier_error(&1, name))
    end)
  end

  defp child_tier_error(child, slot_name) do
    case tier(child) do
      :element ->
        []

      other ->
        [
          ~s|the "#{slot_name}" slot accepts only element blocks, | <>
            ~s|got a #{other} ("#{type_of(child) || "?"}")|
        ]
    end
  end

  defp type_of(%{"type" => t}) when is_binary(t) and t != "", do: t
  defp type_of(_), do: nil
end
