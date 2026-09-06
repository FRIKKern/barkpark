defmodule Barkpark.PortableDoc.Patch do
  @moduledoc """
  Pure, immutable patch operations over a PortableDoc block tree. A STANDALONE
  Elixir patch engine — the single owner of the block-tree op semantics. Its
  behaviour is pinned by the golden fixtures in
  `api/test/support/fixtures/doc-patch-op/`, which double as the cross-surface
  op contract every producer (CLI/SDK/Studio) writes against.

  `apply_patch/2` is **pure**: it never mutates its input, performs no Repo
  access, no GenServer, no I/O. It returns either a new document/block list or
  a [structured error](#module-errors) — never a silent no-op, never a
  partially-applied result.

  ## Wire shape

  Documents and ops cross process boundaries as JSON, so this module operates
  on plain maps keyed by **string keys** — the same convention as the sibling
  `Barkpark.PortableDoc.Render`. A document is

      %{"version" => 1, "title" => "…", "blocks" => [block, …]}

  and a block is `%{"id" => "…", "type" => "…", …}`. A `section` block nests
  the tree under its own `"blocks"` key; an `expandable` uses `"children"`
  (with `"blocks"` retained as a compatibility alias); each `steps` row uses
  the same visible-body aliases. A `figure` has exactly one canonical child
  block under its singular map-valued `"child"` key; its other keys are not
  treated as child collections. A `columns` block stores `"columns"` as a list
  of column block-lists; scalar rows and scalar elements are retained opaquely.

  ## The six ops

  Each op is a map whose `"op"` key is the discriminator:

  | `"op"`          | Required keys        | Effect                                              |
  | --------------- | -------------------- | --------------------------------------------------- |
  | `append-block`  | `"block"`            | Append to the document's **top-level** `blocks`.    |
  | `insert-after`  | `"afterId"`, `"block"` | Insert directly after the block `afterId`.        |
  | `patch-block`   | `"id"`, `"patch"`    | Shallow-merge `patch`; `id` + `type` are immutable. |
  | `replace-block` | `"id"`, `"block"`    | Replace the block `id` wholesale.                   |
  | `remove-block`  | `"id"`               | Remove the block `id` from its parent's `blocks`.   |
  | `move-block`    | `"id"`, `"after"`    | Move the block `id` to just after `after` (or to the front when `after` is `null`). |

  Ids are resolved against the **entire** tree: `insert-after`, `patch-block`,
  `replace-block`, and `remove-block` recurse into `section` and `expandable`
  children, each visible `steps` row body, each plain `tabs` row's canonical
  `blocks` list, and a `terminal`'s canonical `children` list, plus a `figure`'s
  canonical child and that child's visible descendants, and map children within
  each valid `columns` list, at any depth.
  `patch-block` and a map-valued `replace-block` may target the figure child.
  `append-block` is top-level only.

  `move-block` is **top-level only** (the paper editor reorders the top-level
  block list; nested-within-section reorder is not in scope). It is a pure
  permutation — the moved block keeps its identity (same id, same content), so
  it never duplicates content. `"after"` names the block the moved block should
  land directly after; `null` (or absent) moves it to the head. Moving a block
  after itself, or after the block it already follows, is an idempotent no-op.
  Note: `move-block` is a Barkpark-local extension layered on top of the core
  five ops.

  An op MAY also carry an optional `"ifRev"` / `"expectedVersion"` concurrency
  guard. The single-op core does not evaluate these (rev comparison is a
  batch/runtime concern that builds on top), so this module ignores them — they
  pass through harmlessly.

  ## Errors

  Mutating ops validate before they mutate and surface failures as tagged
  tuples, consistent with the error-return style elsewhere in this namespace:

      {:error, {:block_not_found, target, op}}
      {:error, {:type_mismatch, target, op}}
      {:error, {:duplicate_id, target, op}}
      {:error, {:locked_block, target, op}}
      {:error, {:constraint, message, op}}
      {:error, {:invalid_op, op_value}}

  where `target` is the offending id (or `afterId`), and `op` is the failing
  op's discriminator string. `:invalid_op` is raised for an unknown or
  malformed op map. `:locked_block` is the doctrine backstop (pdd-t2/t3): an op
  that would remove, move, displace, or unmake a template-locked block is
  rejected — both when the op TARGETS the locked block and when its side
  effect would shift a locked block's top-level position (e.g. an insert-after
  landing inside the locked prefix).

  `:constraint` covers intrinsic container shape as well as the optional
  CONSTRAINT-VOCABULARY backstop (pdd-t20). A figure must retain exactly one
  map-valued child, so direct `insert-after`, direct `remove-block`, and a
  non-map direct `replace-block` are refused even without opts. For declared
  constraints, when the caller threads a doc type's DECLARATIONS via
  `apply_patch/3`'s `opts[:constraints]`
  (`Barkpark.PortableDoc.Constraints` shape), an op whose result would break a
  CARDINALITY (min/max/exactly) or RELATIVE-order (after/before/index) rule is
  rejected — a `remove-block` dropping below a min-N, an `insert-after` adding
  a second max-1 block, or a `move-block` misplacing an optional-but-positioned
  block. `message` is the first human-readable violation string. The veto fires
  ONLY when the doc was VALID before the op (D12): a legacy / already-invalid
  doc plus an unrelated op is NOT rejected, so no edit is punished for a
  pre-existing violation. With no declarations passed, non-figure behavior is
  byte-identical to the pre-vocabulary behavior (D3 additive).
  """

  alias Barkpark.PortableDoc.Constraints

  @figure_child_constraint "figure must contain exactly one child"

  @type block :: %{required(String.t()) => term()}
  @type blocks :: [block()]
  @type doc :: %{required(String.t()) => term()}
  @type op :: %{required(String.t()) => term()}

  @type error_code ::
          :block_not_found | :type_mismatch | :duplicate_id | :locked_block | :constraint
  @type error ::
          {:error, {error_code(), String.t(), String.t()}}
          | {:error, {:invalid_op, term()}}

  @doc """
  Apply a single `op` to a PortableDoc or a bare block list.

  Accepts either a full document map (`%{"blocks" => […]}`) or a plain list of
  blocks. Returns the same shape it was given on success — `{:ok, new_doc}` for
  a document, `{:ok, new_blocks}` for a bare list — or `{:error, reason}`.

  `opts` (optional) may carry `:constraints` — a
  `Barkpark.PortableDoc.Constraints` declaration list. When present, an op whose
  result breaks a cardinality / relative-order rule is rejected `{:constraint,
  message, op}` (see the [errors](#module-errors)). Omitting it (the default)
  leaves the engine byte-identical to the pre-vocabulary behaviour.

  Pure and immutable: the input is never mutated; only the path from the root
  down to the target block is rebuilt (structural sharing), every untouched
  subtree keeps its identity.
  """
  @spec apply_patch(doc(), op()) :: {:ok, doc()} | error()
  @spec apply_patch(blocks(), op()) :: {:ok, blocks()} | error()
  @spec apply_patch(doc(), op(), keyword()) :: {:ok, doc()} | error()
  @spec apply_patch(blocks(), op(), keyword()) :: {:ok, blocks()} | error()
  def apply_patch(doc_or_blocks, op), do: apply_patch(doc_or_blocks, op, [])

  def apply_patch(%{"blocks" => blocks} = doc, op, opts) when is_list(blocks) do
    case apply_patch(blocks, op, opts) do
      {:ok, new_blocks} -> {:ok, Map.put(doc, "blocks", new_blocks)}
      {:error, _} = err -> err
    end
  end

  def apply_patch(blocks, op, opts) when is_list(blocks) do
    # Enforcement order: apply → locked-placement check (op-specific, more
    # precise) → constraint-vocabulary check (cardinality + relative order).
    # Locks are checked FIRST so a displaced locked block keeps its
    # `{:locked_block, …}` error; constraints only ever ADD a rejection class,
    # never mask one.
    with {:ok, new_blocks} <- apply_to_blocks(blocks, op),
         {:ok, new_blocks} <- check_locked_placement(blocks, new_blocks, op),
         {:ok, new_blocks} <- check_duplicate_ratchet(blocks, new_blocks, op) do
      check_constraints(blocks, new_blocks, op, opts)
    end
  end

  @doc """
  Apply a LIST of ops to a PortableDoc (or bare block list) **atomically** —
  all-or-nothing.

  Each op is applied in order via `apply_patch/2`, threading the result of
  one op into the next. The fold halts on the FIRST op that errors and
  returns `{:error, reason}` with the ORIGINAL input unchanged — a partially
  applied batch is never returned. `{:ok, doc}` is returned only when every
  op applied cleanly.

  Pure and immutable, like `apply_patch/2`: no Repo access, no I/O. An empty
  list is a no-op that returns `{:ok, input}`.

  `opts` (optional) is threaded verbatim into each `apply_patch/3` — so a
  `:constraints` declaration list is evaluated per op, halting the batch on the
  first op that breaks a rule (the paper op-fold in `Content.Papers.BlockOps`
  passes the paper declarations here).
  """
  @spec apply_patches(doc(), [op()]) :: {:ok, doc()} | error()
  @spec apply_patches(blocks(), [op()]) :: {:ok, blocks()} | error()
  @spec apply_patches(doc(), [op()], keyword()) :: {:ok, doc()} | error()
  @spec apply_patches(blocks(), [op()], keyword()) :: {:ok, blocks()} | error()
  def apply_patches(doc_or_blocks, ops), do: apply_patches(doc_or_blocks, ops, [])

  def apply_patches(doc_or_blocks, ops, opts) when is_list(ops) do
    Enum.reduce_while(ops, {:ok, doc_or_blocks}, fn op, {:ok, acc} ->
      case apply_patch(acc, op, opts) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # ── op dispatch — one clause per discriminator ─────────────────────────────

  defp apply_to_blocks(blocks, %{"op" => "append-block", "block" => block}) do
    if id_exists?(blocks, block_id(block)) do
      {:error, {:duplicate_id, block_id(block), "append-block"}}
    else
      {:ok, blocks ++ [block]}
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "insert-after", "afterId" => after_id, "block" => block}) do
    cond do
      id_exists?(blocks, block_id(block)) ->
        {:error, {:duplicate_id, block_id(block), "insert-after"}}

      direct_figure_child_id?(blocks, after_id) ->
        {:error, {:constraint, @figure_child_constraint, "insert-after"}}

      true ->
        case transform_at_id(blocks, after_id, fn target -> [target, block] end) do
          nil -> {:error, {:block_not_found, after_id, "insert-after"}}
          new_blocks -> {:ok, new_blocks}
        end
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "patch-block", "id" => id, "patch" => patch})
       when is_map(patch) do
    # Track a type mismatch out-of-band: transform_at_id can only signal
    # found / not-found, so the merge fn records the conflict and leaves the
    # target untouched, and we inspect the flag after the walk — a captured
    # `type_mismatch?` flag threaded out of the closure.
    {result, mismatch?} =
      transform_with_flag(blocks, id, fn target ->
        # `patch.type` present and differing from the target's type is a
        # mismatch (contract §5); omitting `type` is the common case. A literal
        # `null` is treated as "absent" — it can never re-key the type.
        case Map.get(patch, "type") do
          nil ->
            {[merge_block(target, coerce_field_patch(target, strip_template_keys(patch)))], false}

          patch_type ->
            if patch_type != Map.get(target, "type") do
              {[target], true}
            else
              {[merge_block(target, coerce_field_patch(target, strip_template_keys(patch)))],
               false}
            end
        end
      end)

    cond do
      result == nil -> {:error, {:block_not_found, id, "patch-block"}}
      mismatch? -> {:error, {:type_mismatch, id, "patch-block"}}
      true -> {:ok, result}
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "replace-block", "id" => id, "block" => block}) do
    cond do
      locked_at_id?(blocks, id) ->
        {:error, {:locked_block, id, "replace-block"}}

      direct_figure_child_id?(blocks, id) and not is_map(block) ->
        {:error, {:constraint, @figure_child_constraint, "replace-block"}}

      true ->
        case transform_at_id(blocks, id, fn _target -> [block] end) do
          nil -> {:error, {:block_not_found, id, "replace-block"}}
          new_blocks -> {:ok, new_blocks}
        end
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "remove-block", "id" => id}) do
    # Doctrine backstop (pdd-t3): a template-locked block cannot be removed —
    # by ANY client, canvas diff or raw API. Checked before the transform so
    # the atomic batch halts with a clear error instead of silently unmaking
    # the guarantee. Op-of-absent stays a no-op below.
    cond do
      locked_at_id?(blocks, id) ->
        {:error, {:locked_block, id, "remove-block"}}

      direct_figure_child_id?(blocks, id) ->
        {:error, {:constraint, @figure_child_constraint, "remove-block"}}

      true ->
        case transform_at_id(blocks, id, fn _target -> [] end) do
          # Idempotent re-send safety for the canvas incremental-diff model: removing a
          # block that is ALREADY absent is a NO-OP, not an error. The desired end-state
          # (id gone) is already true, so we return the block list unchanged and let the
          # atomic batch continue. Without this, a stale remove-block (the canvas can
          # re-send a batch that crosses an echo in flight, or a leading-block delete can
          # arrive twice) would HALT the whole batch via apply_patches/2 / block_ops.ex's
          # fold and discard the user's real edits riding the same batch. Other not-found
          # cases (patch-block / insert-after / replace-block of a missing anchor) keep
          # their hard {:block_not_found} error — only remove/move-of-absent is a no-op.
          nil -> {:ok, blocks}
          new_blocks -> {:ok, new_blocks}
        end
    end
  end

  # move-block — top-level reorder, pure permutation. Lift the block out by id,
  # then splice it back in directly after `after_id` (or at the head when
  # `after_id` is nil). The lifted block keeps its identity + content, so this
  # never duplicates a block. Both the moved id and the (non-nil) anchor must
  # exist at top level; "after itself" is an idempotent no-op.
  defp apply_to_blocks(blocks, %{"op" => "move-block", "id" => id} = op) do
    after_id = Map.get(op, "after")

    cond do
      # Doctrine backstop (pdd-t3): a template-locked block holds its position.
      locked_at_id?(blocks, id) ->
        {:error, {:locked_block, id, "move-block"}}

      not Enum.any?(blocks, &(block_id(&1) == id)) ->
        # Idempotent re-send safety for the canvas incremental-diff model (same
        # rationale as remove-block above): moving a block that is ALREADY absent at
        # top level is a NO-OP, not an error — there is nothing to move and the
        # desired end-state can't be expressed, so we leave the list unchanged and let
        # the atomic batch continue rather than HALT it and lose co-batched edits.
        # NOTE: a PRESENT moved id with an ABSENT `after` anchor still errors below —
        # that is a real "where do I put it?" failure, NOT a move-of-absent.
        {:ok, blocks}

      after_id == id ->
        # Moving a block after itself is meaningless but harmless.
        {:ok, blocks}

      not is_nil(after_id) and not Enum.any?(blocks, &(block_id(&1) == after_id)) ->
        {:error, {:block_not_found, after_id, "move-block"}}

      true ->
        moved = Enum.find(blocks, &(block_id(&1) == id))
        without = Enum.reject(blocks, &(block_id(&1) == id))

        new_blocks =
          case after_id do
            nil ->
              [moved | without]

            anchor ->
              idx = Enum.find_index(without, &(block_id(&1) == anchor))
              {head, tail} = Enum.split(without, idx + 1)
              head ++ [moved] ++ tail
          end

        {:ok, new_blocks}
    end
  end

  defp apply_to_blocks(_blocks, op) do
    {:error, {:invalid_op, op}}
  end

  # Doctrine (pdd-t3): template keys are immutable through patch-block — like
  # `id` and `type`, `locked` and `role` cannot be set, changed, or stripped by
  # a content patch. Seeding happens at create (Papers.Template), never via ops.
  defp strip_template_keys(patch) when is_map(patch), do: Map.drop(patch, ["locked", "role"])

  # Doctrine invariant (pdd-t2): locked placement means a template-locked block
  # HOLDS ITS TOP-LEVEL POSITION under every op — not just the ops that TARGET
  # it (remove/move, rejected in their own clauses above with op-specific
  # errors) but any op whose SIDE EFFECT displaces or unmakes it:
  #
  #   * insert-after / append into the locked prefix (e.g. inserting after the
  #     locked title pushes the locked featured from index 1 to 2 — the exact
  #     op a canvas Enter at the end of the title run would emit);
  #   * move-block of an UNLOCKED block to the head or in between locked blocks;
  #   * replace-block swapping a locked block for an unlocked one (or re-keying
  #     its id) — wholesale replace would otherwise be a delete in disguise.
  #
  # Checked once per op against the top-level index map (locks are a top-level
  # template concept). Additive / D3: a doc with no locked blocks passes in one
  # scan, so the pre-doctrine corpus is byte-untouched.
  defp check_locked_placement(before_blocks, after_blocks, op) do
    before_map = locked_index_map(before_blocks)

    if map_size(before_map) == 0 do
      {:ok, after_blocks}
    else
      after_map = locked_index_map(after_blocks)

      case Enum.find(before_map, fn {id, idx} -> Map.get(after_map, id) != idx end) do
        nil -> {:ok, after_blocks}
        {id, _idx} -> {:error, {:locked_block, id, Map.get(op, "op")}}
      end
    end
  end

  # Doctrine backstop (pdd-t20): the CONSTRAINT-VOCABULARY op-layer veto — the
  # calm sibling of check_locked_placement. When the caller threads a doc type's
  # constraint DECLARATIONS via `opts[:constraints]`, an op whose result would
  # break a cardinality (min/max/exactly) or relative-order (after/before/index)
  # rule is rejected `{:constraint, first_error, op}`.
  #
  # The ONLY-WHEN-BEFORE-VALID guard is LOAD-BEARING (D12): the veto fires only
  # when the doc satisfied every declaration BEFORE the op. A legacy /
  # already-invalid doc (e.g. a pre-doctrine paper with no title block) plus an
  # unrelated op is NOT rejected — an edit is never punished for a pre-existing
  # violation, and the op engine stays additive over the untouched corpus (D3).
  #
  # With no declarations passed (the common case, incl. every non-paper op), the
  # scan short-circuits and the result is byte-identical to the pre-vocabulary
  # engine.
  defp check_constraints(before_blocks, after_blocks, op, opts) do
    case Keyword.get(opts, :constraints, []) do
      [] ->
        {:ok, after_blocks}

      decls ->
        # Validate the RESULT first: the common op keeps the doc valid, so the
        # before-scan (only needed to decide whether a violation is NEW) is
        # skipped entirely on the happy path. Truth table is unchanged: a valid
        # result always passes; an invalid result is vetoed only when the doc
        # was valid before the op (D12).
        case Constraints.validate(after_blocks, decls) do
          [] ->
            {:ok, after_blocks}

          [first | _] ->
            if Constraints.validate(before_blocks, decls) == [] do
              {:error, {:constraint, first, Map.get(op, "op")}}
            else
              {:ok, after_blocks}
            end
        end
    end
  end

  # Guard every op against introducing a duplicate authored identity anywhere
  # in the document, including non-targetable container-row ids. Existing
  # legacy duplicates remain editable: only an occurrence count that grows
  # beyond both one and its pre-op count is rejected.
  defp check_duplicate_ratchet(before_blocks, after_blocks, %{"op" => op_kind}) do
    before_counts = before_blocks |> authored_ids() |> Enum.frequencies()
    after_ids = authored_ids(after_blocks)
    after_counts = Enum.frequencies(after_ids)

    case Enum.find(after_ids, fn id ->
           after_counts[id] > 1 and after_counts[id] > Map.get(before_counts, id, 0)
         end) do
      nil -> {:ok, after_blocks}
      id -> {:error, {:duplicate_id, id, op_kind}}
    end
  end

  defp check_duplicate_ratchet(_before_blocks, after_blocks, _op),
    do: {:ok, after_blocks}

  defp authored_ids(blocks) when is_list(blocks),
    do: Enum.flat_map(blocks, &authored_block_ids/1)

  defp authored_block_ids(block) when is_map(block) do
    own = authored_id(block)

    nested =
      case block do
        %{"type" => "section", "blocks" => children} when is_list(children) ->
          authored_ids(children)

        %{"type" => "expandable"} ->
          authored_alias_ids(block)

        %{"type" => "columns", "columns" => columns} when is_list(columns) ->
          Enum.flat_map(columns, fn
            children when is_list(children) -> authored_ids(children)
            _opaque -> []
          end)

        %{"type" => "figure", "child" => child} when is_map(child) ->
          authored_block_ids(child)

        %{"type" => "terminal"} ->
          authored_alias_ids(block)

        %{"type" => "steps", "steps" => rows} when is_list(rows) ->
          Enum.flat_map(rows, &authored_step_row_ids/1)

        %{"type" => "tabs", "tabs" => rows} when is_list(rows) ->
          Enum.flat_map(rows, &authored_tab_row_ids/1)

        _ ->
          []
      end

    own ++ nested
  end

  defp authored_block_ids(_block), do: []

  defp authored_step_row_ids(row) when is_map(row),
    do: authored_id(row) ++ authored_alias_ids(row)

  defp authored_step_row_ids(_row), do: []

  defp authored_tab_row_ids(row) when is_map(row) do
    nested =
      case Map.get(row, "blocks") do
        children when is_list(children) -> authored_ids(children)
        _opaque -> []
      end

    authored_id(row) ++ nested
  end

  defp authored_tab_row_ids(_row), do: []

  # Both renderer body aliases are authored block lists when present. Count the
  # shadow too: replacing a parent must not smuggle an identity collision into
  # metadata merely because the other alias currently wins renderer precedence.
  defp authored_alias_ids(container) do
    Enum.flat_map(["children", "blocks"], fn key ->
      case Map.get(container, key) do
        children when is_list(children) -> authored_ids(children)
        _other -> []
      end
    end)
  end

  defp authored_id(%{"id" => id}) when is_binary(id) and id != "", do: [id]
  defp authored_id(_value), do: []

  # Top-level id → index for every template-locked block.
  defp locked_index_map(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {block, idx}, acc ->
      if is_map(block) and Map.get(block, "locked") == true do
        Map.put(acc, block_id(block), idx)
      else
        acc
      end
    end)
  end

  # True when the block with `id` is template-locked. Templates seed locks at
  # the top level, but raw/legacy documents can carry locked nested children;
  # once those children are addressable they must retain the same remove /
  # replace protection.
  defp locked_at_id?(blocks, id) do
    Enum.any?(blocks, fn block ->
      (block_id(block) == id and block_locked?(block)) or
        Enum.any?(visible_child_lists(block), &locked_at_id?(&1, id))
    end)
  end

  # ── id resolution & structural transform (recurses containers) ─────────────

  # True when `id` names any block anywhere in `blocks` (recurses containers).
  defp id_exists?(blocks, id) do
    Enum.any?(blocks, fn block ->
      block_id(block) == id or Enum.any?(visible_child_lists(block), &id_exists?(&1, id))
    end)
  end

  defp direct_figure_child_id?(blocks, id) do
    Enum.any?(blocks, fn
      %{"type" => "figure", "child" => child} = block when is_map(child) ->
        block_id(child) == id or
          Enum.any?(visible_child_lists(block), &direct_figure_child_id?(&1, id))

      block when is_map(block) ->
        Enum.any?(visible_child_lists(block), &direct_figure_child_id?(&1, id))

      _block ->
        false
    end)
  end

  # Transform a block list, applying `fn` to the matching block at any depth.
  #
  # `fn` returns the replacement list for the array slot it was handed (one
  # block in → zero or more out), so a single helper drives patch (1→1),
  # replace (1→1), insert-after (1→2) and remove (1→0).
  #
  # Returns `nil` (distinct from `[]`) when `id` was not found at this level or
  # below, so callers can tell "not found" from "found and removed". Untouched
  # subtrees keep their identity; only the branch containing the target is
  # rebuilt.
  defp transform_at_id(blocks, id, fun) do
    case transform_with_flag(blocks, id, fn block -> {fun.(block), false} end) do
      {nil, _flag} -> nil
      {transformed, _flag} -> transformed
    end
  end

  # Variant of `transform_at_id` whose `fun` returns `{replacement_list, flag}`.
  # Returns `{transformed_blocks_or_nil, flag}` — the flag carries out-of-band
  # state (here: a type mismatch) past the walk. The flag defaults to false
  # when the target is never reached.
  defp transform_with_flag(blocks, id, fun) do
    transform_with_flag(blocks, id, fun, [])
  end

  defp transform_with_flag([], _id, _fun, _acc), do: {nil, false}

  defp transform_with_flag([block | rest], id, fun, acc) do
    cond do
      block_id(block) == id ->
        {replacement, flag} = fun.(block)
        {Enum.reverse(acc) ++ replacement ++ rest, flag}

      true ->
        case transform_block_children(block, id, fun) do
          {nil, _} ->
            transform_with_flag(rest, id, fun, [block | acc])

          {next_block, flag} ->
            {Enum.reverse([next_block | acc]) ++ rest, flag}
        end
    end
  end

  # ── small helpers ──────────────────────────────────────────────────────────

  defp transform_block_children(block, id, fun) do
    case visible_child_container(block) do
      {:blocks, key, children} ->
        case transform_with_flag(children, id, fun) do
          {nil, _flag} -> {nil, false}
          {next_children, flag} -> {Map.put(block, key, next_children), flag}
        end

      {:steps, rows} ->
        case transform_steps_rows(rows, id, fun, []) do
          {nil, _flag} -> {nil, false}
          {next_rows, flag} -> {Map.put(block, "steps", next_rows), flag}
        end

      {:tabs, rows} ->
        case transform_tabs_rows(rows, id, fun, []) do
          {nil, _flag} -> {nil, false}
          {next_rows, flag} -> {Map.put(block, "tabs", next_rows), flag}
        end

      {:columns, columns} ->
        case transform_columns(columns, id, fun, []) do
          {nil, _flag} -> {nil, false}
          {next_columns, flag} -> {Map.put(block, "columns", next_columns), flag}
        end

      {:figure, child} ->
        case transform_with_flag([child], id, fun) do
          {nil, _flag} ->
            {nil, false}

          {[next_child], flag} when is_map(next_child) ->
            {Map.put(block, "child", next_child), flag}

          {_invalid_shape, _flag} ->
            {nil, false}
        end

      nil ->
        {nil, false}
    end
  end

  defp transform_steps_rows([], _id, _fun, _acc), do: {nil, false}

  defp transform_steps_rows([row | rest], id, fun, acc) when is_map(row) do
    case visible_row_container(row) do
      {key, children} ->
        case transform_with_flag(children, id, fun) do
          {nil, _flag} ->
            transform_steps_rows(rest, id, fun, [row | acc])

          {next_children, flag} ->
            {Enum.reverse([Map.put(row, key, next_children) | acc]) ++ rest, flag}
        end

      nil ->
        transform_steps_rows(rest, id, fun, [row | acc])
    end
  end

  defp transform_steps_rows([row | rest], id, fun, acc),
    do: transform_steps_rows(rest, id, fun, [row | acc])

  defp transform_tabs_rows([], _id, _fun, _acc), do: {nil, false}

  defp transform_tabs_rows([%{"blocks" => children} = row | rest], id, fun, acc)
       when is_list(children) do
    case transform_with_flag(children, id, fun) do
      {nil, _flag} ->
        transform_tabs_rows(rest, id, fun, [row | acc])

      {next_children, flag} ->
        {Enum.reverse([Map.put(row, "blocks", next_children) | acc]) ++ rest, flag}
    end
  end

  defp transform_tabs_rows([row | rest], id, fun, acc),
    do: transform_tabs_rows(rest, id, fun, [row | acc])

  defp transform_columns([], _id, _fun, _acc), do: {nil, false}

  defp transform_columns([children | rest], id, fun, acc) when is_list(children) do
    case transform_with_flag(children, id, fun) do
      {nil, _flag} ->
        transform_columns(rest, id, fun, [children | acc])

      {next_children, flag} ->
        {Enum.reverse([next_children | acc]) ++ rest, flag}
    end
  end

  defp transform_columns([opaque | rest], id, fun, acc),
    do: transform_columns(rest, id, fun, [opaque | acc])

  defp visible_child_lists(block) do
    case visible_child_container(block) do
      {:blocks, _key, children} ->
        [children]

      {:steps, rows} ->
        Enum.flat_map(rows, fn
          row when is_map(row) ->
            case visible_row_container(row) do
              {_key, children} -> [children]
              nil -> []
            end

          _row ->
            []
        end)

      {:tabs, rows} ->
        Enum.flat_map(rows, fn
          %{"blocks" => children} when is_list(children) -> [children]
          _row -> []
        end)

      {:columns, columns} ->
        Enum.filter(columns, &is_list/1)

      {:figure, child} ->
        [[child]]

      nil ->
        []
    end
  end

  defp visible_child_container(%{"type" => "section", "blocks" => blocks})
       when is_list(blocks),
       do: {:blocks, "blocks", blocks}

  defp visible_child_container(%{"type" => "expandable"} = block) do
    case visible_alias(block) do
      {key, children} -> {:blocks, key, children}
      nil -> nil
    end
  end

  defp visible_child_container(%{"type" => "steps", "steps" => rows}) when is_list(rows),
    do: {:steps, rows}

  defp visible_child_container(%{"type" => "tabs", "tabs" => rows}) when is_list(rows),
    do: {:tabs, rows}

  defp visible_child_container(%{"type" => "columns", "columns" => columns})
       when is_list(columns),
       do: {:columns, columns}

  defp visible_child_container(%{"type" => "figure", "child" => child}) when is_map(child),
    do: {:figure, child}

  defp visible_child_container(%{"type" => "terminal", "children" => children} = block)
       when is_list(children) do
    if Map.has_key?(block, "blocks"), do: nil, else: {:blocks, "children", children}
  end

  defp visible_child_container(%{"type" => "terminal"}), do: nil

  defp visible_child_container(_block), do: nil

  defp visible_row_container(row), do: visible_alias(row)

  # Renderer precedence is truthy `children` before `blocks`. A malformed
  # truthy value therefore hides the shadow alias instead of exposing content
  # the reader does not render; nil/false retain the legacy fallback.
  defp visible_alias(container) do
    case Map.get(container, "children") do
      children when children not in [nil, false] ->
        if is_list(children), do: {"children", children}, else: nil

      _absent ->
        case Map.get(container, "blocks") do
          blocks when is_list(blocks) -> {"blocks", blocks}
          _other -> nil
        end
    end
  end

  # Shallow / replace-by-key merge of `patch` over `target`, then re-pin `id`
  # and `type` so a patch can never mutate the block's identity or kind.
  # Map.merge replaces wholesale per key (arrays/objects are not deep-merged),
  # matching the op contract's shallow-merge rule.
  defp merge_block(target, patch) do
    target
    |> Map.merge(patch)
    |> Map.put("id", Map.get(target, "id"))
    |> Map.put("type", Map.get(target, "type"))
  end

  defp block_id(block) when is_map(block), do: Map.get(block, "id")
  defp block_id(_block), do: nil

  defp block_locked?(block) when is_map(block), do: Map.get(block, "locked") == true
  defp block_locked?(_block), do: false

  # Minimal per-type coercion for field-* LEAF blocks (P2.1). Only the
  # `"value"` key is touched, and only for field-boolean (string "true"/"false"
  # → real bool) so a stringy checkbox value can never land in the store as a
  # binary. All other field types (string/slug/text/select/datetime/color) keep
  # their value as-is — string values are already the right shape. Non-field
  # blocks (rich text, callout, …) are returned untouched, so the P1 path is
  # byte-identical. Full per-type schema validation is a later slice.
  defp coerce_field_patch(%{"type" => "field-boolean"}, patch) do
    case Map.fetch(patch, "value") do
      {:ok, "true"} -> Map.put(patch, "value", true)
      {:ok, "false"} -> Map.put(patch, "value", false)
      _ -> patch
    end
  end

  defp coerce_field_patch(_target, patch), do: patch
end
