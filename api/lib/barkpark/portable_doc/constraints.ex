defmodule Barkpark.PortableDoc.Constraints do
  @moduledoc """
  The PortableDoc **constraint vocabulary** — a pure, Content-free checker for a
  block document's structural declarations (paper `portabledoc-doctrine`, task
  pdd-t20; charter D10/D11).

  A doc type's structure is expressed as a list of DECLARATIONS. Each declaration
  governs one block *kind* across three independent axes:

    * **presence** — `:required` (the kind must appear) or `:optional`.
    * **cardinality** — how many may appear: `{:exactly, n}` / `{:min, n}` /
      `{:max, n}`.
    * **position** — a list of position constraints, ALL of which must hold:
      * `{:index, n}` — pinned to an absolute index (every occurrence).
      * `{:not_index, n}` — the mirror of `{:index, n}`: NO occurrence may sit at
        absolute index `n` (e.g. "no widget at index 0").
      * `:top_group` / `:bottom_group` — occurrences form a contiguous run at
        the very top / bottom of the doc.
      * `{:before, kind}` / `{:after, kind}` **relations** — RELATIVE order
        against other kinds, checked ONLY between kinds actually present (an
        absent anchor never fails a present block). Relations compose, e.g.
        `[{:after, "title"}, {:before, "featured"}]`.
      * `:free` — no position constraint.

  ## Kinds: role/type strings AND composition tiers

  A declaration's `kind` is EITHER a role/type STRING (the block's structural
  label, matched by `kind_of/1` — role→type) OR a composition **tier atom**
  (`:element | :widget | :section`, matched by
  `Barkpark.PortableDoc.Tiers.tier_of/1` — a type-only classifier). Both are
  discriminated at match time by the same index, which keys every block under
  BOTH its string kind AND its tier atom (string keys and atom keys never
  collide, so the two vocabularies are independent):

    * `count: {:max, 0}` on `:widget` — "forbid a widget entirely".
    * `presence: :required` (or `count: {:min, 1}`) on `:section` — "require at
      least one section".
    * `position: [{:not_index, 0}]` on `:widget` — "no widget at the very top".

  Because a tier atom anchors the index too, `{:after, :element}` /
  `{:before, :section}` relations can anchor on a whole tier for free. A block is
  indexed under both keys, so a decl set carrying BOTH a `"section"` type decl
  and a `:section` tier decl evaluates them independently — the tier decl counts
  the whole `:section` tier (a `section` AND a `columns` block), potentially
  overlapping the type decl. That overlap is intended.

  `locked` on a declaration marks the kind as template-locked (the op-backstops in
  `Barkpark.PortableDoc.Patch` and the seed own that flag) — the checker itself is
  agnostic to it; it reports pure structural violations.

  The *kind* of a block is its `"role"` (the doctrine's structural label), falling
  back to its `"type"`. So a `role: "title"` heading has kind `"title"`, and a
  plain paragraph has kind `"paragraph"`.

  This module is deliberately free of any `Content` / DB dependency (layering
  purity): it takes plain block maps + declarations and returns calm error
  strings. `Barkpark.Content.Papers.Template` owns the paper's declaration set and
  the additive trigger; this owns the enforcement math.
  """

  alias Barkpark.PortableDoc.Tiers

  @type tier :: :element | :widget | :section
  @type kind :: String.t() | tier()
  @type presence :: :required | :optional
  @type count ::
          {:exactly, non_neg_integer()}
          | {:min, non_neg_integer()}
          | {:max, non_neg_integer()}
  @type position_atom :: :top_group | :bottom_group | :free
  @type relation :: {:before, kind()} | {:after, kind()}
  @type position_constraint ::
          {:index, non_neg_integer()}
          | {:not_index, non_neg_integer()}
          | position_atom()
          | relation()
  @type position :: [position_constraint()]
  @type declaration :: %{
          kind: kind(),
          presence: presence(),
          count: count(),
          position: position(),
          locked: boolean()
        }

  @doc """
  The structural *kind* of a block: its `"role"` (the doctrine label), else its
  `"type"`. `nil` for a block that carries neither (it constrains nothing and is
  never counted).
  """
  @spec kind_of(term()) :: kind() | nil
  def kind_of(%{"role" => role}) when is_binary(role) and role != "", do: role
  def kind_of(%{"type" => type}) when is_binary(type) and type != "", do: type
  def kind_of(_), do: nil

  @doc """
  Validate `blocks` against `declarations`, returning `[]` for a conforming doc or
  a list of calm, specific error strings (presence + cardinality + relative/pinned
  order). Never raises; a non-list input validates to `[]`.
  """
  @spec validate(term(), term()) :: [String.t()]
  def validate(blocks, declarations) when is_list(blocks) and is_list(declarations) do
    indexed = index_blocks(blocks)
    total = length(blocks)

    decl_errors =
      Enum.flat_map(declarations, fn decl ->
        indices = Map.get(indexed, decl.kind, [])

        presence_errors(decl, indices) ++
          cardinality_errors(decl, indices) ++
          position_errors(decl, indices, indexed, total)
      end)

    # D1 slot gate (STEP 3): every widget's slot children must be element-tier.
    # Additive and legacy-safe — a legacy callout (body synthesized from `content`)
    # yields no slot error; only a slot holding a nested widget/section does.
    # `Slots` is pure/Content-free, so this keeps the checker's layering purity.
    slot_errors = Enum.flat_map(blocks, &Barkpark.PortableDoc.Slots.slot_type_errors/1)

    # LIVE-DATA gate (task-list widget): a present-but-malformed `query` (a non-map)
    # yields a calm error. Additive and legacy-safe — a snapshot-only / author-pinned
    # task-list (no `query`) and a well-formed live query both yield nothing, so no
    # existing paper gains an error. `Slots` is pure/Content-free, so this keeps the
    # checker's layering purity (same posture as `slot_type_errors` above).
    query_errors = Enum.flat_map(blocks, &Barkpark.PortableDoc.Slots.query_type_errors/1)

    decl_errors ++ slot_errors ++ query_errors
  end

  def validate(_, _), do: []

  @doc "Whether `blocks` satisfies every declaration (i.e. `validate/2` is empty)."
  @spec satisfied?(term(), term()) :: boolean()
  def satisfied?(blocks, declarations), do: validate(blocks, declarations) == []

  # key (string kind OR tier atom) => ascending list of the indices where a
  # matching block sits. Each block is written under BOTH its `kind_of` (string)
  # and its `Tiers.tier_of` (atom) so a declaration keyed by either vocabulary
  # resolves uniformly. String keys and atom keys never collide, and `kind_of` is
  # added first for every block, so every string-keyed index list is byte-
  # identical to the kind-only index — existing (string-only) decls are unaffected.
  defp index_blocks(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {block, idx}, acc ->
      acc
      |> add_index(kind_of(block), idx)
      |> add_index(Tiers.tier_of(block), idx)
    end)
  end

  defp add_index(acc, nil, _idx), do: acc
  defp add_index(acc, key, idx), do: Map.update(acc, key, [idx], &(&1 ++ [idx]))

  # ── presence ──────────────────────────────────────────────────────────────
  defp presence_errors(%{presence: :required, kind: kind}, []),
    do: [~s(the required "#{kind}" block is missing)]

  defp presence_errors(_decl, _indices), do: []

  # ── cardinality ─────────────────────────────────────────────────────────────
  defp cardinality_errors(%{count: count, kind: kind}, indices) do
    occ = length(indices)

    case count do
      {:exactly, n} ->
        # occ == 0 is silent here: a required-missing kind is the presence axis'
        # error (no double-report), an optional-absent kind is fine.
        if occ == n or occ == 0,
          do: [],
          else: [~s(exactly #{n} "#{kind}" #{block_word(n)} required, found #{occ})]

      {:max, n} ->
        if occ > n,
          do: [~s(at most #{n} "#{kind}" #{block_word(n)} allowed, found #{occ})],
          else: []

      {:min, n} ->
        if occ < n,
          do: [~s(at least #{n} "#{kind}" #{block_word(n)} required, found #{occ})],
          else: []
    end
  end

  # ── position ────────────────────────────────────────────────────────────────
  # An absent kind constrains no position (presence/cardinality already spoke).
  # Position is a LIST of constraints and every element must hold — a mixed list
  # like `[{:index, 0}, {:before, "x"}]` enforces both (never a silent no-op).
  defp position_errors(_decl, [], _indexed, _total), do: []

  defp position_errors(%{position: position, kind: kind}, indices, indexed, total)
       when is_list(position) do
    Enum.flat_map(position, fn
      {:index, n} -> index_errors(kind, indices, n)
      {:not_index, n} -> not_index_errors(kind, indices, n)
      :free -> []
      :top_group -> top_group_errors(kind, indices)
      :bottom_group -> bottom_group_errors(kind, indices, total)
      {:after, anchor} -> anchored_errors(kind, indices, anchor, indexed, &after_error/4)
      {:before, anchor} -> anchored_errors(kind, indices, anchor, indexed, &before_error/4)
      _ -> []
    end)
  end

  defp position_errors(_decl, _indices, _indexed, _total), do: []

  defp index_errors(kind, indices, n) do
    case Enum.find(indices, &(&1 != n)) do
      nil -> []
      off -> [~s(the "#{kind}" block must be at block #{n}, found at #{off})]
    end
  end

  # The mirror of `{:index, n}`: no occurrence of `kind` may sit at index `n`.
  defp not_index_errors(kind, indices, n) do
    if n in indices,
      do: [~s(a "#{kind}" block may not be at block #{n})],
      else: []
  end

  defp top_group_errors(kind, indices) do
    sorted = Enum.sort(indices)

    if sorted == Enum.to_list(0..(length(sorted) - 1)//1),
      do: [],
      else: [~s(the "#{kind}" block must sit at the top)]
  end

  defp bottom_group_errors(kind, indices, total) do
    sorted = Enum.sort(indices)
    n = length(sorted)

    if sorted == Enum.to_list((total - n)..(total - 1)//1),
      do: [],
      else: [~s(the "#{kind}" block must sit at the bottom)]
  end

  # Relative order: each relation is checked ONLY when the anchor kind is present.
  # `{:after, a}` — every occurrence of `kind` sits after every occurrence of `a`
  # (`min(kind) > max(a)`); `{:before, a}` — the mirror (`max(kind) < min(a)`).
  defp anchored_errors(kind, indices, anchor, indexed, check) do
    case Map.get(indexed, anchor, []) do
      [] -> []
      anchor_idx -> check.(kind, indices, anchor, anchor_idx)
    end
  end

  defp after_error(kind, indices, anchor, anchor_idx) do
    if Enum.min(indices) > Enum.max(anchor_idx),
      do: [],
      else: [~s(the "#{kind}" block must come after the "#{anchor}" block)]
  end

  defp before_error(kind, indices, anchor, anchor_idx) do
    if Enum.max(indices) < Enum.min(anchor_idx),
      do: [],
      else: [~s(the "#{kind}" block must come before the "#{anchor}" block)]
  end

  defp block_word(1), do: "block"
  defp block_word(_), do: "blocks"
end
