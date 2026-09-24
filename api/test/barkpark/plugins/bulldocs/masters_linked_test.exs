defmodule Barkpark.Plugins.Bulldocs.MastersLinkedTest do
  # Linked paper-master instances (task-59f078a2fd248698): a `master-ref`
  # block resolved at READ time, inside the instance paper's tenant, batched,
  # cycle-safe; Detach / Pin op builders; the master delete refusal.
  #
  # async: false — the op path's idempotency store is a shared table (same
  # reason as masters_test.exs).
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Errors
  alias Barkpark.Plugins.Bulldocs.Masters
  alias Barkpark.PortableDoc.Render
  alias Barkpark.QueryCounter
  alias Barkpark.TenancyFixtures

  @dataset "production"

  @section %{
    "id" => "sec",
    "type" => "section",
    "blocks" => [
      %{"id" => "sec-h", "type" => "heading", "level" => 2, "text" => "Pricing"},
      %{"id" => "sec-p", "type" => "paragraph", "text" => "Master body copy"}
    ]
  }

  defp seed_paper!(blocks, scope) do
    slug = "linked-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})
      |> Map.merge(Map.new(scope, fn {k, v} -> {Atom.to_string(k), v} end))

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp scope_opts(%{workspace_id: ws, project_id: p}), do: [workspace_id: ws, project_id: p]

  defp reload(slug, paper), do: Content.get_paper(slug, @dataset, scope_opts(paper))

  defp ref(id, master, version \\ nil),
    do: %{"id" => id, "type" => "master-ref", "master" => master, "version" => version}

  defp request_id, do: Ecto.UUID.generate()

  # A master saved from a real paper (the editor's own door).
  defp master!(ctx, node \\ @section, title \\ "Pricing") do
    {slug, paper} =
      seed_paper!([node], workspace_id: ctx.ws.id, project_id: ctx.project.id)

    {:ok, master} =
      Masters.save_master(slug, node["id"], @dataset, [title: title] ++ scope_opts(paper))

    master
  end

  # A master whose node is written verbatim (lets a master hold a master-ref).
  defp raw_master!(scope, node, title) do
    {:ok, master} =
      Content.create_document(
        Masters.type_name(),
        %{"title" => title, "content" => %{"tier" => "widget", "node" => node}},
        @dataset,
        scope
      )

    master
  end

  defp edit_master!(master, node) do
    {:ok, edited} =
      Content.upsert_document(
        Masters.type_name(),
        %{
          "doc_id" => master.doc_id,
          "title" => master.title,
          "content" => Map.put(master.content, "node", node)
        },
        @dataset,
        scope_opts(master)
      )

    edited
  end

  defp render(paper, blocks, opts \\ []) do
    masters = Masters.render_map(paper, blocks, opts)
    Render.render_blocks(blocks, %{style: :article, masters: masters})
  end

  defp apply_op!(slug, paper, op) do
    assert {:ok, _receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request_id(),
               "test:linked",
               scope_opts(paper)
             )

    reload(slug, paper)
  end

  setup do
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    %{ws: ws, project: project}
  end

  describe "render at read time" do
    test "an instance renders the master's current content", ctx do
      master = master!(ctx)
      mid = Masters.master_id(master)
      blocks = [ref("r1", mid)]
      {_slug, paper} = seed_paper!(blocks, scope_opts(master))

      html = render(paper, blocks)
      assert html =~ ~s(<div class="bp-master-ref">)
      assert html =~ "Master body copy"
      refute html =~ "Master unavailable"
    end

    test "a master edit shows on the next render and never writes the instance paper", ctx do
      master = master!(ctx)
      blocks = [ref("r1", Masters.master_id(master))]
      {slug, paper} = seed_paper!(blocks, scope_opts(master))
      before = reload(slug, paper)

      assert render(before, blocks) =~ "Master body copy"

      edited_node =
        put_in(@section, ["blocks", Access.at(1), "text"], "Edited master copy")

      edit_master!(master, edited_node)

      after_edit = reload(slug, paper)
      html = render(after_edit, after_edit.content["blocks"])
      assert html =~ "Edited master copy"
      refute html =~ "Master body copy"

      # The instance document was never written: same row rev, same content.
      assert after_edit.rev == before.rev
      assert after_edit.content == before.content
    end

    test "a pinned instance stays on its version while an unpinned one follows", ctx do
      master = master!(ctx)
      mid = Masters.master_id(master)
      blocks = [ref("pinned", mid, master.rev), ref("latest", mid)]
      {_slug, paper} = seed_paper!(blocks, scope_opts(master))

      edit_master!(
        master,
        put_in(@section, ["blocks", Access.at(1), "text"], "Edited master copy")
      )

      [pinned, latest] = Enum.map(blocks, &render(paper, [&1]))
      assert pinned =~ "Master body copy"
      refute pinned =~ "Edited master copy"
      assert latest =~ "Edited master copy"
    end

    test "a caller that does not resolve masters renders the neutral placeholder" do
      html = Render.render_blocks([ref("r1", "paper_master-x")], %{style: :article})
      assert html =~ "bp-master-ref--pending"
      refute html =~ "paper_master-x"
    end
  end

  describe "tenancy" do
    test "a foreign-tenant master renders exactly like a missing one", ctx do
      master = master!(ctx)
      other_ws = TenancyFixtures.create_workspace!()
      other_project = TenancyFixtures.create_project!(other_ws)
      foreign_scope = [workspace_id: other_ws.id, project_id: other_project.id]

      # Same block id, so the ONLY difference between the two papers is whether
      # the referenced id exists (in another tenant) or not at all.
      foreign_blocks = [ref("r1", Masters.master_id(master))]
      missing_blocks = [ref("r1", "paper_master-does-not-exist")]
      {_s1, foreign_paper} = seed_paper!(foreign_blocks, foreign_scope)
      {_s2, missing_paper} = seed_paper!(missing_blocks, foreign_scope)

      foreign = render(foreign_paper, foreign_blocks)
      missing = render(missing_paper, missing_blocks)

      assert foreign =~ "Master unavailable"
      refute foreign =~ "Master body copy"
      refute foreign =~ Masters.master_id(master)
      assert foreign == missing
    end

    test "the public reader resolves only published master rows", ctx do
      # A master that exists only as a DRAFT (written through the generic
      # create door, not the editor's save, which publishes): authoring
      # resolves it, the public reader does not.
      scope = [workspace_id: ctx.ws.id, project_id: ctx.project.id]
      master = raw_master!(scope, @section, "Draft only")
      blocks = [ref("r1", Masters.master_id(master))]
      {_slug, paper} = seed_paper!(blocks, scope)

      assert render(paper, blocks) =~ "Master body copy"
      assert render(paper, blocks, published_only: true) =~ "Master unavailable"
    end

    test "save_master publishes: the public reader resolves it, a newer draft stays private",
         ctx do
      master = master!(ctx)
      mid = Masters.master_id(master)
      assert master.doc_id == mid
      blocks = [ref("r1", mid)]
      {_slug, paper} = seed_paper!(blocks, scope_opts(master))

      assert render(paper, blocks, published_only: true) =~ "Master body copy"

      edit_master!(master, put_in(@section, ["blocks", Access.at(1), "text"], "Draft edit"))

      assert render(paper, blocks) =~ "Draft edit"
      public = render(paper, blocks, published_only: true)
      assert public =~ "Master body copy"
      refute public =~ "Draft edit"
    end
  end

  describe "bounded reads" do
    test "N instances cost the same queries as one — batched per level", ctx do
      masters =
        for i <- 1..12 do
          raw_master!(
            [workspace_id: ctx.ws.id, project_id: ctx.project.id],
            %{"id" => "p#{i}", "type" => "paragraph", "text" => "Body #{i}"},
            "M#{i}"
          )
        end

      one = [ref("r0", Masters.master_id(hd(masters)))]

      many =
        masters
        |> Enum.with_index()
        |> Enum.map(fn {m, i} ->
          # every third instance pinned to a rev that is no longer current, so
          # the pinned-revision read runs too
          ref("r#{i}", Masters.master_id(m), if(rem(i, 3) == 0, do: "stale-#{i}", else: nil))
        end)

      scope = %{workspace_id: ctx.ws.id, project_id: ctx.project.id, dataset: @dataset}
      {one_map, one_count} = QueryCounter.count(fn -> Masters.render_map(scope, one) end)
      {many_map, many_count} = QueryCounter.count(fn -> Masters.render_map(scope, many) end)

      assert map_size(one_map) == 1
      # 8 unpinned resolve; the 4 pinned to an unknown rev are unavailable
      assert map_size(many_map) == 8
      assert one_count == 1
      assert many_count <= 2
    end

    # task-59be65118320fa0e item 2: instances NESTED in sections and columns
    # of the paper are in the same map, read in the same single batch.
    test "instances nested in sections and columns resolve in the same batch", ctx do
      masters =
        for i <- 1..6 do
          raw_master!(
            [workspace_id: ctx.ws.id, project_id: ctx.project.id],
            %{"id" => "n#{i}", "type" => "paragraph", "text" => "Nested body #{i}"},
            "N#{i}"
          )
        end

      [a, b, c, d, e, f] = Enum.map(masters, &Masters.master_id/1)

      blocks = [
        ref("top", a),
        %{"id" => "s1", "type" => "section", "blocks" => [ref("in-s1", b)]},
        %{
          "id" => "s2",
          "type" => "section",
          "blocks" => [%{"id" => "s3", "type" => "section", "blocks" => [ref("in-s3", c)]}]
        },
        %{
          "id" => "cols",
          "type" => "columns",
          "columns" => [[ref("in-c0", d)], [ref("in-c1", e)]]
        },
        %{"id" => "s4", "type" => "section", "blocks" => [ref("in-s4", f)]}
      ]

      scope = %{workspace_id: ctx.ws.id, project_id: ctx.project.id, dataset: @dataset}
      {map, count} = QueryCounter.count(fn -> Masters.render_map(scope, blocks) end)

      assert map_size(map) == 6
      assert count == 1
      # Sections (at any depth) walk with the map. A `columns` block composes
      # its children at compose time without render opts, so the renderer
      # itself shows them as the neutral placeholder (0010 §6); Studio's
      # columns editor renders each child through `paper_block_fields`, which
      # does carry the map.
      html = Render.render_blocks(blocks, %{style: :article, masters: map})
      for i <- [1, 2, 3, 6], do: assert(html =~ "Nested body #{i}")
    end

    test "a cycle between masters renders once and stops", ctx do
      scope = [workspace_id: ctx.ws.id, project_id: ctx.project.id]
      a = raw_master!(scope, %{"id" => "pa", "type" => "paragraph", "text" => "A body"}, "A")
      b = raw_master!(scope, ref("to-a", Masters.master_id(a)), "B")
      # A now holds B, and B holds A: A → B → A.
      a =
        edit_master!(a, %{
          "id" => "sa",
          "type" => "section",
          "blocks" => [
            %{"id" => "pa", "type" => "paragraph", "text" => "A body"},
            ref("to-b", Masters.master_id(b))
          ]
        })

      blocks = [ref("r1", Masters.master_id(a))]
      {_slug, paper} = seed_paper!(blocks, scope)

      html = render(paper, blocks)
      # A renders, B inside it renders, and A inside B is cut by the chain.
      assert length(String.split(html, "A body")) - 1 == 1
      assert html =~ "Master unavailable"
    end

    test "nesting past max_depth is not read and renders unavailable", ctx do
      scope = [workspace_id: ctx.ws.id, project_id: ctx.project.id]

      m4 =
        raw_master!(scope, %{"id" => "p4", "type" => "paragraph", "text" => "Level four"}, "M4")

      m3 = raw_master!(scope, section_with("L3", "Level three", Masters.master_id(m4)), "M3")
      m2 = raw_master!(scope, section_with("L2", "Level two", Masters.master_id(m3)), "M2")
      m1 = raw_master!(scope, section_with("L1", "Level one", Masters.master_id(m2)), "M1")

      blocks = [ref("r1", Masters.master_id(m1))]
      {_slug, paper} = seed_paper!(blocks, scope)

      {html, count} = QueryCounter.count(fn -> render(paper, blocks) end)
      assert Masters.Linked.max_depth() == 3
      assert html =~ "Level one"
      assert html =~ "Level two"
      assert html =~ "Level three"
      refute html =~ "Level four"
      assert html =~ "Master unavailable"
      assert count <= 2 * Masters.Linked.max_depth()
    end
  end

  defp section_with(id, text, child_master) do
    %{
      "id" => id,
      "type" => "section",
      "blocks" => [
        %{"id" => id <> "-p", "type" => "paragraph", "text" => text},
        ref(id <> "-ref", child_master)
      ]
    }
  end

  describe "linked insert, Detach and Pin" do
    test "linked_insert_op inserts a master-ref following latest, in scope only", ctx do
      master = master!(ctx)

      {slug, paper} =
        seed_paper!([%{"id" => "p", "type" => "paragraph", "text" => "x"}], scope_opts(master))

      assert {:ok, op} =
               Masters.linked_insert_op(paper, Masters.master_id(master), "p", request_id())

      fresh = apply_op!(slug, paper, op)
      [_p, inserted] = fresh.content["blocks"]
      assert inserted["type"] == "master-ref"
      assert inserted["master"] == Masters.master_id(master)
      assert inserted["version"] == nil

      other_ws = TenancyFixtures.create_workspace!()

      {_s, foreign} =
        seed_paper!([%{"id" => "p", "type" => "paragraph", "text" => "x"}],
          workspace_id: other_ws.id
        )

      assert {:error, :master_not_found} =
               Masters.linked_insert_op(foreign, Masters.master_id(master), nil, request_id())
    end

    test "Detach copies the shown content in and drops the reference", ctx do
      master = master!(ctx)
      mid = Masters.master_id(master)
      {slug, paper} = seed_paper!([ref("r1", mid)], scope_opts(master))

      assert {:ok, op} = Masters.detach_op(paper, "r1", request_id())
      assert op["op"] == "replace-block"
      detached = apply_op!(slug, paper, op)

      assert [copy] = detached.content["blocks"]
      assert copy["type"] == "section"
      assert copy["master"]["mode"] == "detached"
      assert copy["master"]["id"] == mid
      assert Enum.map(copy["blocks"], & &1["text"]) == ["Pricing", "Master body copy"]
      refute Enum.any?(Barkpark.PortableDoc.MasterRef.refs(detached.content["blocks"]))

      # Detached: a later master edit no longer reaches it.
      edit_master!(master, put_in(@section, ["blocks", Access.at(1), "text"], "Edited"))
      refute render(detached, detached.content["blocks"]) =~ "Edited"

      assert {:error, :not_linked} = Masters.detach_op(detached, copy["id"], request_id())
      assert {:error, :block_not_found} = Masters.detach_op(detached, "nope", request_id())
    end

    test "Pin freezes the instance to the master's current rev; Unpin follows latest", ctx do
      master = master!(ctx)
      mid = Masters.master_id(master)
      {slug, paper} = seed_paper!([ref("r1", mid)], scope_opts(master))

      assert {:ok, pin} = Masters.pin_op(paper, "r1", true)
      pinned = apply_op!(slug, paper, pin)
      assert [%{"version" => version}] = pinned.content["blocks"]
      assert version == master.rev

      edit_master!(master, put_in(@section, ["blocks", Access.at(1), "text"], "Edited"))
      assert render(pinned, pinned.content["blocks"]) =~ "Master body copy"

      assert {:ok, unpin} = Masters.pin_op(pinned, "r1", false)
      unpinned = apply_op!(slug, pinned, unpin)
      assert [%{"version" => nil}] = unpinned.content["blocks"]
      assert render(unpinned, unpinned.content["blocks"]) =~ "Edited"
    end
  end

  describe "master delete refusal" do
    test "deleting a master with live instances is refused 409 listing the instance ids", ctx do
      master = master!(ctx)
      mid = Masters.master_id(master)
      {slug_a, _} = seed_paper!([ref("r1", mid)], scope_opts(master))

      {slug_b, _} =
        seed_paper!(
          [%{"id" => "s", "type" => "section", "blocks" => [ref("nested", mid)]}],
          scope_opts(master)
        )

      # A paper in ANOTHER tenant naming the same id is not an instance: it can
      # never resolve this master, and its id must not leak into the refusal.
      other_ws = TenancyFixtures.create_workspace!()
      {slug_foreign, _} = seed_paper!([ref("r1", mid)], workspace_id: other_ws.id)

      assert {:error, {:halted, message} = reason} =
               Content.delete_document(
                 master.doc_id,
                 Masters.type_name(),
                 @dataset,
                 scope_opts(master)
               )

      assert %{status: 409, code: "halted"} = Errors.to_envelope({:error, reason})
      assert message =~ slug_a
      assert message =~ slug_b
      refute message =~ slug_foreign
      assert Masters.live_instances(master) == Enum.sort([slug_a, slug_b])
    end

    test "a master with no live instance deletes", ctx do
      master = master!(ctx)

      assert {:ok, _} =
               Content.delete_document(
                 master.doc_id,
                 Masters.type_name(),
                 @dataset,
                 scope_opts(master)
               )
    end
  end
end
