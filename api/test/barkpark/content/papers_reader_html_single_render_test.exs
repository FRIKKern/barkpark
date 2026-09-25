defmodule Barkpark.Content.PapersReaderHtmlSingleRenderTest do
  @moduledoc """
  `Content.Papers.reader_html/3` renders a blocks paper once per read
  (task-f967486732a5a366).

  `reader_source/3` renders the blocks to compare them with the stored
  `body_html` cache (`cache_provenance/4`). `reader_html/3` used to render the
  same blocks a second time. It now serves the first render whenever that
  render is the one it would make.

  The count comes from an Erlang trace session on `Render.render_blocks/2`,
  scoped to the process doing the read, so no other test's renders are
  counted and no mock is involved. Every count test also asserts the bytes
  equal the old second render: `Render.render_blocks/2` over the caller's
  `Labels.paper_render_opts/3`.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels, Papers}
  alias Barkpark.PortableDoc.Render

  @dataset "production"

  defp blocks do
    [
      %{"id" => "h1", "type" => "heading", "level" => 2, "text" => "A section"},
      %{"id" => "p1", "type" => "paragraph", "text" => "Canonical prose."},
      %{
        "id" => "p2",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Second paragraph."}]
      }
    ]
  end

  defp paper(content, scope \\ []) do
    %Document{
      doc_id: "single-render-#{System.unique_integer([:positive])}",
      dataset: @dataset,
      type: "paper",
      title: "T",
      workspace_id: scope[:workspace_id],
      project_id: scope[:project_id],
      content: content
    }
  end

  # What reader_html/3 returned before this change: its second render, made
  # with the caller's scope.
  defp old_second_render(%Document{content: content}, scope_opts) do
    Render.render_blocks(
      content["blocks"],
      Labels.paper_render_opts(@dataset, content["style"], scope_opts)
    )
  end

  defp provenance_render(%Document{} = paper) do
    scope = [workspace_id: paper.workspace_id, project_id: paper.project_id]

    Render.render_blocks(
      paper.content["blocks"],
      Labels.paper_render_opts(@dataset, paper.content["style"], scope)
    )
  end

  # Run `fun` in a fresh process traced for calls to Render.render_blocks/2 and
  # return {result, call_count}. The trace session is private to this call, so
  # concurrent tests neither add to nor read this count.
  defp count_renders(fun) do
    session = :trace.session_create(:render_count, self(), [])

    try do
      # A trace pattern only matches a LOADED module: with Render not yet
      # loaded it matches 0 functions and every count reads 0.
      Code.ensure_loaded!(Render)
      1 = :trace.function(session, {Render, :render_blocks, 2}, true, [])
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            :go -> send(parent, {:result, self(), fun.()})
          end
        end)

      # The traced read runs in its own process; it shares this test's sandbox
      # connection for the lookups reader_source/3 makes.
      Ecto.Adapters.SQL.Sandbox.allow(Barkpark.Repo, parent, pid)
      :trace.process(session, pid, true, [:call])
      send(pid, :go)

      result =
        receive do
          {:result, ^pid, value} -> value
        after
          10_000 -> flunk("traced read did not finish")
        end

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      end

      {result, drain_calls(pid, 0)}
    after
      :trace.session_destroy(session)
    end
  end

  defp drain_calls(pid, n) do
    receive do
      {:trace, ^pid, :call, {Render, :render_blocks, [_, _]}} -> drain_calls(pid, n + 1)
    after
      0 -> n
    end
  end

  describe "a blocks paper with a stored cache renders once per read" do
    test "lagging cache (stale): one render, bytes equal the old second render" do
      doc = paper(%{"blocks" => blocks(), "body_html" => "<p>lagging cache</p>"})

      {result, renders} = count_renders(fn -> Papers.reader_html(doc, @dataset, []) end)

      assert renders == 1
      assert {:ok, html} = result
      assert html =~ "Canonical prose."
      assert html == old_second_render(doc, [])
    end

    test "coherent cache: one render, bytes equal the old second render" do
      doc = paper(%{"blocks" => blocks(), "style" => "article"})

      doc = %{
        doc
        | content:
            Map.merge(doc.content, %{
              "body_html" => provenance_render(doc),
              "body_html_sv" => Render.body_html_render_version()
            })
      }

      {result, renders} = count_renders(fn -> Papers.reader_html(doc, @dataset, []) end)

      assert renders == 1
      assert {:ok, html} = result
      assert html == old_second_render(doc, [])
    end
  end

  test "no cache: reader_source renders nothing, so reader_html renders once" do
    doc = paper(%{"blocks" => blocks()})

    {result, renders} = count_renders(fn -> Papers.reader_html(doc, @dataset, []) end)

    assert renders == 1
    assert {:ok, html} = result
    assert html == old_second_render(doc, [])
  end

  test "reader_source/3 keeps its public {:blocks, blocks} contract" do
    doc = paper(%{"blocks" => blocks(), "body_html" => "<p>lagging cache</p>"})
    expected = blocks()
    assert {:blocks, ^expected} = Papers.reader_source(doc, @dataset, [])
  end

  describe "a resolver-dependent paper" do
    setup do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]
      referent_id = "single-render-referent-#{System.unique_integer([:positive])}"

      # Draft-only referent: the paper-scope render (published-only) shows the
      # raw id, a caller that declares `published_only: false` sees the title.
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => referent_id, "title" => "Draft Referent Title"},
          @dataset,
          scope
        )

      blocks = [
        %{"id" => "p1", "type" => "paragraph", "text" => "Intro."},
        %{
          "id" => "ref1",
          "type" => "field-reference",
          "name" => "related",
          "refType" => "post",
          "value" => referent_id
        }
      ]

      doc = paper(%{"blocks" => blocks, "body_html" => "<p>lagging cache</p>"}, scope)
      {:ok, scope: scope, doc: doc}
    end

    test "a caller in the paper's own scope reuses the provenance render",
         %{scope: scope, doc: doc} do
      {result, renders} = count_renders(fn -> Papers.reader_html(doc, @dataset, scope) end)

      assert renders == 1
      assert {:ok, html} = result
      assert html == old_second_render(doc, scope)
    end

    test "a caller whose resolver scope differs gets its own render, not the paper-scope bytes",
         %{scope: scope, doc: doc} do
      caller_scope = scope ++ [published_only: false]

      refute old_second_render(doc, caller_scope) == provenance_render(doc),
             "the two scopes must render different bytes, or this test proves nothing"

      {result, renders} =
        count_renders(fn -> Papers.reader_html(doc, @dataset, caller_scope) end)

      assert renders == 2
      assert {:ok, html} = result
      assert html =~ "Draft Referent Title"
      assert html == old_second_render(doc, caller_scope)
    end
  end
end
