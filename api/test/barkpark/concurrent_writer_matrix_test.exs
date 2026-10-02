defmodule Barkpark.ConcurrentWriterMatrixTest do
  @moduledoc """
  THE CONCURRENT-WRITER MATRIX (Run-4 Lane B).

  For each pair of write paths on ONE document, two writers start together
  (a barrier releases both) after each PREPARED from the same stored state —
  what a real client holds before it writes: the Studio's mounted form, the rev
  an SDK read, the canvas's run. Then:

    * DIFFERENT fields/blocks — neither accepted change may be lost.
    * SAME field/block — the loser gets an explicit conflict (a rev-fenced
      writer), or the pair is last-writer-wins by contract; never a silent drop
      of BOTH, and never a value neither writer wrote.

  Every cell runs @rounds times. The writers:

    document  patch       REST/SDK `patch.set`, no ifRevisionID (LWW by contract)
              patch_rev   `patch.set` + ifRevisionID (412 on a stale rev)
              classic     Studio Classic save: the WHOLE mounted form, one field changed
              beta        Beta canvas: a block op on the field's bound block
              replace     `createOrReplace` of the read document, no rev — a whole-
                          document REPLACE (LWW by contract; also what sync's
                          Applier and `bp migrate` send)
              replace_rev `createOrReplace` + ifRevisionID
    paper     ops         `/ops` block op, no rev (#20843: CAS-retried server-side)
              ops_rev     `/ops` block op + if_rev
              batch       canvas batch (`apply_paper_block_ops`) + if_rev
              ingest      Bulldocs ingest upsert of the read blocks, one changed —
                          a whole-paper REPLACE (`/papers` is upsert by contract)

  WHOLE-DOCUMENT REPLACERS (replace, ingest) are last-writer-wins on the WHOLE
  document by their documented contract: a concurrent change elsewhere is
  replaced along with everything else. Those cells assert coherence (the final
  state is one writer's complete intent), not survival.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @moduletag :concurrent_matrix
  @ds "production"
  @type_name "cwm"
  @rounds 20

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "CWM",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "a", "type" => "string"},
            %{"name" => "b", "type" => "string"}
          ]
        },
        @ds
      )

    %{schema: schema}
  end

  # ── document writers ──────────────────────────────────────────────────────

  defp doc!(id) do
    {:ok, d} = Content.get_document(DraftId.draft_id(id), @type_name, @ds)
    d
  end

  defp seed_doc!(blocks?) do
    id = "cwm-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_document(
        @type_name,
        %{
          "doc_id" => DraftId.draft_id(id),
          "title" => "T",
          "content" => %{"a" => "a0", "b" => "b0"}
        },
        @ds,
        source: :api
      )

    if blocks? do
      # The first Beta edit materialises the block list.
      beta_op!(id, "a", "a0")
      assert is_list(doc!(id).content["blocks"])
    end

    id
  end

  defp beta_op!(id, field, value) do
    {:ok, _} = beta_write(id, field, value).()
  end

  defp beta_write(id, field, value) do
    doc = doc!(id)
    {blocks, _} = Content.resolve_blocks_for_edit(doc, @type_name, @ds)
    block = Enum.find(blocks, &(&1["fieldName"] == field))
    op = %{"op" => "patch-block", "id" => block["id"], "patch" => %{"value" => value}}
    fn -> Content.apply_document_block_op(DraftId.draft_id(id), @type_name, op, @ds) end
  end

  defp doc_writer(:patch, id, field, value, _ctx) do
    fn ->
      Content.apply_mutations(
        [
          %{
            "patch" => %{
              "id" => DraftId.draft_id(id),
              "type" => @type_name,
              "set" => %{field => value}
            }
          }
        ],
        @ds
      )
    end
  end

  defp doc_writer(:patch_rev, id, field, value, _ctx) do
    rev = doc!(id).rev

    fn ->
      Content.apply_mutations(
        [
          %{
            "patch" => %{
              "id" => DraftId.draft_id(id),
              "type" => @type_name,
              "set" => %{field => value},
              "ifRevisionID" => rev
            }
          }
        ],
        @ds
      )
    end
  end

  defp doc_writer(:classic, id, field, value, ctx) do
    base = doc!(id)
    form = Content.doc_to_form(base, ctx.schema) |> Map.put(field, value)
    fn -> Content.upsert_draft(base, @type_name, ctx.schema, form, @ds) end
  end

  defp doc_writer(:beta, id, field, value, _ctx), do: beta_write(id, field, value)

  defp doc_writer(:replace, id, field, value, _ctx), do: replace_writer(id, field, value, false)

  defp doc_writer(:replace_rev, id, field, value, _ctx),
    do: replace_writer(id, field, value, true)

  defp replace_writer(id, field, value, rev?) do
    base = doc!(id)

    env =
      base.content
      |> Map.drop(["blocks", "body"])
      |> Map.merge(%{"_id" => base.doc_id, "_type" => @type_name, "title" => base.title})
      |> Map.put(field, value)
      |> then(&if rev?, do: Map.put(&1, "ifRevisionID", base.rev), else: &1)

    fn -> Content.apply_mutations([%{"createOrReplace" => env}], @ds) end
  end

  # ── paper writers ─────────────────────────────────────────────────────────

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp seed_paper! do
    slug = "cwm-paper-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "CWM paper",
          "blocks" => [para("pa", "a0"), para("pb", "b0")]
        })
      )

    slug
  end

  defp paper_text(slug, id) do
    Content.get_paper(slug).content["blocks"]
    |> Enum.find(&(&1["id"] == id))
    |> get_in(["content", Access.at(0), "value"])
  end

  defp patch_op(block_id, text),
    do: %{
      "op" => "patch-block",
      "id" => block_id,
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    }

  defp paper_rev(slug) do
    {:ok, rev} = Content.Papers.op_rev(Content.get_paper(slug))
    rev
  end

  defp paper_writer(:ops, slug, block_id, text),
    do: fn -> Content.apply_paper_block_op(slug, patch_op(block_id, text), @ds) end

  defp paper_writer(:ops_rev, slug, block_id, text) do
    rev = paper_rev(slug)
    fn -> Content.apply_paper_block_op(slug, patch_op(block_id, text), @ds, if_rev: rev) end
  end

  defp paper_writer(:batch, slug, block_id, text) do
    rev = paper_rev(slug)
    fn -> Content.apply_paper_block_ops(slug, [patch_op(block_id, text)], @ds, if_rev: rev) end
  end

  defp paper_writer(:ingest, slug, block_id, text) do
    paper = Content.get_paper(slug)

    blocks =
      Enum.map(paper.content["blocks"], fn b ->
        if b["id"] == block_id, do: para(block_id, text), else: b
      end)

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "title" => paper.title,
        "blocks" => blocks
      })

    fn -> Content.upsert_paper(attrs) end
  end

  # ── the race ──────────────────────────────────────────────────────────────

  defp race(fun1, fun2) do
    parent = self()

    tasks =
      for f <- [fun1, fun2] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> f.()
          end
        end)
      end

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp ok?({:ok, _}), do: true
  defp ok?({:ok, _, _}), do: true
  defp ok?(_), do: false

  # ── document cells ────────────────────────────────────────────────────────

  @merge_writers [:patch, :patch_rev, :classic, :beta]
  @replacers [:replace, :replace_rev]

  defp needs_blocks?(w1, w2), do: :beta in [w1, w2]

  defp doc_different_fields(w1, w2, ctx) do
    for n <- 1..@rounds, reduce: [] do
      acc ->
        id = seed_doc!(needs_blocks?(w1, w2))

        [r1, r2] =
          race(doc_writer(w1, id, "a", "a#{n}", ctx), doc_writer(w2, id, "b", "b#{n}", ctx))

        c = doc!(id).content

        lost =
          if(ok?(r1) and c["a"] != "a#{n}", do: ["a"], else: []) ++
            if(ok?(r2) and c["b"] != "b#{n}", do: ["b"], else: [])

        if lost == [],
          do: acc,
          else: [{n, lost, elem(r1, 0), elem(r2, 0), Map.take(c, ["a", "b"])} | acc]
    end
  end

  defp doc_same_field(w1, w2, ctx) do
    for n <- 1..@rounds, reduce: [] do
      acc ->
        id = seed_doc!(needs_blocks?(w1, w2))

        [r1, r2] =
          race(doc_writer(w1, id, "a", "x#{n}", ctx), doc_writer(w2, id, "a", "y#{n}", ctx))

        a = doc!(id).content["a"]

        bad =
          cond do
            # A value neither writer wrote: a corrupted merge.
            a not in ["x#{n}", "y#{n}", "a0"] -> {:corrupt, a}
            # Both reported success but neither value survived.
            ok?(r1) and ok?(r2) and a == "a0" -> {:both_dropped, a}
            # A success whose value is not stored, while the other writer FAILED.
            ok?(r1) and not ok?(r2) and a != "x#{n}" -> {:silent_drop, a, r2}
            ok?(r2) and not ok?(r1) and a != "y#{n}" -> {:silent_drop, a, r1}
            true -> nil
          end

        if bad, do: [{n, bad} | acc], else: acc
    end
  end

  # Two rev-fenced writers prepared from the same rev cannot BOTH succeed.
  defp rev_fenced?(w), do: w in [:patch_rev, :replace_rev]

  for w1 <- @merge_writers, w2 <- @merge_writers, w1 <= w2 do
    @tag w1: w1, w2: w2
    test "document, different fields: #{w1} x #{w2} — no accepted write is lost", ctx do
      losses = doc_different_fields(ctx.w1, ctx.w2, ctx)

      assert losses == [],
             "#{ctx.w1} x #{ctx.w2}: #{length(losses)}/#{@rounds} rounds silently lost an accepted write:\n" <>
               Enum.map_join(Enum.take(losses, 3), "\n", &inspect/1)
    end
  end

  for w1 <- @merge_writers ++ @replacers, w2 <- @merge_writers ++ @replacers, w1 <= w2 do
    @tag w1: w1, w2: w2
    test "document, same field: #{w1} x #{w2} — conflict or last-writer-wins, never a silent drop",
         ctx do
      bad = doc_same_field(ctx.w1, ctx.w2, ctx)

      assert bad == [],
             "#{ctx.w1} x #{ctx.w2}: #{length(bad)}/#{@rounds} rounds:\n" <>
               Enum.map_join(Enum.take(bad, 3), "\n", &inspect/1)
    end
  end

  for w1 <- [:patch_rev, :replace_rev], w2 <- [:patch_rev, :replace_rev], w1 <= w2 do
    @tag w1: w1, w2: w2
    test "document, same field: #{w1} x #{w2} — the loser gets an explicit conflict", ctx do
      for n <- 1..@rounds do
        id = seed_doc!(false)

        [r1, r2] =
          race(
            doc_writer(ctx.w1, id, "a", "x#{n}", ctx),
            doc_writer(ctx.w2, id, "a", "y#{n}", ctx)
          )

        refute ok?(r1) and ok?(r2),
               "round #{n}: two writers fenced on the same rev both succeeded"
      end

      assert rev_fenced?(ctx.w1)
    end
  end

  # Whole-document replacers vs a merge writer on a DIFFERENT field: LWW on the
  # whole document by contract — assert the final state is COHERENT (each field
  # holds its seed or the value its writer sent), never a third value.
  for r <- @replacers, w <- @merge_writers -- [:beta] do
    @tag r: r, w: w
    test "document, whole-document replace: #{r} x #{w} — documented LWW, coherent", ctx do
      for n <- 1..@rounds do
        id = seed_doc!(false)

        [_r1, _r2] =
          race(doc_writer(ctx.r, id, "a", "a#{n}", ctx), doc_writer(ctx.w, id, "b", "b#{n}", ctx))

        c = doc!(id).content
        assert c["a"] in ["a0", "a#{n}"]
        assert c["b"] in ["b0", "b#{n}"]
      end
    end
  end

  # ── paper cells ───────────────────────────────────────────────────────────

  @paper_merge [:ops, :ops_rev, :batch]

  for w1 <- @paper_merge, w2 <- @paper_merge, w1 <= w2 do
    @tag w1: w1, w2: w2
    test "paper, different blocks: #{w1} x #{w2} — no accepted op is lost", ctx do
      losses =
        for n <- 1..@rounds, reduce: [] do
          acc ->
            slug = seed_paper!()

            [r1, r2] =
              race(
                paper_writer(ctx.w1, slug, "pa", "a#{n}"),
                paper_writer(ctx.w2, slug, "pb", "b#{n}")
              )

            lost =
              if(ok?(r1) and paper_text(slug, "pa") != "a#{n}", do: ["pa"], else: []) ++
                if(ok?(r2) and paper_text(slug, "pb") != "b#{n}", do: ["pb"], else: [])

            if lost == [], do: acc, else: [{n, lost, r1, r2} | acc]
        end

      assert losses == [],
             "#{ctx.w1} x #{ctx.w2}: #{length(losses)}/#{@rounds} rounds lost an accepted op:\n" <>
               Enum.map_join(Enum.take(losses, 3), "\n", &inspect(&1, limit: 8))
    end
  end

  for w1 <- @paper_merge ++ [:ingest], w2 <- @paper_merge ++ [:ingest], w1 <= w2 do
    @tag w1: w1, w2: w2
    test "paper, same block: #{w1} x #{w2} — conflict or last-writer-wins, never a silent drop",
         ctx do
      bad =
        for n <- 1..@rounds, reduce: [] do
          acc ->
            slug = seed_paper!()

            [r1, r2] =
              race(
                paper_writer(ctx.w1, slug, "pa", "x#{n}"),
                paper_writer(ctx.w2, slug, "pa", "y#{n}")
              )

            t = paper_text(slug, "pa")

            b =
              cond do
                t not in ["x#{n}", "y#{n}", "a0"] -> {:corrupt, t}
                ok?(r1) and ok?(r2) and t == "a0" -> {:both_dropped, t}
                ok?(r1) and not ok?(r2) and t != "x#{n}" -> {:silent_drop, t, r2}
                ok?(r2) and not ok?(r1) and t != "y#{n}" -> {:silent_drop, t, r1}
                true -> nil
              end

            if b, do: [{n, b} | acc], else: acc
        end

      assert bad == [],
             "#{ctx.w1} x #{ctx.w2}: #{length(bad)}/#{@rounds} rounds:\n" <>
               Enum.map_join(Enum.take(bad, 3), "\n", &inspect(&1, limit: 8))
    end
  end

  for w1 <- [:ops_rev, :batch], w2 <- [:ops_rev, :batch], w1 <= w2 do
    @tag w1: w1, w2: w2
    test "paper, same block: #{w1} x #{w2} — the loser gets an explicit conflict", ctx do
      for n <- 1..@rounds do
        slug = seed_paper!()

        [r1, r2] =
          race(
            paper_writer(ctx.w1, slug, "pa", "x#{n}"),
            paper_writer(ctx.w2, slug, "pa", "y#{n}")
          )

        refute ok?(r1) and ok?(r2),
               "round #{n}: two writers fenced on the same rev both succeeded"
      end
    end
  end

  # Ingest is a whole-paper upsert (documented): vs an op on ANOTHER block it is
  # LWW on the whole paper — coherent, never a third value.
  for w <- @paper_merge do
    @tag w: w
    test "paper, whole-paper ingest x #{w} — documented LWW, coherent", ctx do
      for n <- 1..@rounds do
        slug = seed_paper!()
        race(paper_writer(:ingest, slug, "pa", "a#{n}"), paper_writer(ctx.w, slug, "pb", "b#{n}"))
        assert paper_text(slug, "pa") in ["a0", "a#{n}"]
        assert paper_text(slug, "pb") in ["b0", "b#{n}"]
      end
    end
  end
end
