defmodule BarkparkWeb.Studio.PaperFrameProjectFenceTest do
  @moduledoc """
  task-62ff63f43817eb08: the paper topic names the workspace, the dataset and
  the slug, not the project, and paper slugs are per project. A write to P2's
  paper of the same slug reached a Studio socket holding P1's and repainted
  it with P2's body. Each paper frame now names its project, and Studio drops
  another project's.

  The fence only holds if every frame names its project (a frame naming none
  is not judged), so the last describe pins that every paper frame in `lib/`
  is built in the one helper pair that stamps it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "ppf-#{System.unique_integer([:positive])}"

  setup do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      if prev_canvas, do: System.put_env("BARKPARK_PAPER_CANVAS", prev_canvas)
    end)

    {ws, p1} = Barkpark.TenancyFixtures.ensure_default_scope!()
    p2 = Barkpark.TenancyFixtures.create_project!(ws)

    for p <- [p1, p2] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset,
          workspace_id: ws.id,
          project_id: p.id
        )
    end

    Barkpark.LabelFixtures.register_tags!(@dataset)
    {:ok, ws: ws, p1: p1, p2: p2, slug: "ppf-same-#{System.unique_integer([:positive])}"}
  end

  defp html_paper!(c, p, body) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => c.slug,
          "title" => "T",
          "dataset" => @dataset,
          "body_html" => body,
          "workspace_id" => c.ws.id,
          "project_id" => p.id
        })
      )

    assert doc.project_id == p.id
    doc
  end

  defp blocks_paper!(c, p, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => c.slug,
          "title" => "T",
          "dataset" => @dataset,
          "workspace_id" => c.ws.id,
          "project_id" => p.id,
          "blocks" => [
            %{"id" => "h-1", "type" => "heading", "text" => "Title"},
            %{
              "id" => "b-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ]
        })
      )

    assert doc.project_id == p.id
    doc
  end

  defp append!(c, p, id, text) do
    op = %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    }

    {:ok, _} =
      Content.apply_paper_block_op(c.slug, op, @dataset, workspace_id: c.ws.id, project_id: p.id)
  end

  defp open!(conn, c) do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{c.slug}"))
    {view, html}
  end

  defp settle(view) do
    _ = :sys.get_state(view.pid)
    Process.sleep(150)
    render(view)
  end

  describe "a Studio socket holding P1's paper" do
    test "P2's same-slug whole-paper write does not repaint it", %{conn: conn} = c do
      html_paper!(c, c.p1, "<p>P1-BODY</p>")
      html_paper!(c, c.p2, "<p>P2-BODY</p>")
      {view, html} = open!(conn, c)
      assert html =~ "P1-BODY"

      html_paper!(c, c.p2, "<p>P2-BODY-V2</p>")
      out = settle(view)

      assert out =~ "P1-BODY"
      refute out =~ "P2-BODY"
    end

    test "P2's same-slug block write does not reach it", %{conn: conn} = c do
      blocks_paper!(c, c.p1, "P1 words")
      blocks_paper!(c, c.p2, "P2 words")
      {view, html} = open!(conn, c)
      assert html =~ "P1 words"

      append!(c, c.p2, "b-p2", "P2 streamed")
      out = settle(view)

      assert out =~ "P1 words"
      refute out =~ "P2 streamed"
    end

    test "control: P1's own writes from another process still repaint it", %{conn: conn} = c do
      blocks_paper!(c, c.p1, "P1 words")
      blocks_paper!(c, c.p2, "P2 words")
      {view, _html} = open!(conn, c)

      append!(c, c.p1, "b-p1", "P1 streamed")
      assert settle(view) =~ "P1 streamed"
    end
  end

  describe "the /papers reader holding P1's paper" do
    setup c do
      ds = Content.paper_default_dataset()

      for p <- [c.p1, c.p2] do
        {:ok, _} =
          Content.upsert_schema(
            %{
              "name" => "paper",
              "title" => "Papers",
              "visibility" => "public",
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            ds,
            workspace_id: c.ws.id,
            project_id: p.id
          )
      end

      Barkpark.LabelFixtures.register_tags!(ds)
      {:ok, ds: ds}
    end

    defp reader_paper!(c, p, text) do
      {:ok, doc} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => c.slug,
            "title" => "T",
            "dataset" => c.ds,
            "workspace_id" => c.ws.id,
            "project_id" => p.id,
            "blocks" => [
              %{"id" => "h-1", "type" => "heading", "text" => "Title"},
              %{
                "id" => "b-1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => text}]
              }
            ]
          })
        )

      assert doc.project_id == p.id
    end

    defp reader_append!(c, p, id, text) do
      op = %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }

      {:ok, _} =
        Content.apply_paper_block_op(c.slug, op, c.ds, workspace_id: c.ws.id, project_id: p.id)
    end

    defp reader!(conn, c) do
      reader_paper!(c, c.p1, "P1 words")
      {:ok, view, html} = live(conn, "/papers/#{c.slug}")
      assert html =~ "P1 words"
      assert :sys.get_state(view.pid).socket.assigns.paper_project_id == c.p1.id
      reader_paper!(c, c.p2, "P2 words")
      _ = settle(view)
      view
    end

    test "P2's same-slug block write does not paint into it", %{conn: conn} = c do
      view = reader!(conn, c)

      reader_append!(c, c.p2, "b-p2", "P2 streamed")
      out = settle(view)

      assert out =~ "P1 words"
      refute out =~ "P2 streamed"
    end

    test "control: P1's own block write still streams into it", %{conn: conn} = c do
      view = reader!(conn, c)

      reader_append!(c, c.p1, "b-p1", "P1 streamed")
      assert settle(view) =~ "P1 streamed"
    end
  end

  describe "every paper frame names its project" do
    test "both frames carry the written row's project_id", c do
      blocks_paper!(c, c.p2, "P2 words")
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(c.slug, c.ws.id, @dataset))

      append!(c, c.p2, "b-p2", "P2 streamed")
      blocks_paper!(c, c.p2, "P2 again")

      p2 = c.p2.id
      assert_receive {:paper_block, %{project_id: ^p2}}, 1_000
      assert_receive {:paper_updated, %{project_id: ^p2}}, 1_000
    end

    # A frame naming no project is not judged by the fence, so a broadcaster
    # that builds its own frame would reopen the repaint. Every paper frame
    # in lib/ is built in BlockOps' two helpers, which stamp the project.
    test "paper frames are built only in BlockOps' broadcast helpers" do
      builds =
        for path <- Path.wildcard("lib/**/*.ex"),
            {line, n} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
            line =~ ~r/\{:paper_(block|updated),/,
            not (line =~ ~r/^\s*#|def handle_info|`/),
            do: {path, n, String.trim(line)}

      assert [
               {"lib/barkpark/content/papers/block_ops.ex", _, "{:paper_updated,"},
               {"lib/barkpark/content/papers/block_ops.ex", _, "{:paper_block," <> _}
             ] = builds

      src = File.read!("lib/barkpark/content/papers/block_ops.ex")
      assert src =~ "project_id: doc.project_id,"

      assert src =~
               "{:paper_block, Map.merge(frame, %{sender: self(), project_id: doc.project_id})}"
    end
  end
end
