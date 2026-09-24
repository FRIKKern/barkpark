defmodule Barkpark.Plugins.Bulldocs.MastersTest do
  # async: false — the op path's idempotency store is a shared table, and the
  # sibling op tests in test/barkpark/content/papers run synchronously for it.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Labels
  alias Barkpark.Plugins.Bulldocs.Masters
  alias Barkpark.PortableDoc.Render
  alias Barkpark.TenancyFixtures

  @dataset "production"

  @section %{
    "id" => "sec",
    "type" => "section",
    "blocks" => [
      %{"id" => "sec-h", "type" => "heading", "level" => 2, "text" => "Pricing"},
      %{"id" => "sec-p", "type" => "paragraph", "text" => "Master body copy"},
      %{
        "id" => "sec-c",
        "type" => "callout",
        "tone" => "info",
        "content" => [%{"type" => "text", "value" => "Master callout"}]
      }
    ]
  }

  defp seed_paper!(blocks, scope) do
    slug = "paper-master-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})
      |> Map.merge(Map.new(scope, fn {k, v} -> {Atom.to_string(k), v} end))

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp scope_opts(paper), do: [workspace_id: paper.workspace_id, project_id: paper.project_id]

  defp reload(slug, paper), do: Content.get_paper(slug, @dataset, scope_opts(paper))

  defp strip_ids(%{} = map),
    do: map |> Map.delete("id") |> Map.new(fn {k, v} -> {k, strip_ids(v)} end)

  defp strip_ids(list) when is_list(list), do: Enum.map(list, &strip_ids/1)
  defp strip_ids(other), do: other

  defp ids(%{} = map) do
    own = if is_binary(map["id"]), do: [map["id"]], else: []
    own ++ Enum.flat_map(Map.values(map), &ids/1)
  end

  defp ids(list) when is_list(list), do: Enum.flat_map(list, &ids/1)
  defp ids(_), do: []

  setup do
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    %{ws: ws, project: project}
  end

  describe "save_master/4" do
    test "stores the node as its own paper_master document in the paper's scope", ctx do
      {slug, paper} =
        seed_paper!([%{"id" => "lead", "type" => "paragraph", "text" => "Lead"}, @section],
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id
        )

      assert {:ok, master} =
               Masters.save_master(slug, "sec", @dataset, [title: "Pricing"] ++ scope_opts(paper))

      assert master.type == "paper_master"
      assert master.title == "Pricing"
      assert master.workspace_id == ctx.ws.id
      assert master.project_id == ctx.project.id
      assert master.dataset == @dataset
      assert master.content["tier"] == "section"
      assert master.content["block_type"] == "section"
      assert master.content["source_paper"] == slug
      assert master.content["source_block_id"] == "sec"
      assert master.content["node"] == @section
      assert is_binary(master.rev)

      assert [listed] = Masters.list_masters(@dataset, scope_opts(paper))
      assert listed.id == master.id
    end

    test "saves a nested element and a widget, refuses locked and unknown nodes", ctx do
      {slug, paper} =
        seed_paper!([@section], workspace_id: ctx.ws.id, project_id: ctx.project.id)

      opts = scope_opts(paper)
      assert {:ok, el} = Masters.save_master(slug, "sec-p", @dataset, opts)
      assert el.content["tier"] == "element"
      assert {:ok, w} = Masters.save_master(slug, "sec-c", @dataset, opts)
      assert w.content["tier"] == "widget"
      assert {:error, :block_not_found} = Masters.save_master(slug, "nope", @dataset, opts)

      assert {:error, :paper_not_found} =
               Masters.save_master("no-such-paper", "sec", @dataset, opts)

      {tslug, tpaper} =
        seed_paper!(
          [
            %{
              "id" => "t",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "locked" => true,
              "text" => "T"
            },
            %{"id" => "b", "type" => "field-string", "fieldName" => "subtitle", "value" => "x"}
          ],
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id
        )

      assert {:error, :locked_block} =
               Masters.save_master(tslug, "t", @dataset, scope_opts(tpaper))

      assert {:error, :bound_field} =
               Masters.save_master(tslug, "b", @dataset, scope_opts(tpaper))
    end
  end

  describe "insert_detached/7" do
    test "round-trip: the inserted node equals the source with fresh ids and provenance", ctx do
      {src_slug, src} =
        seed_paper!([@section], workspace_id: ctx.ws.id, project_id: ctx.project.id)

      {:ok, master} = Masters.save_master(src_slug, "sec", @dataset, scope_opts(src))

      {slug, paper} =
        seed_paper!([%{"id" => "anchor", "type" => "paragraph", "text" => "Anchor"}],
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id
        )

      assert {:ok, receipt, :applied} =
               Masters.insert_detached(
                 slug,
                 Masters.master_id(master),
                 "anchor",
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:master-roundtrip",
                 [if_rev: paper.content["rev"] || 0] ++ scope_opts(paper)
               )

      stored = reload(slug, paper)
      assert [%{"id" => "anchor"}, inserted] = stored.content["blocks"]
      assert receipt.block_ids == [inserted["id"]]

      # Equal to the source once ids and provenance are set aside …
      assert strip_ids(Map.delete(inserted, "master")) == strip_ids(@section)
      # … every id is fresh (none reused from the source, none repeated) …
      copy_ids = ids(Map.delete(inserted, "master"))
      assert length(copy_ids) == length(ids(@section))
      assert MapSet.disjoint?(MapSet.new(copy_ids), MapSet.new(ids(@section)))
      assert length(Enum.uniq(copy_ids)) == length(copy_ids)
      # … and the copy names the master and revision it came from.
      assert inserted["master"] == %{
               "id" => Masters.master_id(master),
               "rev" => master.rev,
               "mode" => "detached"
             }

      # Detached: the source paper is untouched.
      assert reload(src_slug, src).content["blocks"] == [@section]
    end

    test "render: the inserted copy renders like the source into the stored body_html", ctx do
      {src_slug, src} =
        seed_paper!([@section], workspace_id: ctx.ws.id, project_id: ctx.project.id)

      {:ok, master} = Masters.save_master(src_slug, "sec", @dataset, scope_opts(src))

      {slug, paper} =
        seed_paper!([%{"id" => "anchor", "type" => "paragraph", "text" => "Anchor"}],
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id
        )

      assert {:ok, _receipt, :applied} =
               Masters.insert_detached(
                 slug,
                 Masters.master_id(master),
                 nil,
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:master-render",
                 [if_rev: paper.content["rev"] || 0] ++ scope_opts(paper)
               )

      stored = reload(slug, paper)
      html = stored.content["body_html"]
      inserted = List.last(stored.content["blocks"])

      assert html =~ "Pricing"
      assert html =~ "Master body copy"
      assert html =~ "Master callout"
      # The stored cache is exactly the paper's own render of its block list …
      render_opts =
        Labels.paper_render_opts(@dataset, stored.content["style"],
          workspace_id: stored.workspace_id,
          project_id: stored.project_id
        )

      assert html == Render.render_blocks(stored.content["blocks"], render_opts)
      fragment = Render.render_block(inserted, render_opts)
      assert html =~ fragment

      # … and the copy renders exactly like the source node (ids aligned):
      # provenance adds nothing to the rendered surface.
      assert fragment == Render.render_block(Map.delete(inserted, "master"), render_opts)
      assert fragment == Render.render_block(align_ids(@section, inserted), render_opts)
    end

    test "a retried insert replays its receipt and inserts exactly once", ctx do
      {src_slug, src} =
        seed_paper!([@section], workspace_id: ctx.ws.id, project_id: ctx.project.id)

      {:ok, master} = Masters.save_master(src_slug, "sec-p", @dataset, scope_opts(src))

      {slug, paper} =
        seed_paper!([%{"id" => "anchor", "type" => "paragraph", "text" => "Anchor"}],
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id
        )

      request_id = Ecto.UUID.generate()
      opts = [if_rev: paper.content["rev"] || 0] ++ scope_opts(paper)

      call = fn ->
        Masters.insert_detached(
          slug,
          Masters.master_id(master),
          "anchor",
          @dataset,
          request_id,
          "user:master-retry",
          opts
        )
      end

      assert {:ok, receipt, :applied} = call.()
      assert {:ok, ^receipt, :replayed} = call.()

      blocks = reload(slug, paper).content["blocks"]
      assert length(blocks) == 2
      assert Enum.count(blocks, &(get_in(&1, ["master", "id"]) == Masters.master_id(master))) == 1
      assert reload(slug, paper).content["rev"] == receipt.rev
    end

    test "tenancy: a master from another workspace is refused and the paper is unchanged",
         ctx do
      other_ws = TenancyFixtures.create_workspace!()
      other_project = TenancyFixtures.create_project!(other_ws)

      {src_slug, src} =
        seed_paper!([@section], workspace_id: other_ws.id, project_id: other_project.id)

      {:ok, foreign} = Masters.save_master(src_slug, "sec", @dataset, scope_opts(src))
      assert foreign.workspace_id == other_ws.id

      {slug, paper} =
        seed_paper!([%{"id" => "anchor", "type" => "paragraph", "text" => "Anchor"}],
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id
        )

      assert {:error, :master_not_found} =
               Masters.insert_detached(
                 slug,
                 Masters.master_id(foreign),
                 "anchor",
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:master-tenant",
                 [if_rev: paper.content["rev"] || 0] ++ scope_opts(paper)
               )

      stored = reload(slug, paper)
      assert stored.content["blocks"] == paper.content["blocks"]
      assert stored.content["rev"] == paper.content["rev"]
      assert Masters.list_masters(@dataset, scope_opts(paper)) == []
    end
  end

  # Give `source` the ids `copy` carries, position by position.
  defp align_ids(%{} = source, %{} = copy) do
    source
    |> Map.new(fn
      {"id", _} -> {"id", copy["id"]}
      {k, v} -> {k, align_ids(v, Map.get(copy, k))}
    end)
  end

  defp align_ids(source, copy) when is_list(source) and is_list(copy),
    do: Enum.zip_with(source, copy, &align_ids/2)

  defp align_ids(source, _copy), do: source
end
