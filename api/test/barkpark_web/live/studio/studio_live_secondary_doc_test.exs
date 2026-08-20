defmodule BarkparkWeb.Studio.StudioLiveSecondaryDocTest do
  @moduledoc """
  The secondary (split-view) pane is IDENTITY-SCOPED to the primary document
  it was opened beside (charter D175/D187/D199).

  Two legs, both load-bearing:

    1. NAV CLEARS — navigating the same LiveView (push_patch, no remount) to a
       DIFFERENT primary document clears secondary_doc/secondary_schema/
       secondary_type. Before the identity-gated clear, NO nav handler touched
       the trio, so a 360px `.bp-secondary-pane` survived into the paper
       reader, shrank `.editor-panel` to 620px at standard/1024 and let the
       @container scrim paint over live prose.

    2. SAME-DOC RELOAD PRESERVES (regression guard, D199) — a same-document
       reload ("reload-remote-doc", the Save/"Saved" rebuild path) with a
       split view open KEEPS the secondary pane. This is the regression an
       UNCONDITIONAL clear inside clear_paper_view/1 / setup_paper_view/2
       would introduce: rebuild_panes' `_ ->` branch calls clear_paper_view/1
       on every same-doc save, not only on nav.

  Assigns are read via :sys.get_state(view.pid) because the trio is state,
  not markup — the rendered pane is covered elsewhere; this test pins the
  LiveView contract itself.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @paper_slug "2026-07-21-secondary-doc-paper"

  setup %{conn: conn} do
    # Two `post` documents: p1 is the primary, p2 becomes the secondary
    # (select-secondary lists same-type candidates only).
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "p1", "title" => "Post One", "content" => %{"body" => "aaa"}},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "p2", "title" => "Post Two", "content" => %{"body" => "bbb"}},
        @dataset
      )

    # A paper as the DIFFERENT primary document for the nav leg — the exact
    # shape of the D187 compound state (split view carried into the reader).
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @paper_slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "b-intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Reader prose."}]
            }
          ]
        })
      )

    {:ok, conn: conn}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_split_view!(view) do
    # Drive the REAL handlers: picker open, then selection — the only code
    # path that sets the trio (handlers/secondary.ex).
    render_click(view, "open-secondary-picker", %{})
    render_click(view, "select-secondary", %{"id" => "p2"})

    a = assigns(view)
    assert a.secondary_doc, "select-secondary must set secondary_doc (harness broken otherwise)"
    assert Content.published_id(a.secondary_doc.doc_id) == "p2"
    assert a.secondary_type == "post"
    a
  end

  test "navigating to a DIFFERENT primary document clears the secondary pane", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
    assert html =~ ~s(id="editor-form")

    open_split_view!(view)

    # Same LiveView, push_patch — no remount, so mount's nil seed never runs.
    render_patch(view, scoped_studio("/d/#{@dataset}/studio/paper/#{@paper_slug}"))

    a = assigns(view)

    # Non-vacuity (D192): the nav actually landed on the paper — the primary
    # document changed identity for real.
    assert a.paper_doc,
           "nav must reach the paper (paper_doc set) or the clear was never exercised"

    assert a.paper_doc.doc_id == @paper_slug

    # The identity change cleared the whole trio.
    assert a.secondary_doc == nil
    assert a.secondary_schema == nil
    assert a.secondary_type == nil
  end

  test "a same-document reload with a split view open PRESERVES the secondary pane (D199)",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
    assert html =~ ~s(id="editor-form")

    open_split_view!(view)

    # Same doc_id through rebuild_panes — the Save/"Saved" reload leg. An
    # unconditional clear in clear_paper_view/1 (rebuild_panes' `_ ->` branch)
    # wipes the pane right here; the identity gate must not.
    render_click(view, "reload-remote-doc", %{})

    a = assigns(view)

    # Non-vacuity: the rebuild ran against the SAME primary document.
    assert a.editor_doc, "reload must keep the primary doc loaded"
    assert Content.published_id(a.editor_doc.doc_id) == "p1"

    # The split view survived the same-doc rebuild.
    assert a.secondary_doc, "same-doc reload must NOT wipe a live secondary pane"
    assert Content.published_id(a.secondary_doc.doc_id) == "p2"
    assert a.secondary_type == "post"
  end
end
