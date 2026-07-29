defmodule BarkparkWeb.Studio.StudioLiveNewPaperJourneyTest do
  @moduledoc """
  THE HUMAN PATH, not the API path (spd-w17).

  The owner sat down, clicked "+" in the Papers pane, watched the URL become
  `/studio/paper/paper-XXXX` — and the content pane still read
  "Select a document to edit". Every prior Studio suite drove the CODE
  (`render_click(view, "new-document", …)`, direct `Content.upsert_paper`
  seeds); nobody had ever clicked the DOM button with type `"paper"` and looked
  at what came back. This file is that journey, offline.

  Two arms, because the defect has two faces:

    1. FRESH CREATE — mount the Papers desk, click the pane's "+" button, and
       assert a real editor came back: `paper_block_mode` on, the block-editor
       marker in the DOM, and NOT the empty state. Plus the PERSISTED shape:
       the paper-template seed (locked `tpl-title` with `role: "title"` +
       `tpl-body`, `style: "article"`), which only fires when the create seeds
       an explicit EMPTY block list (D219).

    2. PRE-EXISTING DRAFT-ONLY PAPER — every never-published paper is
       unopenable by URL, not merely freshly-created ones (D228; two such
       fossils sit in production from 2026-07-06 and 2026-07-09). Same
       assertions, reached by navigation instead of by the button.

  DELIBERATELY NOT ASSERTED: that `Content.get_blocks_doc(published_id)`
  resolves. It does not, and must not — `create_document` always writes
  `drafts.<id>` (writer.ex), so the published row genuinely does not exist.
  Asserting it would push the fix toward navigating to the `drafts.` id, which
  is the refuted lever (it would break `same_editor_doc?/2` identity, presence,
  the secondary pane and discard). The editor resolving the DRAFT is the fix.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @fossil_slug "spd-w17-fossil-paper"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  setup do
    seed_paper_schema!()
    :ok
  end

  # The template seed is the product promise: a brand-new paper is not an empty
  # void, it is a locked title heading plus one empty paragraph to type into.
  defp assert_template_shape!(doc) do
    blocks = doc.content["blocks"]
    assert is_list(blocks), "expected a blocks list, got: #{inspect(doc.content["blocks"])}"

    title =
      Enum.find(blocks, fn b ->
        Map.get(b, "role") == "title" or get_in(b, ["meta", "role"]) == "title"
      end)

    assert title, "expected a role:title block in #{inspect(blocks)}"
    assert title["id"] == "tpl-title"
    assert title["type"] == "heading"
    assert title["locked"] == true or get_in(title, ["meta", "locked"]) == true

    assert Enum.any?(blocks, &(&1["id"] == "tpl-body")),
           "expected the empty tpl-body paragraph to type into, got #{inspect(blocks)}"

    assert doc.content["style"] == "article"
  end

  # The one place the two arms agree: whatever route got us here, the human is
  # looking at a real editor.
  defp assert_real_editor!(view, html) do
    refute html =~ "Select a document to edit"
    assert html =~ ~s(data-test-id="studio-paper-block-editor")

    assert :sys.get_state(view.pid).socket.assigns.paper_block_mode,
           "expected paper_block_mode — the paper opened in the field-form/empty branch instead"
  end

  describe "arm 1 — a human clicks + in the Papers pane" do
    test "the new paper opens in a real editor, seeded with the paper template", %{conn: conn} do
      # The flat /studio/... path 302s since the P3 scoped cutover; mount the
      # canonical scoped form the browser actually lands on.
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      # Before the click there is no document selected — the empty state here is
      # CORRECT, and pinning it is what makes its survival after the click a
      # real failure rather than a coincidence.
      assert html =~ "Select a document to edit"

      # SCOPE the selector: the airdrop/access header buttons share the
      # `.pane-add-btn` class, and more than one element carries
      # [phx-click="new-document"] across the desk.
      html =
        view
        |> element(~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]))
        |> render_click()

      refute html =~ "Failed to create"
      assert_real_editor!(view, html)

      # …and the row that was actually written carries the template.
      created =
        "paper"
        |> Content.list_documents(@dataset, perspective: :raw)
        |> Enum.find(&(&1.doc_id != "drafts.#{@fossil_slug}"))

      assert created, "expected the created paper draft row to exist"
      assert Content.draft?(created.doc_id), "create_document always writes drafts.<id>"
      assert_template_shape!(created)
    end
  end

  describe "arm 2 — a pre-existing draft-only paper opened by URL (D228)" do
    setup do
      {:ok, doc} =
        Content.create_document(
          "paper",
          %{"doc_id" => @fossil_slug, "title" => "Untitled", "content" => %{"blocks" => []}},
          @dataset
        )

      # The fossil is genuinely draft-only: no published row exists for it.
      assert doc.doc_id == "drafts.#{@fossil_slug}"
      assert {:error, :not_found} = Content.get_document(@fossil_slug, "paper", @dataset)

      :ok
    end

    test "it opens in a real editor rather than the empty state", %{conn: conn} do
      {:ok, view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@fossil_slug}"))

      assert_real_editor!(view, html)

      {:ok, fossil} = Content.get_document("drafts.#{@fossil_slug}", "paper", @dataset)
      assert_template_shape!(fossil)
    end

    # The SECOND door onto the same defect (D220). The backlinks panel jumps to a
    # referencer through the reserved ["open", type, id] segment, which resolved
    # blocks-docs published-only too. Fixing only the desk branch would have left
    # this one silently blank — and no arm above touches it.
    test "the same paper opens through the reserved open/type/id backlink segment", %{conn: conn} do
      {:ok, view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/open/paper/#{@fossil_slug}"))

      assert_real_editor!(view, html)
    end
  end
end
