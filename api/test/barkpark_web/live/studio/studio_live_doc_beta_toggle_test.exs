defmodule BarkparkWeb.Studio.StudioLiveDocBetaToggleTest do
  @moduledoc """
  Exp-P3.2 (barkpark-g2ql) — the per-document Classic ⇄ Beta toggle.

  The capstone of Portable Doc + Expectations: an Expectation-bearing document
  (a `post`) opens in the Studio editor with a visible Classic ⇄ Beta switch.

    * Classic view = the existing schema form (reads projected content[fieldName]).
    * Beta view    = the premium block editor (the SAME `paper_block_editor`
      reused) over the doc's content["blocks"].

  Proven here, driving the real LiveView through Content + the toggle:

    1. The editor mounts in Classic with the toggle visible; clicking Beta
       renders the block editor over the post's blocks (synthesize if absent).
    2. Flipping Classic↔Beta does NOT mutate content["blocks"] (lossless).
    3. A Beta op (patch-block from the WC hook) on a POST persists + projects
       through `Content.apply_document_block_op/5` — editing the bound title
       block updates content["title"]; same view pid (no remount).
    4. Flipping back to Classic shows the Beta-edited value in the form.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    # A `post` Expectation with an explicit layout — create_document scaffolds
    # content["blocks"] (bound title/slug/featuredImage + a free body region).
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{"name" => "featuredImage", "title" => "Featured Image", "type" => "image"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "slug"},
            %{"kind" => "field", "name" => "featuredImage"},
            %{"kind" => "region", "name" => "body"}
          ],
          "prefill" => %{"status" => "draft"}
        },
        @dataset
      )

    {:ok, post} =
      Content.create_document(
        "post",
        %{"doc_id" => "toggle-demo-p3", "title" => "Toggle Demo"},
        @dataset
      )

    {:ok, post: post}
  end

  test "editor mounts in Classic with the toggle; clicking Beta renders the block editor",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/toggle-demo-p3"))

    # Classic by default — the schema form, the toggle present, no block editor.
    assert html =~ ~s(name="doc[title]")
    assert html =~ ~s(data-test-id="editor-mode-toggle")
    assert html =~ ~s(data-test-id="editor-mode-classic")
    assert html =~ ~s(data-test-id="editor-mode-beta")
    refute html =~ ~s(data-test-id="studio-doc-beta-editor")

    # Flip to Beta — the premium block editor renders over the post's blocks.
    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="studio-doc-beta-editor")
    assert beta_html =~ ~s(data-test-id="studio-paper-block-editor")
    # A bound field-block + the free body block both render.
    assert beta_html =~ ~s(data-test-id="paper-add-block")
  end

  test "flipping Classic↔Beta does not mutate content[\"blocks\"] (lossless)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/toggle-demo-p3"))

    {:ok, before} = Content.get_document("drafts.toggle-demo-p3", "post", @dataset)
    before_blocks = stored_blocks("drafts.toggle-demo-p3")

    # Beta → Classic → Beta. Each flip is a pure assign; no write.
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    view |> element(~s([data-test-id="editor-mode-classic"])) |> render_click()
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    after_blocks = stored_blocks("drafts.toggle-demo-p3")

    assert after_blocks == before_blocks

    # The stored row's rev did not move (no persist on a toggle).
    {:ok, after_doc} = Content.get_document("drafts.toggle-demo-p3", "post", @dataset)
    assert after_doc.rev == before.rev
  end

  test "a Beta patch-block on the bound title persists + projects content[\"title\"]; no remount",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/toggle-demo-p3"))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    pid_before = view.pid

    title_block = Enum.find(stored_blocks("drafts.toggle-demo-p3"), &(&1["fieldName"] == "title"))

    # The bound title is a field-block edited via the field-block bridge; the
    # hook forwards a patch-block as a `paper-op` pushEvent (same wire the WC
    # uses). It routes through `Content.apply_document_block_op/5`.
    render_hook(view, "paper-op", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => current_doc_rev(view),
      "op" => "patch-block",
      "id" => title_block["id"],
      "patch" => %{"value" => "Beta Edited Title"}
    })

    {:ok, saved} = Content.get_document("drafts.toggle-demo-p3", "post", @dataset)
    assert saved.content["title"] == "Beta Edited Title"
    assert saved.title == "Beta Edited Title"

    saved_title = Enum.find(saved.content["blocks"], &(&1["fieldName"] == "title"))
    assert saved_title["value"] == "Beta Edited Title"

    # Same process — the op went through the document path, not a remount.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  test "flipping back to Classic shows the Beta-edited title in the form",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/toggle-demo-p3"))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    title_block = Enum.find(stored_blocks("drafts.toggle-demo-p3"), &(&1["fieldName"] == "title"))

    render_hook(view, "paper-op", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => current_doc_rev(view),
      "op" => "patch-block",
      "id" => title_block["id"],
      "patch" => %{"value" => "Round-Trip Title"}
    })

    classic_html = view |> element(~s([data-test-id="editor-mode-classic"])) |> render_click()

    # The Classic form's title input reflects the Beta edit (re-read via doc_to_form).
    assert classic_html =~ ~s(value="Round-Trip Title")
  end

  defp stored_blocks(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, "post", @dataset)
    doc.content["blocks"]
  end

  defp current_doc_rev(view), do: :sys.get_state(view.pid).socket.assigns.editor_doc.rev
end
