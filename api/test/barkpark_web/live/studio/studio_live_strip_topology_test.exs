defmodule BarkparkWeb.Studio.StudioLiveStripTopologyTest do
  @moduledoc """
  b47 — D180 BEYOND TWO PANES. The companion to
  `studio_live_navigational_truth_test.exs`, which measured the surviving
  44px strip on a 2-SEGMENT paper path only (`panes = [Structure, Papers]`)
  and refused to generalise. This file drives the two topologies that ruling
  could not claim, on live processes.

  ## What the filing predicted, and what the run says

  `b47-strip-behaviour-unmeasured-beyond-two-panes` predicted that a paper
  nested under a group ("3+ panes") would make the surviving strip an
  INTERMEDIATE pane, so `Enum.take(nav_path, idx)` would land on a LIST
  instead of closing the document.

  THE PREMISE IS FALSE, and the mechanism says why. `PaneBuilder.display_state/5`
  hands `:strip` to `idx == num_panes - 1` and `:hidden` to everything else —
  the surviving strip is the LAST pane at EVERY depth, never an intermediate
  one. And the last pane is addressed by `Enum.take(nav_path, num_panes - 1)`,
  which on an ordinary paper path drops exactly the one segment the editor
  consumed: the document id. So the strip closes the document at depth 3 for
  the same arithmetic reason it does at depth 2.

  Measured here on a declared desk (`deskStructure` → a `list` group
  "Library" holding a `documentTypeList` of type `paper`):

      nav_path BEFORE:  ["library", "papers", "<slug>"]
      panes BEFORE:     ["pane-structure", "pane-library", "pane-papers"]
      editor open:      true
      strips SUMMONED:  ["pane-papers"]           # the LAST pane, not an intermediate
      nav_path AFTER:   ["library", "papers"]
      panes AFTER:      ["pane-structure", "pane-library", "pane-papers"]
      editor open:      false
      editor_doc:       nil
      sidebar_user_opened: false

  ## The reserved `["open", "paper", id]` head, driven END-TO-END

  D180's comment named this route from source only. Here it is DRIVEN: a
  materialised inbound edge puts a real row in the Relations backlinks panel,
  the row's `open-backlink` click is dispatched, and the resulting nav head is
  read off the live socket. That topology has ONE pane (the reserved head adds
  none), so the strip is pane 0 and `take(nav_path, 0) == []` — the desk root.
  Still a document-close, one level deeper than the ordinary path's exit.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @deep_slug "2026-09-10-b47-deep-paper"
  @target_slug "2026-09-10-b47-backlink-target"
  @referrer_slug "2026-09-10-b47-backlink-referrer"

  setup do
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

    for slug <- [@deep_slug, @target_slug, @referrer_slug] do
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: @dataset,
            blocks: [
              %{"id" => "h-1", "type" => "heading", "text" => "Topology"},
              %{
                "id" => "p-1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "The way out, deeper."}]
              }
            ]
          })
        )
    end

    :ok
  end

  # A DECLARED desk (`deskStructure`) is the only way to nest a paper type list
  # under a group: the generated desk puts every public type at the root, which
  # is exactly why every prior D180 measurement was stuck at two panes.
  defp declare_nested_desk! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        @dataset
      )

    items = [
      %{
        "kind" => "list",
        "id" => "library",
        "title" => "Library",
        "items" => [
          %{
            "kind" => "documentTypeList",
            "id" => "papers",
            "type" => "paper",
            "title" => "Papers"
          }
        ]
      }
    ]

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
    :ok
  end

  defp bucket(view, b), do: render_hook(view, "width-bucket", %{"bucket" => b})

  defp toggle(view),
    do: element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()

  # Tag-agnostic, exactly as in the D179/D180 lock: a `:strip` renders as a
  # <button> and a `:full` as a <section>, so a tag whitelist would under-count
  # the very affordance under test.
  defp pane_ids(html) do
    Regex.scan(~r/<[a-z]+[^>]*\bid="(pane-[a-z0-9-]+)"/, html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  defp editor_body_tag(html) do
    case Regex.run(~r|<div[^>]*class="editor-body[^>]*>|s, html) do
      [tag] -> tag
      _ -> ""
    end
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "D180 at nav depth 3 — a paper nested under a declared group" do
    test "the surviving strip is the LAST pane, and its click still closes the document",
         %{conn: conn} do
      :ok = declare_nested_desk!()

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/library/papers/#{@deep_slug}"))

      before_html = bucket(view, "standard")
      before_ids = pane_ids(before_html)
      before_assigns = live_assigns(view)

      # PRECONDITION 1 — this really is the topology the filing said was
      # unmeasured. Without three panes the whole test is the old 2-pane case
      # wearing a new name.
      assert length(before_ids) == 3, """
      premise failed: the deep path rendered #{length(before_ids)} pane(s) \
      (#{inspect(before_ids)}), not 3. The declared desk did not nest the paper \
      list under a group, so this is not the >2-pane topology b47 asks about.
      """

      assert before_assigns[:nav_path] == ["library", "papers", @deep_slug], """
      premise failed: nav_path is #{inspect(before_assigns[:nav_path])}. The URL \
      must resolve to a THREE-segment path or `Enum.take/2` has nothing deeper \
      to slice than the 2-segment case already measured.
      """

      # PRECONDITION 2 — a document is actually open. "The strip closes the
      # document" is unfalsifiable against a desk with no document.
      assert editor_body_tag(before_html) != "",
             "premise failed: no editor is open on the deep path"

      summoned = toggle(view)
      strips = pane_ids(summoned)

      assert length(strips) == 1, """
      premise failed: the Tier-2 ladder must leave exactly ONE 44px strip at \
      standard, but the row is #{inspect(strips)}. Without the ladder engaged \
      this measures an ordinary pane click.
      """

      [strip_id] = strips

      # THE FINDING. b47 predicted an INTERMEDIATE strip. `display_state/5`
      # gives `:strip` to `idx == num_panes - 1` only, so the surviving strip
      # is the LAST pane at depth 3 exactly as at depth 2.
      assert strip_id == List.last(before_ids), """
      the surviving strip is #{inspect(strip_id)}, not the last pane \
      #{inspect(List.last(before_ids))}. If the ladder ever leaves an \
      INTERMEDIATE pane behind, b47's prediction comes true and D180's \
      generalisation must be withdrawn: `Enum.take(nav_path, idx)` on an \
      intermediate index lands on a LIST with the document still open.
      """

      element(view, "##{strip_id}") |> render_click()

      path = assert_patch(view)
      assert is_binary(path) and path != "", "the strip click did not patch"

      after_html = render(view)
      after_assigns = live_assigns(view)

      # 1 — the truncation dropped exactly the document id, not a whole level.
      assert after_assigns[:nav_path] == ["library", "papers"], """
      nav_path after the strip click is #{inspect(after_assigns[:nav_path])}. \
      D180's arithmetic is that pane `num_panes - 1` is addressed by \
      `Enum.take(nav_path, num_panes - 1)`, which on an ordinary paper path \
      drops exactly the segment the editor consumed.
      """

      # 2 — the rail came all the way back, all three panes.
      assert pane_ids(after_html) == before_ids, """
      the strip click did not restore the rail. Before: #{inspect(before_ids)} \
      after: #{inspect(pane_ids(after_html))}.
      """

      # 3 — the DOCUMENT is closed. This is the half b47 predicted would NOT
      # happen at depth 3.
      assert editor_body_tag(after_html) == "", """
      the editor survived the strip click at nav depth 3. b47 predicted exactly \
      this ("lands on a LIST instead of closing the document") — if this \
      assertion ever fails, the prediction was right and D180 must be re-scoped \
      to two panes.
      """

      assert after_assigns[:editor_doc] == nil,
             "the editor doc assign survived the document close at depth 3"

      # 4 — the transitive dismiss chain ran here too (push_patch ->
      # handle_params -> rebuild_panes -> clear_paper_view -> sidebar_assigns(nil)).
      # Pane ids alone stay green if that chain is refactored away.
      assert after_assigns[:sidebar_user_opened] == false, """
      `sidebar_user_opened` is #{inspect(after_assigns[:sidebar_user_opened])}, \
      not false, at nav depth 3.
      """
    end
  end

  describe "D180 on the reserved [\"open\", \"paper\", id] head, reached through the backlinks panel" do
    test "a backlink click lands the reserved head, and its strip exits to the desk root",
         %{conn: conn} do
      # A materialised inbound edge is what puts a row in the Relations panel:
      # `Shared.load_backlinks/2` reads `Content.Graph.reverse_referencers/2`
      # over `content_edges`.
      {:ok, _edge} =
        Content.add_edge(@referrer_slug, @target_slug, "references",
          dataset: @dataset,
          plugin_source: nil
        )

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@target_slug}"))

      html = bucket(view, "standard")

      # PRECONDITION — the panel really rendered a clickable backlink. Without
      # it the "end-to-end" claim is source inference again.
      assert html =~ ~s(data-test-id="backlink-row"), """
      premise failed: no backlink row rendered on the target paper, so the \
      reserved head cannot be reached the way a user reaches it.
      """

      element(view, ~s(button[data-test-id="backlink-row"])) |> render_click()

      backlink_path = assert_patch(view)

      assert backlink_path =~ "/open/paper/#{@referrer_slug}", """
      the backlink click patched to #{inspect(backlink_path)}, which does not \
      carry the reserved `["open", "paper", id]` head. This assertion is the \
      end-to-end half: `Handlers.Paper.open_backlink/2` is the ONLY producer of \
      that head in the Studio.
      """

      opened_html = render(view)
      opened_assigns = live_assigns(view)

      assert opened_assigns[:nav_path] == ["open", "paper", @referrer_slug], """
      nav_path after the backlink click is #{inspect(opened_assigns[:nav_path])}.
      """

      assert editor_body_tag(opened_html) != "", """
      the reserved head opened no editor, so there is no Document inspector to \
      summon and the ladder cannot engage.
      """

      # The reserved head contributes NO panes — `walk_path(["open", …])`
      # returns the pane stack unchanged — so the root pane IS the last pane.
      before_ids = pane_ids(opened_html)

      assert before_ids == ["pane-structure"], """
      the reserved head rendered #{inspect(before_ids)}; it is supposed to add \
      no pane at all, leaving the root pane as the only one.
      """

      summoned = toggle(view)
      strips = pane_ids(summoned)

      assert length(strips) == 1, """
      the ladder did not engage on the reserved head: strips #{inspect(strips)}.
      """

      [strip_id] = strips
      element(view, "##{strip_id}") |> render_click()

      _ = assert_patch(view)

      after_html = render(view)
      after_assigns = live_assigns(view)

      # `Enum.take(nav_path, 0) == []` — the desk root, skipping the Papers
      # list the ordinary path would have returned to. One level deeper an exit
      # than the 2-segment case, and still a document-close.
      assert after_assigns[:nav_path] == [], """
      nav_path after the reserved-head strip click is \
      #{inspect(after_assigns[:nav_path])}, not the desk root. The strip is \
      pane 0 here, and `Enum.take(nav_path, 0)` is `[]`.
      """

      assert editor_body_tag(after_html) == "",
             "the editor survived the strip click on the reserved head"

      assert after_assigns[:editor_doc] == nil,
             "the editor doc assign survived the reserved-head document close"

      assert after_assigns[:sidebar_user_opened] == false, """
      `sidebar_user_opened` is #{inspect(after_assigns[:sidebar_user_opened])}, \
      not false, after the reserved-head strip click.
      """
    end
  end
end
