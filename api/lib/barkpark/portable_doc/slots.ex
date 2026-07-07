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
  callout widget's own layout contract. The `card` widget (STEP 4) has its OWN
  flattening contract: it flattens its `body` slot to the legacy `bp-card__d` PLAIN
  text (marks dropped) — see `card_body_text/1` — so a card renders byte-identically
  to one legacy `cards` grid item.

  ## Wire decision

  For callout the body is losslessly inline-encodable, so THIS build keeps `content`
  as the persisted wire form and treats `slots` as an ADDITIVE, OPTIONAL key that is
  normalized to/from `content`. `normalize_widget/1` is idempotent and keeps
  `content` and `slots.body[0].content` in sync (dual-write) if `slots` is ever
  persisted. That is precisely why callout is the correct REFERENCE slot: it proves
  the slot MODEL (declaration + typed container + node-view slot editing + validate
  gate) WITHOUT forcing a cross-runtime wire change. The `card` widget (STEP 4) is the
  first genuinely SLOTS-NATIVE type — its media/title/body/action slots have no legacy
  inline encoding, so it persists a real `slots` key (no `content`/`slots` duality,
  `normalize_widget/1` passes it through untouched). The HTML reader lands here
  (`card_title_text/1` … `card_action/1` + `Components.card_html/1`); slot-aware
  `pdrender.go`/email renderers are a filed follow-up (the card degrades to the
  fallback renderer in the TUI/email until then).

  ## Layering

  Mirrors `Barkpark.PortableDoc.Constraints` style: no `Content`/DB dependency, plain
  block maps in, plain data / calm error strings out. Never raises on malformed input.

  The D1 slot gate keys off `tier/1`, which delegates FULLY to the one canonical
  classifier `Barkpark.PortableDoc.Tiers.tier_of/1` (with a fallback to `:element`
  for an unknown / type-less block).
  """

  @typedoc "The three structural tiers a block can occupy."
  @type tier :: :element | :widget | :section

  @typedoc "A widget's declaration of one typed slot."
  @type slot_decl :: %{
          name: String.t(),
          tier: tier(),
          count: Barkpark.PortableDoc.Constraints.count()
        }

  @typedoc """
  A widget's declaration of one SCALAR editable datum (an attr, not a slot child).
  `kind` is the datum's shape (`:query` map / `:string` / `:config` map); `required`
  is `:when_live` (required only when the widget is in its live/editable encoding),
  `true`, or `false`. The LIVE `task-list` widget declares these — its editable data
  are scalar attrs (query/title/config), NOT element-tier slot children, so it needs
  a PARALLEL declaration surface to `slot_decls/1` (figure/diagram/table are widgets
  with no `slot_decls` entry for the same reason).
  """
  @type query_field_decl :: %{
          name: String.t(),
          kind: :query | :string | :config,
          required: :when_live | boolean()
        }

  @doc """
  The structural tier of a block, for the D1 slot gate: `:widget` / `:section` /
  `:element`. Delegates FULLY to the one canonical classifier
  `Barkpark.PortableDoc.Tiers.tier_of/1` (which knows every renderable type,
  including `card` now that it is a real block); an unknown / type-less block falls
  back to `:element` (it carries no slots and is legal slot content, so legacy docs
  never gain a new error).
  """
  @spec tier(term()) :: tier()
  def tier(block), do: Barkpark.PortableDoc.Tiers.tier_of(block) || :element

  @doc """
  The slot declarations for a widget block.

    * Callout declares exactly one `body` slot of element tier, arity `{:exactly, 1}`.
    * Card (STEP 4) declares four element slots — `title` / `body` / `media` /
      `action` — each arity `{:max, 1}` (`media` / `action` OPTIONAL, so an
      absent slot is conforming). The D1 gate rejects a nested widget/section in
      any of them the moment this declaration exists.

  A non-widget block declares no slots.
  """
  @spec slot_decls(term()) :: [slot_decl()]
  def slot_decls(%{"type" => "callout"}),
    do: [%{name: "body", tier: :element, count: {:exactly, 1}}]

  def slot_decls(%{"type" => "card"}),
    do: [
      %{name: "title", tier: :element, count: {:max, 1}},
      %{name: "body", tier: :element, count: {:max, 1}},
      %{name: "media", tier: :element, count: {:max, 1}},
      %{name: "action", tier: :element, count: {:max, 1}}
    ]

  def slot_decls(_), do: []

  @doc """
  The SCALAR editable-data declarations for a widget block whose editable surface is
  attrs, not slot children. The LIVE `task-list` widget declares three:

    * `query` — kind `:query` (the filter map), `required: :when_live` (a task-list in
      its LIVE encoding must carry a query; a legacy snapshot-only task-list is the
      author-pinned encoding and declares nothing to require here).
    * `title` — kind `:string`, optional.
    * `config` — kind `:config` (a `%{limit, fields}` map), optional.

  This is the contract the canvas node-view (`task-list-node.js`) and the JS round-trip
  (`taskListBlockToNode`/`taskListNodeToBlock`) agree on. Every other block declares
  none (an empty list).
  """
  @spec query_decl(term()) :: [query_field_decl()]
  def query_decl(%{"type" => "task-list"}),
    do: [
      %{name: "query", kind: :query, required: :when_live},
      %{name: "title", kind: :string, required: false},
      %{name: "config", kind: :config, required: false}
    ]

  def query_decl(_), do: []

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

  # ── card widget accessors (STEP 4) ──────────────────────────────────────────
  #
  # Byte-identity accessors, the analogue of `callout_body_inline/1`. `Components.
  # card_html/1` reads through these so a card renders byte-identically to one legacy
  # `cards` grid item. The card FLATTENS: `title` → the heading element's plain
  # `text`, `body` → the paragraph element's inline FLATTENED to plain text (marks
  # dropped). `media` / `action` return the whole optional element (or nil).

  @doc """
  The title text of a card's `title` slot — the lone heading element's `text`, or
  `""` when the slot is absent/empty. Byte-aligns to the legacy `bp-card__t` string.
  """
  @spec card_title_text(term()) :: String.t()
  def card_title_text(block) do
    case slot_elements(block, "title") do
      [first | _] when is_map(first) -> first |> Map.get("text") |> to_text()
      _ -> ""
    end
  end

  @doc """
  The body text of a card's `body` slot — the lone paragraph element's inline content
  FLATTENED to CONCATENATED PLAIN TEXT (marks dropped), or `""` when absent/empty.
  This is the card widget's layout contract (the callout FLATTENS its body to inline;
  the card flattens its body to the legacy `bp-card__d` plain string), so escaping it
  DIRECTLY (not through `compose_inline_children`) yields byte-identity with a legacy
  cards item — inline marks authored in a card body round-trip in persistence but do
  NOT render (a deliberate STEP-4 tradeoff, byte-compat over rich body).
  """
  @spec card_body_text(term()) :: String.t()
  def card_body_text(block) do
    case slot_elements(block, "body") do
      [first | _] when is_map(first) -> first |> Map.get("content") |> flatten_inline_text()
      _ -> ""
    end
  end

  @doc "The lone element of a card's OPTIONAL `media` slot (an image element), or nil."
  @spec card_media(term()) :: map() | nil
  def card_media(block), do: first_slot_element(block, "media")

  @doc "The lone element of a card's OPTIONAL `action` slot (an action element), or nil."
  @spec card_action(term()) :: map() | nil
  def card_action(block), do: first_slot_element(block, "action")

  defp first_slot_element(block, name) do
    case slot_elements(block, name) do
      [first | _] when is_map(first) -> first
      _ -> nil
    end
  end

  defp to_text(s) when is_binary(s), do: s
  defp to_text(n) when is_integer(n), do: Integer.to_string(n)
  defp to_text(_), do: ""

  # Flatten a ProseMirror-style inline array to concatenated PLAIN text (marks
  # dropped): a text / inline-code leaf contributes its `value`; a mark node
  # (strong/em/link/…) contributes its children flattened; a bare string is itself.
  defp flatten_inline_text(list) when is_list(list),
    do: Enum.map_join(list, "", &flatten_inline_node/1)

  defp flatten_inline_text(s) when is_binary(s), do: s
  defp flatten_inline_text(_), do: ""

  defp flatten_inline_node(%{"type" => "text"} = n), do: to_text(Map.get(n, "value", ""))
  defp flatten_inline_node(%{"type" => "code"} = n), do: to_text(Map.get(n, "value", ""))

  defp flatten_inline_node(%{"children" => children}) when is_list(children),
    do: flatten_inline_text(children)

  defp flatten_inline_node(s) when is_binary(s), do: s
  defp flatten_inline_node(_), do: ""

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

  def normalize_widget(%{"type" => "task-list"} = block) do
    # A LIVE task-list persists its `query` map DIRECTLY (like `card`, it is genuinely
    # slots-free on the wire — no `content`/`slots` duality to reconcile). This clause
    # is idempotent + lossless: a map query is preserved EXACTLY (coerced to a plain
    # map when it is one — a no-op), and a snapshot-only author-pinned block (no query)
    # passes through UNTOUCHED. It NEVER adds a snapshot to a query block (nor a query
    # to a snapshot block), so the two encodings never co-exist. Persistence-side only
    # (NOT on the read/compose path — the reader byte-identity is via compose.ex:688).
    case Map.get(block, "query") do
      q when is_map(q) -> Map.put(block, "query", Map.new(q))
      _ -> block
    end
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

  @doc """
  The LIVE-DATA gate for the `task-list` widget's `query` datum — LEGACY-SAFE. Returns
  `[]` for:

    * a snapshot-only / author-pinned task-list (NO `query` key) — the legacy encoding
      is valid, so no existing paper ever gains an error; AND
    * a well-formed LIVE task-list (`query` is a map).

  Returns a single calm error ONLY when a `query` key IS present but is NOT a map (a
  malformed live query). It NEVER requires a query unconditionally — that would red
  every legacy block. This is "the query is a real, validated editable datum" WITHOUT
  breaking author-pinned rows. Every non-task-list block yields `[]`. Never raises.
  """
  @spec query_type_errors(term()) :: [String.t()]
  def query_type_errors(%{"type" => "task-list"} = block) do
    case Map.fetch(block, "query") do
      :error ->
        []

      {:ok, q} when is_map(q) ->
        []

      {:ok, _} ->
        [
          ~s|the "task-list" query must be a map (a filter like %{"label" => "proj:x"}), got a non-map value|
        ]
    end
  end

  def query_type_errors(_), do: []
end
