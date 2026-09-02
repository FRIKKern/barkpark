defmodule BarkparkWeb.Studio.StudioPaperDocActionsRulingTest do
  @moduledoc """
  THE RULING: PAPERS DELIBERATELY DO NOT CARRY THE CLASSIC DOC-ACTION BAR.

  `components.ex` dispatches `@editor_view == :paper` to `studio_paper_view/1`,
  whose attr list has no `doc_actions`; `DocActions.resolved_doc_actions/1` is
  threaded only into `studio_editor_shell`, the classic branch. The open
  question (spd-b34) was whether that is a deliberate scoping or a forgotten
  attribute. It is DELIBERATE, and this file is the binary that says so in both
  directions so a future refactor cannot re-decide it by accident — in EITHER
  direction:

    * threading the classic bar into the paper branch reds the exclusion arm;
    * dropping the paper pane's own controls reds the inclusion arm.

  ## The ruling

  The paper pane OWNS ITS HEADER. It carries Share, and since #13042 a Publish
  control (`data-test-id="paper-publish"`, drafts only), plus the sidebar
  metadata affordances. The classic actions — `open-secondary-picker`,
  `select-secondary`, `duplicate-doc`, `view-graph` — are EXCLUDED on purpose,
  because the paper surface is a single-document reading/writing canvas whose
  secondary pane is the paper SIDEBAR, not a second editor. Anything a paper
  needs from that set must be added to the paper header explicitly; never by
  threading the whole classic bar in.

  So spd-b34's criterion 1 ("if actions should be available, thread
  doc_actions…") does NOT apply, and its absence is not a bug to be repaired.

  ## Why these assertions are shaped this way

  Scoped to the `[data-test-id=studio-paper-editor]` panel and read as ELEMENTS
  and ATTRIBUTES (LazyHTML over that one panel's own render), never as a
  substring over the whole document: a whole-document `=~ "view-graph"` matches
  inlined CSS, icon sprite ids, and the desk chrome, and would go quietly
  vacuous.

  The classic-document arm is the non-vacuity proof. Without it the exclusion
  arm would pass just as well if the doc-action bar had been deleted repo-wide,
  or if the selector had rotted.

  `select-secondary` is deliberately NOT asserted present on the classic render:
  it lives inside the secondary PICKER MODAL, which only exists after
  `open-secondary-picker` is pressed. Its absence from a paper is still asserted
  — it is one of the four the ruling excludes.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @paper_slug "spd-b34-ruling-paper"
  @classic_type "b34article"
  @classic_slug "spd-b34-ruling-article"

  # The classic editor-header doc actions the paper surface excludes BY DESIGN
  # (`DocActions.default_doc_actions/2` — each is both the phx-click event name
  # and the control's data-test-id).
  @classic_actions ~w(open-secondary-picker select-secondary duplicate-doc view-graph)

  @paper_panel ~s([data-test-id="studio-paper-editor"])

  setup do
    # The canvas default, pinned (charter D233): sibling suites set this
    # process-globally, and the paper header renders differently at "0".
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

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

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @classic_type,
          "title" => "B34 Articles",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, paper} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => @paper_slug,
          "title" => "The Ruling Paper",
          "content" => %{
            "blocks" => [
              %{
                "id" => "b1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body prose."}]
              }
            ]
          }
        },
        @dataset
      )

    # FIXTURE LAW: the Publish control is draft-only (`paper_draft?`), so the
    # inclusion arm is only meaningful on a genuine `drafts.<slug>` row.
    assert paper.doc_id == "drafts.#{@paper_slug}"
    assert paper.status == "draft"

    {:ok, _} =
      Content.create_document(
        @classic_type,
        %{"doc_id" => @classic_slug, "title" => "The Ruling Article"},
        @dataset
      )

    :ok
  end

  defp open_paper(conn),
    do: live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@paper_slug}"))

  # The reserved `["open", type, id]` nav path — resolves a document with no
  # structure lookup, so the classic arm cannot fail for a desk-navigation
  # reason unrelated to what it is measuring.
  defp open_classic(conn),
    do:
      live(
        conn,
        scoped_studio("/d/#{@dataset}/studio/open/#{@classic_type}/drafts.#{@classic_slug}")
      )

  # Every `phx-click` value inside ONE panel, as a set — elements and attributes,
  # not a substring sweep over the page.
  defp phx_clicks_in(view, panel_selector) do
    view
    |> element(panel_selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[phx-click]")
    |> LazyHTML.attribute("phx-click")
    |> MapSet.new()
  end

  describe "the paper pane owns its header (the INCLUSION half of the ruling)" do
    test "a draft paper carries its own Publish control", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      assert has_element?(view, ~s(#{@paper_panel} [data-test-id="paper-publish"])),
             "the paper header's own Publish control (#13042) must be present on a draft"

      # PERMIT DIRECTION for the exclusion arm below: the panel really was
      # found and really parsed into phx-click-bearing elements, so a
      # `refute` over that set is a statement about the paper header rather
      # than about an empty MapSet.
      clicks = phx_clicks_in(view, @paper_panel)

      assert "paper-publish" in clicks,
             "expected the panel scrape to see the paper's own actions, got: #{inspect(Enum.sort(clicks))}"
    end
  end

  describe "the classic doc-action bar is excluded from papers ON PURPOSE" do
    test "none of the classic actions appear in the paper panel", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      clicks = phx_clicks_in(view, @paper_panel)

      for action <- @classic_actions do
        refute action in clicks,
               "#{action} is a CLASSIC editor doc action; the paper surface excludes it " <>
                 "by design (see this file's moduledoc). Panel phx-clicks: " <>
                 inspect(Enum.sort(clicks))

        refute has_element?(view, ~s(#{@paper_panel} [data-test-id="#{action}"])),
               "#{action} must have no control in the paper panel"
      end
    end
  end

  describe "non-vacuity: the classic bar really does exist, on classic documents" do
    test "a classic document renders the doc-action entry points the paper omits",
         %{conn: conn} do
      {:ok, view, _html} = open_classic(conn)

      assert has_element?(view, ~s([data-test-id="open-secondary-picker"])),
             "if this reds, the exclusion arm above is vacuous — the bar is gone repo-wide " <>
               "or the selector rotted, not 'papers exclude it'"

      # The other two header members of the excluded set, so the exclusion arm
      # is measured against a bar that demonstrably renders all of them.
      for action <- ~w(duplicate-doc view-graph) do
        assert has_element?(view, ~s([data-test-id="#{action}"])),
               "#{action} must render on a classic document"
      end

      # And the paper's own control is NOT part of that bar — the two headers
      # are different surfaces, which is the ruling in one line.
      refute has_element?(view, ~s([data-test-id="paper-publish"]))
    end
  end
end
