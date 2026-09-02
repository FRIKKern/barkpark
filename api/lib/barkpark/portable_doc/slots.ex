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

  # Note (the notes-grid split) declares THREE element slots — `label` /
  # `lead` / `body` — mirroring the three fields of ONE legacy `notes` item.
  # `label` and `body` are REQUIRED ({:exactly, 1}); `lead` is OPTIONAL
  # ({:max, 1}, the arity twin of "at most one") so an absent lead is
  # conforming. The D1 gate rejects a nested widget/section in any of them.
  def slot_decls(%{"type" => "note"}),
    do: [
      %{name: "label", tier: :element, count: {:exactly, 1}},
      %{name: "lead", tier: :element, count: {:max, 1}},
      %{name: "body", tier: :element, count: {:exactly, 1}}
    ]

  # Stage — the editable per-node twin of ONE legacy `pipeline` node. THREE PLAIN-TEXT
  # element slots (the `title` is the required one, arity {:exactly, 1}); `files` and
  # `source` stay WIDGET chrome (like callout `title`/`collapsible`), NOT slots — that
  # keeps the slot count at three and preserves the byte-fidelity of the pnode cell.
  def slot_decls(%{"type" => "stage"}),
    do: [
      %{name: "kind", tier: :element, count: {:max, 1}},
      %{name: "title", tier: :element, count: {:exactly, 1}},
      %{name: "detail", tier: :element, count: {:max, 1}}
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

  @typedoc """
  A block type's **consumed-field vocabulary** — the keys its renderer actually
  reads. `consumed` are the content-bearing keys (their emptiness means the
  block renders no prose); `chrome` are presentational keys the renderer also
  honors. A key OUTSIDE `consumed ++ chrome ++` the structural set is UNKNOWN to
  the renderer — authored prose placed there is silently dropped behind an
  HTTP 200. This is the THIRD parallel declaration surface (after `slot_decls/1`
  and `query_decl/1`); its checker is `lossy_shape?/1`.
  """
  @type field_vocab :: %{consumed: [String.t()], chrome: [String.t()]}

  # Keys that are STRUCTURE on any block, never a content field.
  @vocab_structural_keys ~w(id type role locked style level lang language)

  @doc """
  The consumed-field vocabulary for a block type whose renderer reads a FIXED,
  known key set — the surface the silent-content-loss gate (`lossy_shape?/1`)
  keys off. The types whose renderer returns an EMPTY string (not a visible
  "no data" placeholder) when their content key is absent declare one, so
  authored prose stranded under an unread key is caught at write time:

    * `note` consumes `label` / `lead` / `text` (the flat legacy fields) plus
      `slots` (the materialized form); no chrome. (gate: pd-note-block, #5731)
    * `card` is slots-native — it consumes `slots` alone (title/body/media/action
      all live under it) plus the `tone` accent chrome. (#5731)
    * `callout` (census follow-up) consumes `content` (the legacy inline body
      array `callout_body_inline/1` reads), `slots` (the materialized `body`
      slot) and `title`; `tone` / `collapsible` / `collapsed` are chrome. The
      proven legacy `text` dialect is also consumed and canonicalized at write
      boundaries.
    * `pipeline` (census follow-up) consumes `nodes` alone — the node list whose
      per-node `kind`/`title`/`detail`/`files` `pipeline_html/1` reads. An empty
      or mis-keyed node list (e.g. prose stranded under `steps`/`stages`)
      renders "" with no signal at all.

  Every other type returns `nil` (UNGATED — either not lossy, or a VISIBLE
  placeholder makes its empty state honest — see the census on
  `pt-backlog-block-field-census`), so no existing block of an undeclared type
  can ever be flagged. Never raises.
  """
  @spec field_vocab(term()) :: field_vocab() | nil
  def field_vocab(%{"type" => "note"}),
    do: %{consumed: ["label", "lead", "text", "slots"], chrome: []}

  def field_vocab(%{"type" => "card"}),
    do: %{consumed: ["slots"], chrome: ["tone"]}

  def field_vocab(%{"type" => "callout"}),
    do: %{consumed: ["content", "slots", "title"], chrome: ["tone", "collapsible", "collapsed"]}

  def field_vocab(%{"type" => "pipeline"}),
    do: %{consumed: ["nodes"], chrome: []}

  def field_vocab(_), do: nil

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

  # A note's `label`/`lead`/`body` slots are its flat `label`/`lead`/`text`
  # fields wrapped as ONE implicit paragraph each (the compat-read: no `slots`
  # key ⇒ synthesize the three paragraphs). The flat field maps to the slot as
  # label→label, lead→lead, body→TEXT (the legacy `notes` item vocab: `text`).
  # An EMPTY lead synthesizes `[]` (arity {:max, 1}: an absent optional slot),
  # so `note_lead_text/1` reads the empty legacy field, never a stray paragraph.
  defp legacy_slot(%{"type" => "note"} = block, "label"),
    do: [note_para(note_flat(block, "label"))]

  defp legacy_slot(%{"type" => "note"} = block, "body"),
    do: [note_para(note_flat(block, "text"))]

  defp legacy_slot(%{"type" => "note"} = block, "lead") do
    case note_flat(block, "lead") do
      "" -> []
      lead -> [note_para(lead)]
    end
  end

  # A stage's `kind`/`title`/`detail` slot is its SCALAR string wrapped as ONE implicit
  # PLAIN-TEXT paragraph (one text run). A PRESENT key (even "") synthesizes ONE element;
  # an ABSENT key synthesizes []. `stage_field_text/2` flattens it BACK to the scalar
  # string, so a scalar-only stage reads through the slot API byte-identically to a
  # slots-materialized stage.
  defp legacy_slot(%{"type" => "stage"} = block, name) when name in ["kind", "title", "detail"] do
    case Map.fetch(block, name) do
      {:ok, scalar} ->
        [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => scalar}]}]

      :error ->
        []
    end
  end

  defp legacy_slot(_block, _name), do: []

  # A plain-text implicit paragraph: an empty string wraps to `content: []`, a
  # non-empty string to a single inline text node (the flatten-to-plain twin).
  defp note_para(""), do: %{"type" => "paragraph", "content" => []}

  defp note_para(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  # A note's flat field as a plain string (nil-safe, non-map-safe): the legacy
  # `notes` item vocab where `body` lives under the `text` key.
  defp note_flat(block, key) when is_map(block), do: block |> Map.get(key) |> to_text()
  defp note_flat(_block, _key), do: ""

  @doc """
  The inline array of a callout's single body element — from the slot's lone
  paragraph when materialized, or from legacy `content`. THE load-bearing invariant:
  both encodings of the same body yield the SAME inline array, so `Render.Compose`
  emits a byte-identical `PdText`. Always a list (nil-safe).
  """
  @spec callout_body_inline(term()) :: [map()]
  def callout_body_inline(block) do
    case slot_elements(block, "body") do
      [first | _] when is_map(first) ->
        case Map.get(first, "content") do
          content when is_list(content) and content != [] -> content
          _ -> callout_text_inline(block)
        end

      _ ->
        callout_text_inline(block)
    end
  end

  defp callout_text_inline(block) do
    case is_map(block) && Map.get(block, "text") do
      text when is_binary(text) and text != "" ->
        [%{"type" => "text", "value" => text}]

      _ ->
        []
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

  # ── note widget accessors (the notes-grid split) ─────────────────────────────
  #
  # THE load-bearing byte-identity invariants — the `callout_body_inline/1` analog,
  # one per field. Each returns the PLAIN string of the slot (the lone paragraph's
  # inline FLATTENED to plain text, marks dropped) when materialized, else the
  # legacy flat field. Both encodings of the same note yield the SAME three strings
  # ⟹ `Components.note_item_html/1` emits byte-identical HTML. These ALSO read a
  # bare legacy `notes` ITEM (a `%{label,lead,text}` map with no `"type"` key —
  # slot_elements synthesizes nothing for it, so it falls straight to the flat
  # field), which is what lets `notes_html/1` reuse `note_item_html/1` per item and
  # stay byte-identical. The body flattens to plain text (marks dropped) to match
  # the legacy `escape_html(text)` contract — a DELIBERATE lossy-inline tradeoff.

  @doc "The plain label string of a note's `label` slot, else the legacy flat `label` field."
  @spec note_label_text(term()) :: String.t()
  def note_label_text(block), do: note_slot_text(block, "label", "label")

  @doc "The plain lead string of a note's `lead` slot, else the legacy flat `lead` field (\"\" when absent)."
  @spec note_lead_text(term()) :: String.t()
  def note_lead_text(block), do: note_slot_text(block, "lead", "lead")

  @doc "The plain body string of a note's `body` slot, else the legacy flat `text` field."
  @spec note_body_text(term()) :: String.t()
  def note_body_text(block), do: note_slot_text(block, "body", "text")

  # Flatten the slot's lone paragraph inline to plain text (marks dropped); when no
  # element is present (a bare legacy item, or an empty optional slot), read the flat
  # field. The SAME plain string either encoding, so reader bytes never move.
  defp note_slot_text(block, slot_name, flat_key) do
    primary =
      case slot_elements(block, slot_name) do
        [first | _] when is_map(first) -> first |> Map.get("content") |> flatten_inline_text()
        _ -> note_flat(block, flat_key)
      end

    # THE BODY'S LAST RESORT — a top-level `content` inline array. A note
    # persisted the widget way (`{"type":"note","content":[…]}`, no flat `text`)
    # read "" through every path above: the legacy synthesis wraps the ABSENT
    # `text` field as an empty paragraph, which flattens to "" and blanked the
    # note on the server-rendered reader (1 such block live on guerrilla, census
    # 2026-07-25, task-993d136b0fbf2fd1) while `@barkpark/react` rendered it.
    # This is the `callout_body_inline/1` law — content ⟂ text, content read
    # FIRST — arriving at the note's BODY only: `label`/`lead` have no `content`
    # spelling, and letting the block's body inline leak into them would print
    # the body twice.
    case {primary, slot_name} do
      {"", "body"} -> note_content_text(block)
      _ -> primary
    end
  end

  # A note block's top-level `content` flattened to plain text. The guard is the
  # SAME one `callout_body_inline/1` and `paragraph_inline/1` hold — a NON-EMPTY
  # INLINE ARRAY — and it is load-bearing twice over:
  #
  #   * it is the shape the widget actually persists (`content:[…]` inline
  #     nodes), the one `@barkpark/react` renders and this fallback exists for;
  #   * a SCALAR `content` (a bare string) stays UNREAD, which is exactly what
  #     the silent-content-loss write gate needs: `lossy_shape?/1` asks
  #     `note_body_text/1` whether the reader shows anything, so consuming a
  #     string here would quietly disarm the ratchet that REFUSES a note whose
  #     prose was stranded under `content`
  #     (`Barkpark.Content.Papers.NoteCardFieldLossTest`). Rendering an inline
  #     array is a fix; swallowing a stranded string would be a regression
  #     dressed as one.
  #
  # Never consulted while the body slot or the flat `text` carries anything, so
  # both canonical encodings stay byte-identical.
  defp note_content_text(block) when is_map(block) do
    case Map.get(block, "content") do
      list when is_list(list) and list != [] -> flatten_inline_text(list)
      _ -> ""
    end
  end

  defp note_content_text(_block), do: ""

  # ── stage widget accessor ────────────────────────────────────────────────────

  @doc """
  The PLAIN string of a stage's named text field (`"kind"` / `"title"` / `"detail"`)
  — the stage analogue of `callout_body_inline/1`. Reads the lone slot element's
  text-runs FLATTENED to plain text (marks dropped) when a `slots` map carries it, ELSE
  the top-level scalar via the compat synthesis. THE load-bearing invariant: both
  encodings yield the SAME string ⟹ `Components.stage_html/1` escapes the same bytes ⟹
  a byte-identical reader. Always a string (nil-safe).

  Stage slot text is PLAIN (unlike the callout's rich `inline*` body): the reader
  escapes it as flat text with no inline markup, so the serializer joins the text-runs
  and DROPS marks — a pasted `<strong>` must NOT survive or byte-identity breaks.
  """
  @spec stage_field_text(term(), String.t()) :: String.t()
  def stage_field_text(block, name) do
    case slot_elements(block, name) do
      [first | _] when is_map(first) -> first |> Map.get("content") |> flatten_inline_text()
      _ -> ""
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

  # A note dual-writes its three flat fields ⇄ a `slots` map, idempotently. label +
  # body (both required) are ALWAYS written on both sides; `lead` (optional) is
  # OMITTED entirely — flat key AND slot — when empty/absent (byte-fidelity: an
  # absent lead round-trips ABSENT, never `""`, mirroring the callout title
  # maybe_put + the empty-body omit). The plain field ⇄ one-paragraph-slot mapping
  # goes through the SAME `note_*_text/1` accessors + `note_para/1` synthesis, so
  # `normalize_widget(normalize_widget(x)) == normalize_widget(x)`.
  def normalize_widget(%{"type" => "note"} = block) do
    label = note_label_text(block)
    lead = note_lead_text(block)
    body = note_body_text(block)

    slots =
      %{"label" => [note_para(label)], "body" => [note_para(body)]}
      |> put_note_lead_slot(lead)

    block
    |> Map.drop(["label", "lead", "text", "slots"])
    |> Map.put("label", label)
    |> Map.put("text", body)
    |> put_note_lead_field(lead)
    |> Map.put("slots", slots)
  end

  # Stage — idempotent dual-write of the three text scalars ⇄ `slots`. An EMPTY field
  # (flattened text == "") omits BOTH the scalar AND the slot entry (the callout empty-
  # body precedent); `files`/`source` chrome pass through untouched. Persistence-side
  # ONLY (not on the read/compose path), so stored bytes are never force-backfilled.
  def normalize_widget(%{"type" => "stage"} = block) do
    fields = ["kind", "title", "detail"]

    {scalars, slots} =
      Enum.reduce(fields, {%{}, %{}}, fn name, {sc, sl} ->
        case stage_field_text(block, name) do
          "" ->
            {sc, sl}

          text ->
            {Map.put(sc, name, text),
             Map.put(sl, name, [
               %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
             ])}
        end
      end)

    block
    |> Map.drop(fields ++ ["slots"])
    |> Map.merge(scalars)
    |> put_stage_slots(slots)
  end

  def normalize_widget(block), do: block

  defp put_note_lead_slot(slots, ""), do: slots
  defp put_note_lead_slot(slots, lead), do: Map.put(slots, "lead", [note_para(lead)])

  defp put_note_lead_field(block, ""), do: block
  defp put_note_lead_field(block, lead), do: Map.put(block, "lead", lead)
  defp put_stage_slots(block, slots) when map_size(slots) == 0, do: block
  defp put_stage_slots(block, slots), do: Map.put(block, "slots", slots)

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

  @doc """
  The SILENT-CONTENT-LOSS predicate — the checker paired with `field_vocab/1`.
  A block is in the lossy shape when BOTH hold:

    1. it RENDERS NO PROSE — every consumed content field, read through the SAME
       byte-identity accessors the renderer uses (`note_*_text/1`,
       `card_*_text/1` / `card_media|action/1`), is blank/absent; AND
    2. it carries an UNKNOWN key whose value holds SEMANTIC TEXT — authored prose
       stranded under a key the renderer never reads.

  This is the NARROW rule (measured ZERO false alarms across the live corpus):
  a block whose consumed fields ARE populated is never flagged, however many
  extra chrome/experimental keys ride alongside — the emptiness gate, not an
  allowlist. A genuinely-empty block (no unknown loud key) is not "loss" either.
  Only `note` / `card` declare a vocabulary, so every other type is `false`.
  Never raises.
  """
  @spec lossy_shape?(term()) :: boolean()
  def lossy_shape?(block) when is_map(block) do
    case field_vocab(block) do
      nil -> false
      vocab -> renders_no_prose?(block) and loud_unknown_key?(block, vocab)
    end
  end

  def lossy_shape?(_), do: false

  # Does the block render NO prose? Asked through the renderer's own accessors so
  # "empty" means exactly "the reader shows nothing".
  defp renders_no_prose?(%{"type" => "note"} = block) do
    blank?(note_label_text(block)) and blank?(note_lead_text(block)) and
      blank?(note_body_text(block))
  end

  defp renders_no_prose?(%{"type" => "card"} = block) do
    blank?(card_title_text(block)) and blank?(card_body_text(block)) and
      is_nil(card_media(block)) and is_nil(card_action(block))
  end

  # A callout renders no prose when BOTH its body inline (from the `content`
  # legacy array or the materialized `body` slot, read through the renderer's own
  # `callout_body_inline/1`) is blank AND its optional `title` is blank — the two
  # surfaces `Compose.compose_block(callout)` paints. The proven legacy `text`
  # dialect is consumed by `callout_body_inline/1`; other unread keys stay loud.
  defp renders_no_prose?(%{"type" => "callout"} = block) do
    blank?(flatten_inline_text(callout_body_inline(block))) and
      blank?(to_text(Map.get(block, "title")))
  end

  # A pipeline renders no prose when its `nodes` list carries no readable text in
  # ANY node (asked through the SAME per-node `kind`/`title`/`detail`/`files` keys
  # `pipeline_html/1` reads) — an empty/absent node list, or one whose prose was
  # stranded under a mis-keyed container (`steps`/`stages`/…). `Enum.all?` over []
  # is true, so an empty pipeline reads as no-prose.
  defp renders_no_prose?(%{"type" => "pipeline"} = block) do
    block |> Map.get("nodes") |> pipeline_nodes_blank?()
  end

  defp renders_no_prose?(_), do: false

  defp pipeline_nodes_blank?(nodes) when is_list(nodes) do
    Enum.all?(nodes, fn node ->
      blank?(pnode_text(node, "kind")) and blank?(pnode_text(node, "title")) and
        blank?(pnode_text(node, "detail")) and blank?(pnode_text(node, "files"))
    end)
  end

  defp pipeline_nodes_blank?(_), do: true

  defp pnode_text(node, key) when is_map(node), do: node |> Map.get(key) |> to_text()
  defp pnode_text(_node, _key), do: ""

  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  # Is there a key OUTSIDE the recognized vocabulary whose value carries semantic
  # text (a letter or number, recursively)? A loud unknown key is the tell of
  # stranded prose — a bare structural/boolean stray never trips it.
  defp loud_unknown_key?(block, vocab) do
    recognized = @vocab_structural_keys ++ vocab.consumed ++ vocab.chrome

    block
    |> Map.drop(recognized)
    |> Map.values()
    |> Enum.any?(&loud_value?/1)
  end

  defp loud_value?(v) when is_binary(v), do: Regex.match?(~r/[\p{L}\p{N}]/u, v)
  defp loud_value?(v) when is_list(v), do: Enum.any?(v, &loud_value?/1)
  defp loud_value?(%{} = m), do: m |> Map.values() |> Enum.any?(&loud_value?/1)
  defp loud_value?(_), do: false
end
