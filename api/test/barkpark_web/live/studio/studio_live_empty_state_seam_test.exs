defmodule BarkparkWeb.Studio.StudioLiveEmptyStateSeamTest do
  @moduledoc """
  spd-w19 — the third seam, proven on the REAL render path.

  The component-level file (`test/barkpark_web/studio/editor_empty_state_seam_test.exs`)
  proves the derivation and the markup. This one proves the WIRING: that a real
  Studio mount whose URL names a document that does not resolve puts the named
  state in the SERVER HTML, and that `"Select a document to edit"` is no longer
  reachable there.

  This is the mutation tripwire for the fill itself: delete the `<:empty_state>`
  block at the `studio_editor_shell` call site and the shell falls back to its
  declared default, so `refute html =~ "Select a document to edit"` reds by name.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws = Tenancy.get_default_workspace()

    raw = "spdw19-empty-state-" <> Ecto.UUID.generate()
    {:ok, _token} = Auth.create_token(raw, "spdw19", @dataset, ["read", "write"], ws.id)

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  test "a URL naming a non-existent document answers with its id, type and reason", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/spdw19-ghost"))

    assert html =~ ~s(data-test-id="studio-unresolved-document-notice"),
           "the declared-and-never-filled <:empty_state> slot must be filled on this path"

    assert html =~ ~s(role="alert")
    assert html =~ ~s(aria-live="assertive")
    assert html =~ ~s(data-reason="not_found")
    assert html =~ ~s(data-doc-id="spdw19-ghost")
    assert html =~ ~s(data-doc-type="post")
    assert html =~ "spdw19-ghost"

    # A named way out, natively tabbable (no tabindex on the anchor — that would
    # remove the only control from the tab order), and its href is a real Studio
    # path. The tabindex="-1" landmark is the notice container itself (D269).
    assert html =~ ~s(data-test-id="studio-unresolved-recovery")
    assert html =~ "/d/#{@dataset}/studio/post"

    recovery =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test-id="studio-unresolved-recovery"]))

    assert LazyHTML.attribute(recovery, "tabindex") == [],
           "the way out must stay in the tab order on a real mounted desk"

    refute html =~ "Select a document to edit",
           "THE OWNER'S COMPLAINT: a document that was named must never be answered with a shrug"
  end

  # The mutation tripwire, kept as its OWN test with the refute FIRST: delete the
  # `<:empty_state>` fill and this reds quoting the default string by name,
  # instead of reporting whichever assertion happened to sit above it.
  test "the default shrug cannot reach a viewer who named a document", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/spdw19-ghost"))

    refute html =~ "Select a document to edit"
  end

  test "a URL naming no desk node at all says so, and names the segment", %{conn: conn} do
    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/spdw19RetiredNode/some-id"))

    assert html =~ ~s(data-test-id="studio-unresolved-document-notice")
    assert html =~ ~s(data-reason="unknown_node")
    assert html =~ "spdw19RetiredNode"
    refute html =~ "Select a document to edit"
  end

  test "the desk root with nothing selected stays calm — and still does not shrug", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    assert html =~ ~s(data-test-id="studio-editor-nothing-selected")
    refute html =~ "Select a document to edit"
  end

  test "a document that DOES resolve renders the editor, not the notice", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "spdw19-real", "title" => "Real Post"},
        @dataset,
        source: :studio
      )

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/spdw19-real"))

    refute html =~ ~s(data-test-id="studio-unresolved-document-notice"),
           "the notice must not fire on a document that opened"

    assert html =~ "Real Post"
  end
end
