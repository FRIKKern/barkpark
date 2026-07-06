defmodule Barkpark.PortableDoc.Constraints do
  @moduledoc """
  The PortableDoc **constraint vocabulary** — the doctrine's structural rules
  expressed as data (pdd-t20, paper `portabledoc-doctrine`).

  A doc type declares its shape as a list of DECLARATIONS. Each declaration
  names a block `kind` (matched against a block's `"role"`) and pins three
  independent facets:

    * **presence** — `:required` | `:optional`
    * **count** (cardinality) — `{:exactly, n}` | `{:min, n}` | `{:max, n}`
    * **position** (relative order) — `{:index, i}` | `{:after, kind}` |
      `{:before, kind}` | `{:after, kind, :before, kind2}` | `:top_group` |
      `:bottom_group` | `:free`

  and optionally `locked: true` (the placement-lock the op engine enforces in
  `Barkpark.PortableDoc.Patch`).

      %{kind: "title",    presence: :required, count: {:exactly, 1}, position: {:index, 0}, locked: true}
      %{kind: "featured", presence: :optional, count: {:max, 1},     position: {:after, "title"}}

  `validate/2` is the single evaluator: it returns the list of human-readable
  violation strings for a block list against a declaration set (`[]` when the
  doc satisfies every declaration). It is PURE — no Repo, no I/O — so both the
  save-time gate (`Content.Papers.Template.validate/1`'s successor) and the
  op-layer backstop (`Patch.apply_patch/3`'s `:constraints` opt) can call it.

  ## Byte-compatibility (D3)

  The current paper template re-expresses exactly (see
  `Content.Papers.Template.paper_declarations/0`): a well-formed template paper
  (`role: "title"` heading at index 0, `role: "featured"` image after it)
  validates clean, so the pre-doctrine corpus is untouched.

  > NOTE (pd-doctrine wave 4): this module is the constraint-vocabulary seam
  > owned by slice **t20a**. The op-layer backstop slice (t20b) ships a
  > minimal-but-correct evaluator here so its enforcement is verifiable
  > standalone; t20a's fuller vocabulary supersedes/extends it at integration.
  """

  @type kind :: String.t()
  @type presence :: :required | :optional
  @type count :: {:exactly, non_neg_integer()} | {:min, non_neg_integer()} | {:max, non_neg_integer()}
  @type position ::
          {:index, non_neg_integer()}
          | {:after, kind()}
          | {:before, kind()}
          | {:after, kind(), :before, kind()}
          | :top_group
          | :bottom_group
          | :free
  @type declaration :: %{
          optional(:kind) => kind(),
          optional(:presence) => presence(),
          optional(:count) => count(),
          optional(:position) => position(),
          optional(:locked) => boolean()
        }

  @doc """
  Return the list of violation strings for `blocks` against `declarations`
  (`[]` = every declaration satisfied). Cardinality and relative-order are
  evaluated against the TOP-LEVEL block list (locks + template roles are a
  top-level concept). Pure.
  """
  @spec validate(list(), [declaration()]) :: [String.t()]
  def validate(blocks, declarations) when is_list(blocks) and is_list(declarations) do
    Enum.flat_map(declarations, &validate_one(&1, blocks))
  end

  def validate(_blocks, _declarations), do: []

  # ── per-declaration evaluation ─────────────────────────────────────────────

  defp validate_one(decl, blocks) when is_map(decl) do
    kind = decl_kind(decl)
    matches = matches_with_index(blocks, kind)
    n = length(matches)

    cardinality_errors(decl, kind, n) ++ position_errors(decl, kind, matches, blocks)
  end

  defp validate_one(_decl, _blocks), do: []

  defp cardinality_errors(decl, kind, n) do
    presence_error(Map.get(decl, :presence, :optional), kind, n) ++
      count_error(Map.get(decl, :count), kind, n)
  end

  defp presence_error(:required, kind, 0),
    do: ["constraint: required #{quoted(kind)} block is missing"]

  defp presence_error(_presence, _kind, _n), do: []

  defp count_error({:exactly, c}, kind, n) when n != c,
    do: ["constraint: exactly #{c} #{quoted(kind)} block(s) required, found #{n}"]

  defp count_error({:min, c}, kind, n) when n < c,
    do: ["constraint: at least #{c} #{quoted(kind)} block(s) required, found #{n}"]

  defp count_error({:max, c}, kind, n) when n > c,
    do: ["constraint: at most #{c} #{quoted(kind)} block(s) allowed, found #{n}"]

  defp count_error(_count, _kind, _n), do: []

  # Position is only meaningful when the kind is actually present — an absent
  # optional block has no place to be misplaced (cardinality already flags a
  # missing REQUIRED one).
  defp position_errors(_decl, _kind, [], _blocks), do: []

  defp position_errors(decl, kind, matches, blocks) do
    case Map.get(decl, :position, :free) do
      :free -> []
      {:index, i} -> index_errors(kind, matches, i)
      {:after, ref} -> after_errors(kind, matches, blocks, ref)
      {:before, ref} -> before_errors(kind, matches, blocks, ref)
      {:after, ref, :before, ref2} ->
        after_errors(kind, matches, blocks, ref) ++ before_errors(kind, matches, blocks, ref2)

      :top_group -> group_errors(kind, matches, blocks, :top)
      :bottom_group -> group_errors(kind, matches, blocks, :bottom)
      _ -> []
    end
  end

  defp index_errors(kind, matches, i) do
    if Enum.all?(matches, fn {_b, idx} -> idx == i end),
      do: [],
      else: ["constraint: #{quoted(kind)} block must be at position #{i}"]
  end

  # Relative order: every kind-block must sit AFTER the referenced kind's first
  # occurrence. A missing reference is not a positioning failure of THIS block
  # (the reference's own declaration flags its absence) — skip.
  defp after_errors(kind, matches, blocks, ref) do
    case first_index(blocks, ref) do
      nil ->
        []

      ref_idx ->
        if Enum.all?(matches, fn {_b, idx} -> idx > ref_idx end),
          do: [],
          else: ["constraint: #{quoted(kind)} block must come after #{quoted(ref)}"]
    end
  end

  defp before_errors(kind, matches, blocks, ref) do
    case first_index(blocks, ref) do
      nil ->
        []

      ref_idx ->
        if Enum.all?(matches, fn {_b, idx} -> idx < ref_idx end),
          do: [],
          else: ["constraint: #{quoted(kind)} block must come before #{quoted(ref)}"]
    end
  end

  # Grouping: every kind-block forms a contiguous run at the top (indices
  # 0..n-1) or bottom (the last n indices) of the top-level list.
  defp group_errors(kind, matches, blocks, side) do
    idxs = matches |> Enum.map(fn {_b, idx} -> idx end) |> Enum.sort()
    n = length(idxs)
    total = length(blocks)

    expected =
      case side do
        :top -> Enum.to_list(0..(n - 1))
        :bottom -> Enum.to_list((total - n)..(total - 1))
      end

    if idxs == expected,
      do: [],
      else: ["constraint: #{quoted(kind)} block(s) must be grouped at the #{side}"]
  end

  # ── small helpers ──────────────────────────────────────────────────────────

  # Blocks whose role matches `kind`, paired with their top-level index.
  defp matches_with_index(blocks, kind) do
    blocks
    |> Enum.with_index()
    |> Enum.filter(fn {b, _i} -> role_of(b) == kind end)
  end

  defp first_index(blocks, kind) do
    Enum.find_index(blocks, fn b -> role_of(b) == kind end)
  end

  defp role_of(b) when is_map(b), do: Map.get(b, "role")
  defp role_of(_), do: nil

  defp decl_kind(decl), do: Map.get(decl, :kind) || Map.get(decl, "kind")

  defp quoted(nil), do: "\"\""
  defp quoted(kind), do: "\"#{kind}\""
end
