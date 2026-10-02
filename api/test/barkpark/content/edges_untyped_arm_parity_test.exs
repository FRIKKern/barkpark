defmodule Barkpark.Content.EdgesUntypedArmParityTest do
  @moduledoc """
  THE GAP-#2 CONTRACT, ASSERTED DIRECTLY (task-8f5938e3ba4d98c7).

  The invariant: *a typed reference and an untyped reference to the same target
  resolve to the same visibility for the same caller.* `Content.Edges` has
  claimed that contract in prose since the batched resolver landed, and for two
  caller kinds the code did not hold it.

  `Edges.resolvable_targets/3` SPLITS on `ref_type`. The typed arm runs
  `Content.Query.resolvable_doc_ids/4` — dataset, workspace-or-global,
  `maybe_scope_to_owner/4`, `maybe_scope_to_grants/2`. The type-agnostic arm
  (`untyped_resolvable/3`, and the fallback clause of
  `resolve_target_existence/4` behind `extract_edges/2`'s per-target
  `dangling: :resolve`) ran dataset + workspace-or-global and NEITHER clamp. A
  wikilink carrying no `refType`, or a field declaring `refTypeTolerant: true`,
  therefore sailed past exactly the clauses the typed arm applied.

  WHAT EACH ARM BELOW VARIES, and nothing else: one caller, one target, two
  reference shapes. The two arms are asked the SAME question about the SAME row
  and their answers are compared to each other — no arm asserts a hardcoded
  visibility, so this suite cannot pass by agreeing with a wrong expectation.

  NON-VACUITY. Each divergence arm carries a control on the SAME fixture:

    * the ownership arm — an `:api_token` caller (the principal
      `Scope.scope_to_owner/2` deliberately exempts) sees the foreign-owner row
      on BOTH arms, so `false == false` for the `:user` caller cannot be the
      row simply being unreachable;
    * the grant arm — the identical caller and opts WITHOUT `grant_scoped: true`
      sees the row on BOTH arms, so the clamped `false == false` is the flag's
      doing and not the fixture's.

  Every schema and document id in this suite is uniquely suffixed: the test
  database is shared, so the suite asserts the presence/absence of ITS OWN ids
  and never a count.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Edges}

  @dataset "test"

  setup do
    suffix = String.replace(Ecto.UUID.generate(), "-", "") |> binary_part(0, 12)
    owned_type = "parity_owned_#{suffix}"
    src_type = "parity_src_#{suffix}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => owned_type,
          "title" => "Parity Owned",
          "owner_scoped" => true,
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset
      )

    # The REFERRING type: two reference fields at the same target type, one
    # typed and one `refTypeTolerant` (which is what makes the emitted edge
    # carry `ref_type = nil` and take the type-agnostic arm).
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => src_type,
          "title" => "Parity Source",
          "fields" => [
            %{"name" => "typed_ref", "type" => "reference", "refType" => owned_type},
            %{
              "name" => "loose_ref",
              "type" => "reference",
              "refType" => owned_type,
              "refTypeTolerant" => true
            }
          ]
        },
        @dataset
      )

    user_a = Ecto.UUID.generate()
    user_b = Ecto.UUID.generate()

    # The target: an owner_scoped row owned by user_b, PUBLISHED. Both arms read
    # under the `:published` lens (no `drafts.` twin is matched), so a
    # draft-only fixture would be dangling on both arms and every parity
    # assertion below would pass vacuously.
    target_id = "parity-target-#{suffix}"
    owner_opts = [caller_context: CallerContext.from_user(user_b, roles: [])]

    {:ok, _} =
      Content.create_document(
        owned_type,
        %{"_id" => target_id, "title" => target_id},
        @dataset,
        [instance_wide: true] ++ owner_opts
      )

    {:ok, target} = Content.publish_document(target_id, owned_type, @dataset, owner_opts)

    # Assert the PRECONDITION rather than trusting the write: the published row
    # must exist, carry no `drafts.` prefix, and be owned by user_b. Without
    # all three the ownership arm measures nothing.
    assert target.doc_id == target_id
    assert Repo.get_by!(Document, doc_id: target_id, dataset: @dataset).owner_id == user_b

    # The schema catalog, read with an unclamped principal. `extract_edges/2`
    # resolves the referring type through `Content.list_schemas/2`, which is
    # itself grant-narrowed — a grant_scoped caller would get an EMPTY catalog
    # and therefore zero edges, which is a catalog finding, not a resolution
    # one. Supplying the prefetch (exactly as `Content.Graph.corpus_edges/3`
    # does in production) keeps this suite measuring the RESOLVER.
    schemas = Content.list_schemas(@dataset, [])

    %{
      suffix: suffix,
      owned_type: owned_type,
      src_type: src_type,
      user_a: user_a,
      user_b: user_b,
      target: target,
      schemas: schemas
    }
  end

  # ── caller opts ───────────────────────────────────────────────────────────

  defp user_opts(user_id), do: [caller_context: CallerContext.from_user(user_id, roles: [])]

  defp token_opts,
    do: [caller_context: %CallerContext{principal_type: :api_token, token_id: "tok-parity"}]

  # A grant-derived caller with no covering grant. `Scope.scope_to_grants/3`
  # fails CLOSED on this shape — which is the whole point: the typed arm does,
  # and the type-agnostic arm must too.
  defp grant_opts(user_id),
    do: [
      caller_context: %CallerContext{
        principal_type: :user,
        user_id: user_id,
        is_admin: false,
        grants: []
      },
      grant_scoped: true
    ]

  # ── the two arms, asked the same question ────────────────────────────────

  # BATCHED: `resolvable_targets/3` answers both pair shapes in one call, so the
  # typed and the type-agnostic answer come from the SAME invocation on the SAME
  # opts — nothing between the two readings can drift.
  defp batched_arms(doc_id, type, opts) do
    set = Edges.resolvable_targets([{doc_id, type}, {doc_id, nil}], @dataset, opts)
    %{typed: MapSet.member?(set, {doc_id, type}), untyped: MapSet.member?(set, {doc_id, nil})}
  end

  # PER-TARGET: `extract_edges/2` with the default `dangling: :resolve` runs
  # `resolve_target_existence/4` once per reference value. The source document
  # is a plain map (never persisted) so the only row this can be reading is the
  # target. `dangling` is inverted here so both helpers speak "resolvable".
  defp per_target_arms(doc_id, src_type, suffix, schemas, opts) do
    doc = %{
      doc_id: "parity-src-#{suffix}",
      type: src_type,
      dataset: @dataset,
      content: %{"typed_ref" => doc_id, "loose_ref" => doc_id}
    }

    edges = Edges.extract_edges(doc, [schemas: schemas] ++ opts)

    typed = Enum.find(edges, &(&1.field == "typed_ref"))
    loose = Enum.find(edges, &(&1.field == "loose_ref"))

    # Guard the fixture, not the finding: if the schema scan ever stops emitting
    # both fields, the parity assertion below would compare nil to nil and pass.
    assert typed, "typed_ref edge missing — the extract, not the clamp, changed"
    assert loose, "loose_ref edge missing — the extract, not the clamp, changed"
    assert loose.refType == nil, "refTypeTolerant must null the emitted refType"

    %{typed: not typed.dangling, untyped: not loose.dangling}
  end

  # ════════════════════════════════════════════════════════════════════════
  # OWNERSHIP — an owner_scoped type under a non-admin :user caller_context
  # ════════════════════════════════════════════════════════════════════════

  describe "owner_scoped type, :user caller_context" do
    test "batched: the typed and the type-agnostic arm agree", ctx do
      %{typed: typed, untyped: untyped} =
        batched_arms(ctx.target.doc_id, ctx.owned_type, user_opts(ctx.user_a))

      assert typed == untyped,
             "gap-#2 broken: typed=#{typed} untyped=#{untyped} for a foreign owner's row"
    end

    test "per-target: resolve_target_existence/4's two clauses agree", ctx do
      %{typed: typed, untyped: untyped} =
        per_target_arms(
          ctx.target.doc_id,
          ctx.src_type,
          ctx.suffix,
          ctx.schemas,
          user_opts(ctx.user_a)
        )

      assert typed == untyped,
             "gap-#2 broken: typed=#{typed} untyped=#{untyped} for a foreign owner's row"
    end

    test "CONTROL — the exempt :api_token principal sees the row on BOTH arms", ctx do
      %{typed: typed, untyped: untyped} =
        batched_arms(ctx.target.doc_id, ctx.owned_type, token_opts())

      assert typed, "fixture unreachable: even an exempt token cannot resolve the target"
      assert untyped
    end

    test "CONTROL — the OWNER sees their own row on BOTH arms", ctx do
      %{typed: typed, untyped: untyped} =
        batched_arms(ctx.target.doc_id, ctx.owned_type, user_opts(ctx.user_b))

      assert typed, "fixture unreachable: the owner cannot resolve their own target"
      assert untyped
    end

    test "CONTROL — a NON-owner_scoped type is untouched on both arms", ctx do
      open_type = "parity_open_#{ctx.suffix}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => open_type,
            "title" => "Parity Open",
            "fields" => [%{"name" => "body", "type" => "text"}]
          },
          @dataset
        )

      open_id = "parity-open-#{ctx.suffix}"

      {:ok, _} =
        Content.create_document(
          open_type,
          %{"_id" => open_id, "title" => open_id},
          @dataset,
          [instance_wide: true] ++ user_opts(ctx.user_b)
        )

      {:ok, open_doc} =
        Content.publish_document(open_id, open_type, @dataset, user_opts(ctx.user_b))

      %{typed: typed, untyped: untyped} =
        batched_arms(open_doc.doc_id, open_type, user_opts(ctx.user_a))

      assert typed, "a non-owner_scoped row must stay visible to any caller"
      assert untyped, "the new clamp must not narrow a type that is not owner_scoped"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # GRANTS — a grant_scoped caller with no covering grant
  # ════════════════════════════════════════════════════════════════════════

  describe "grant_scoped caller" do
    test "batched: the typed and the type-agnostic arm agree", ctx do
      %{typed: typed, untyped: untyped} =
        batched_arms(ctx.target.doc_id, ctx.owned_type, grant_opts(ctx.user_b))

      assert typed == untyped,
             "gap-#2 broken: typed=#{typed} untyped=#{untyped} for a grant_scoped caller"
    end

    test "per-target: resolve_target_existence/4's two clauses agree", ctx do
      %{typed: typed, untyped: untyped} =
        per_target_arms(
          ctx.target.doc_id,
          ctx.src_type,
          ctx.suffix,
          ctx.schemas,
          grant_opts(ctx.user_b)
        )

      assert typed == untyped,
             "gap-#2 broken: typed=#{typed} untyped=#{untyped} for a grant_scoped caller"
    end

    test "CONTROL — the SAME caller without the grant_scoped flag sees it on both arms", ctx do
      opts = grant_opts(ctx.user_b) |> Keyword.delete(:grant_scoped)

      %{typed: typed, untyped: untyped} = batched_arms(ctx.target.doc_id, ctx.owned_type, opts)

      assert typed, "fixture unreachable without the flag — the refute above proves nothing"
      assert untyped
    end
  end
end
