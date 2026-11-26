defmodule BarkparkWeb.Studio.PaperFrameLeaveHoldTest do
  @moduledoc """
  task-bb212404529d765c: under the leave question (`LeaveScope.moved?/1`: the
  question is open and the held paper sits outside the socket's current
  project), P1's own paper frames pass the project fence, but every re-read
  they trigger (`refetch_paper/1`, `sync_paper_edit_doc/1`) runs in the
  socket's new P2 scope and found P2's same-slug paper. The frames are now held
  until Stay or Leave, as #28976 holds reads.

  The leave state is set on the socket directly (`studio_leave`, an unsaved
  key, `current_project` P2): that is the state a Back into P2 over held
  fields leaves (`studio_leave_scope_test.exs` drives the real path for posts).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.LeaveScope

  @dataset "pflh-#{System.unique_integer([:positive])}"

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
    {:ok, ws: ws, p1: p1, p2: p2, slug: "pflh-#{System.unique_integer([:positive])}"}
  end

  defp paper!(c, p, text) do
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
  end

  defp block(id, text),
    do: %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    }

  defp op!(c, p, id, text),
    do:
      {:ok, _} =
        Content.apply_paper_block_op(c.slug, block(id, text), @dataset,
          workspace_id: c.ws.id,
          project_id: p.id
        )

  defp batch!(c, p, id, text),
    do:
      {:ok, _} =
        Content.apply_paper_block_ops(c.slug, [block(id, text)], @dataset,
          workspace_id: c.ws.id,
          project_id: p.id
        )

  defp open!(conn, c) do
    paper!(c, c.p1, "P1 words")
    paper!(c, c.p2, "P2 words")

    {:ok, view, html} =
      live(conn, "/w/#{c.ws.slug}/p/#{c.p1.slug}/d/#{@dataset}/studio/paper/#{c.slug}")

    assert html =~ "P1 words"
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The state a Back into P2 over held fields leaves.
  defp move!(view, c) do
    p2 = Barkpark.Repo.get!(Barkpark.Tenancy.Project, c.p2.id)
    to = "/w/#{c.ws.slug}/p/#{c.p2.slug}/d/#{@dataset}/studio/paper/#{c.slug}"

    :sys.replace_state(view.pid, fn st ->
      assigns =
        st.socket.assigns
        |> Map.put(:studio_leave, %{to: to, kind: "patch"})
        |> Map.put(:editor_unsaved_keys, MapSet.new(["title"]))
        |> Map.put(:current_project, p2)

      %{st | socket: %{st.socket | assigns: assigns}}
    end)

    assert LeaveScope.moved?(assigns(view))
  end

  defp settle(view) do
    _ = :sys.get_state(view.pid)
    Process.sleep(150)
    render(view)
  end

  for {label, write} <- [
        {"a block op", :op},
        {"a batch", :batch},
        {"a whole-paper write", :whole}
      ] do
    test "under the leave question, P1's own #{label} never shows P2's paper",
         %{conn: conn} = c do
      view = open!(conn, c)
      move!(view, c)

      case unquote(write) do
        :op -> op!(c, c.p1, "b-p1", "P1 later")
        :batch -> batch!(c, c.p1, "b-p1", "P1 later")
        :whole -> paper!(c, c.p1, "P1 later")
      end

      out = settle(view)

      refute out =~ "P2 words"
      assert out =~ "P1 words"
      assert assigns(view).paper_doc.project_id == c.p1.id
    end
  end

  test "control: not under the leave question, P1's own op still repaints", %{conn: conn} = c do
    view = open!(conn, c)

    op!(c, c.p1, "b-p1", "P1 later")

    assert settle(view) =~ "P1 later"
    assert assigns(view).paper_doc.project_id == c.p1.id
  end
end
