defmodule BarkparkWeb.Studio.DeskDiscardProjectFenceTest do
  @moduledoc """
  task-097dbe962f85eff0: the desk reads another session's discard of the open
  draft as its own frame (`Desk.Discarded.frame?/2`). It matched type and id
  only, and the doc topic does not tell a sibling project's same-id document
  apart: a discard in P2 reloaded A's P1 editor and dropped A's held words,
  with a "draft discarded" line, with no leave question open at all.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.ObjectRichText

  @ds "production"

  defp schema!(opts) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @ds,
        opts
      )
  end

  setup do
    ws = create_workspace!("lsc-#{System.unique_integer([:positive])}")
    p1 = create_project!(ws, "lsc-one")
    p2 = create_project!(ws, "lsc-two")

    for {p, id} <- [{p1, "kept-doc"}, {p2, "other-doc"}] do
      opts = [workspace_id: ws.id, project_id: p.id]
      schema!(opts)

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => "T0", "content" => %{"notes" => "one two three"}},
          @ds,
          opts
        )
    end

    conn = fn ->
      raw = "lsc-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(raw, "lsc", @ds, ~w(read write admin), ws.id)
      Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})
    end

    {:ok, ws: ws, p1: p1, p2: p2, conn: conn, base: "/w/#{ws.slug}/p/"}
  end

  defp at(c, :desk, :one), do: c.base <> "lsc-one/d/#{@ds}/studio/_desk/post;kept-doc"

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp posts(view, title, notes, target) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => title, "notes" => notes},
      "_bp_seen" => Jason.encode!(%{"v" => 2})
    })
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A holds the notes of P1's kept-doc against B; P2 has its own kept-doc,
  # published, with a draft.
  defp held(c) do
    a = open(c.conn.(), at(c, :desk, :one))
    b = open(c.conn.(), at(c, :desk, :one))

    ObjectRichText.inside(a, fn -> posts(b, "T0", "one twB three", "doc[notes]") end, fn ->
      posts(a, "T0", "one twA three", "doc[notes]")
    end)

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{
          "doc_id" => "drafts.kept-doc",
          "title" => "P2-DRAFT",
          "content" => %{"notes" => "p2 draft"}
        },
        @ds,
        workspace_id: c.ws.id,
        project_id: c.p2.id
      )

    _ = render(a)
    assert assigns(a).editor_form["notes"] == "one twA three"
    a
  end

  defp settle(a) do
    _ = :sys.get_state(a.pid)
    Process.sleep(200)
    render(a)
  end

  test "a discard of P2's same-id draft leaves A's P1 editor and held words alone", c do
    a = held(c)

    {:ok, _} =
      Content.discard_draft("kept-doc", "post", @ds, workspace_id: c.ws.id, project_id: c.p2.id)

    _ = settle(a)

    %{editor_doc: doc, editor_form: form} = x = assigns(a)
    assert {doc.doc_id, doc.project_id} == {"drafts.kept-doc", c.p1.id}
    assert form["notes"] == "one twA three"
    assert x.editor_dirty
    assert x[:desk_discarded] == nil
  end

  test "control: a discard of A's own P1 draft by someone else still reloads with the line", c do
    a = held(c)

    {:ok, _} =
      Content.discard_draft("kept-doc", "post", @ds, workspace_id: c.ws.id, project_id: c.p1.id)

    _ = settle(a)

    assert %{doc: {"post", "kept-doc"}} = assigns(a)[:desk_discarded]
  end
end
