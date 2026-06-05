defmodule BarkparkWeb.BulldocsLiveTest do
  @moduledoc """
  Gate-A surviving-sentinel test for the convergence MVP (masterplan Fig 6).

  Proves the "no reload" property: a paper renders on mount, and a broadcast
  of updated HTML re-assigns `@html` and is patched into the DOM **without
  remounting**. The proof is two-pronged:

    1. PID identity — the LiveView process pid is identical before and after
       the broadcast (a remount / push_navigate would spawn a new process).
    2. Sentinel survival — `#paper-sentinel`, rendered once at mount OUTSIDE
       the re-assigned container, is still present after the update (a teardown
       would remove it).

  If LiveView were tearing down + re-rendering on each update (the old
  goto-reload behaviour the masterplan replaces), the pid would change and the
  sentinel would be re-created from scratch — the assertions below would fail.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Events

  @slug "2026-05-23-convergence-demo"

  defp seed_paper(html) do
    {:ok, paper} =
      Content.upsert_paper(%{slug: @slug, body_html: html, event_type: "plan-written"})

    paper
  end

  describe "mount + live update (no reload)" do
    test "renders the seeded body HTML on mount", %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>Hello convergence</h1></section>))

      {:ok, _view, html} = live(conn, "/papers/#{@slug}")

      assert html =~ "Hello convergence"
      assert html =~ ~s(id="block-1")
      # The sentinel element is present at mount.
      assert html =~ ~s(id="paper-sentinel")
    end

    test "broadcast re-assigns @html; same pid + sentinel survive (no remount)",
         %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>First</h1></section>))

      {:ok, view, html} = live(conn, "/papers/#{@slug}")

      # Pre-update state: original block present, the extra block is NOT.
      assert html =~ "First"
      assert html =~ ~s(id="block-1")
      refute html =~ ~s(id="block-2")
      assert html =~ ~s(id="paper-sentinel")

      pid_before = view.pid

      # Broadcast an UPDATED HTML carrying one extra block. This goes through
      # the real Content/PubSub spine: upsert_paper persists + broadcasts on
      # the per-doc topic the LiveView subscribed to at mount.
      {:ok, _} =
        Content.upsert_paper(%{
          slug: @slug,
          body_html:
            ~s(<section id="block-1"><h1>First</h1></section>) <>
              ~s(<section id="block-2"><p>Second block streamed in</p></section>)
        })

      # Pull the post-update DOM. render/1 reflects assigns after handle_info.
      updated = render(view)

      # The new block now renders...
      assert updated =~ ~s(id="block-2")
      assert updated =~ "Second block streamed in"
      # ...alongside the original (diffed in place, not replaced).
      assert updated =~ ~s(id="block-1")
      assert updated =~ "First"

      # SENTINEL 1 — same process: no remount, no push_navigate/redirect.
      assert view.pid == pid_before
      assert Process.alive?(view.pid)

      # SENTINEL 2 — the mount-time marker survived the update; it was diffed,
      # not torn down and rebuilt.
      assert updated =~ ~s(id="paper-sentinel")
      # The marker still carries its mount-time data-slug (unchanged identity).
      assert updated =~ ~s(data-slug="#{@slug}")
    end

    test "renders an empty-state when no paper is stored for the slug", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/papers/never-saved")
      assert html =~ ~s(id="paper-empty")
      assert html =~ "No paper saved yet"
    end
  end

  describe "Gate-B: multi-block streaming (no reload across a sequence)" do
    @block_slug "2026-05-23-wave4-stream"

    defp seed_block_paper do
      blocks = [
        %{"id" => "b-intro", "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "First block streamed."}]}
      ]

      {:ok, paper} =
        Content.upsert_paper(%{slug: @block_slug, blocks: blocks, event_type: "plan-written"})

      paper
    end

    defp append_block_op(id, text) do
      %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    test "mount streams the initial block keyed by its id", %{conn: conn} do
      seed_block_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@block_slug}")

      # Stream container is present and renders the seeded block.
      assert html =~ ~s(phx-update="stream")
      assert html =~ ~s(data-block-id="b-intro")
      assert html =~ "First block streamed."
      assert html =~ ~s(id="paper-sentinel")
    end

    test "a SEQUENCE of appends each appear via the stream; sentinel + prior blocks + pid survive",
         %{conn: conn} do
      seed_block_paper()

      {:ok, view, html} = live(conn, "/papers/#{@block_slug}")
      assert html =~ "First block streamed."
      refute html =~ "data-block-id=\"b-2\""

      pid_before = view.pid

      # Append three blocks in sequence through the real context + PubSub spine.
      # Each apply_block_op renders the fragment, bumps rev, broadcasts a
      # {:paper_block, …} delta the LiveView (subscribed at mount) consumes.
      {:ok, _} = Content.apply_paper_block_op(@block_slug, append_block_op("b-2", "Second block."))
      {:ok, _} = Content.apply_paper_block_op(@block_slug, append_block_op("b-3", "Third block."))
      {:ok, _} = Content.apply_paper_block_op(@block_slug, append_block_op("b-4", "Fourth block."))

      rendered = render(view)

      # Every new block appears in the DOM, keyed by id, via the stream...
      assert rendered =~ ~s(data-block-id="b-2")
      assert rendered =~ "Second block."
      assert rendered =~ ~s(data-block-id="b-3")
      assert rendered =~ "Third block."
      assert rendered =~ ~s(data-block-id="b-4")
      assert rendered =~ "Fourth block."

      # ...the original block survived (it was never re-rendered)...
      assert rendered =~ ~s(data-block-id="b-intro")
      assert rendered =~ "First block streamed."

      # SENTINEL 1 — same process across the WHOLE sequence: no remount,
      # no push_navigate/redirect at any step = no reload.
      assert view.pid == pid_before
      assert Process.alive?(view.pid)

      # SENTINEL 2 — the mount-time marker survived every delta.
      assert rendered =~ ~s(id="paper-sentinel")
      assert rendered =~ ~s(data-slug="#{@block_slug}")
    end

    test "a patch-block delta patches one block in place; the rest are untouched",
         %{conn: conn} do
      seed_block_paper()
      {:ok, _} = Content.apply_paper_block_op(@block_slug, append_block_op("b-2", "Second block."))

      {:ok, view, _html} = live(conn, "/papers/#{@block_slug}")
      pid_before = view.pid

      patch = %{
        "op" => "patch-block",
        "id" => "b-intro",
        "patch" => %{"content" => [%{"type" => "text", "value" => "First block EDITED."}]}
      }

      {:ok, _} = Content.apply_paper_block_op(@block_slug, patch)
      rendered = render(view)

      assert rendered =~ "First block EDITED."
      refute rendered =~ "First block streamed."
      # Sibling block untouched.
      assert rendered =~ "Second block."
      # No remount.
      assert view.pid == pid_before
    end

    test "rev-gap recovery: a delta whose rev skips ahead triggers a full refetch",
         %{conn: conn} do
      seed_block_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@block_slug}")
      pid_before = view.pid

      # Persist two blocks straight into the context (bumps rev), but hand the
      # LiveView a SINGLE delta whose rev is ahead of what it last saw — a
      # simulated dropped frame. The view must refetch the full doc.
      {:ok, _} = Content.apply_paper_block_op(@block_slug, append_block_op("b-2", "Recovered B2."))
      {:ok, last} = Content.apply_paper_block_op(@block_slug, append_block_op("b-3", "Recovered B3."))

      # Frame with a rev far ahead of the mount rev → gap → refetch path.
      send(
        view.pid,
        {:paper_block,
         %{
           op_kind: "append-block",
           block_id: "b-3",
           fragment_html: "<p>stale fragment ignored</p>",
           position: 2,
           rev: last.rev
         }}
      )

      rendered = render(view)

      # The refetch pulled the true current doc — both persisted blocks present,
      # the stale inline fragment was NOT used.
      assert rendered =~ "Recovered B2."
      assert rendered =~ "Recovered B3."
      refute rendered =~ "stale fragment ignored"
      # Still no remount.
      assert view.pid == pid_before
      assert rendered =~ ~s(id="paper-sentinel")
    end

    test "whole-HTML fallback still works: a :paper_updated broadcast re-assigns",
         %{conn: conn} do
      # An HTML-only paper (no blocks) keeps the Wave-3 re-assign path.
      slug = "wave4-html-fallback"
      {:ok, _} = Content.upsert_paper(%{slug: slug, body_html: "<p id=\"v1\">v1</p>"})

      {:ok, view, html} = live(conn, "/papers/#{slug}")
      assert html =~ ~s(id="v1")
      refute html =~ ~s(id="v2")
      pid_before = view.pid

      {:ok, _} = Content.upsert_paper(%{slug: slug, body_html: "<p id=\"v2\">v2 re-assigned</p>"})

      rendered = render(view)
      assert rendered =~ ~s(id="v2")
      assert rendered =~ "v2 re-assigned"
      # No remount on the fallback path either.
      assert view.pid == pid_before
      assert rendered =~ ~s(id="paper-sentinel")
    end
  end

  describe "P6.U2: goal-path rail" do
    @rail_slug "2026-05-25-goal-rail-demo"
    @rail_goal "g-test"

    # Seed a paper with a goal_id. upsert_paper with a present event_type
    # creates the paper AND (via U1) one paper_event for the goal. We then add
    # two more events for the same goal directly through the Events context so
    # the rail has a 3-commit lineage.
    defp seed_rail_paper do
      {:ok, paper} =
        Content.upsert_paper(%{
          "slug" => @rail_slug,
          "style" => "article",
          "goal_id" => @rail_goal,
          "event_type" => "goal-opened",
          "blocks" => [
            %{
              "id" => "r-intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Rail demo body."}]
            }
          ]
        })

      # W1.5-C: the rail now scopes events to the paper's OWN workspace, so the
      # follow-up events must carry the paper's resolved scope (upsert_paper
      # Default-stamped the paper above) to appear in the rail — mirroring how a
      # real BulldocsLive write stamps the paper's workspace onto each event.
      scope = %{"workspace_id" => paper.workspace_id, "project_id" => paper.project_id}

      {:ok, _} =
        Events.create_event(
          Map.merge(scope, %{"goal_id" => @rail_goal, "event_type" => "plan-written"})
        )

      {:ok, _} =
        Events.create_event(
          Map.merge(scope, %{"goal_id" => @rail_goal, "event_type" => "goal-snapshot"})
        )

      paper
    end

    test "renders the rail with a linear gitGraph commit per event", %{conn: conn} do
      seed_rail_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@rail_slug}")

      # The rail element is present.
      assert html =~ ~s(id="goal-path-rail")
      assert html =~ "Goal path"

      # The gitGraph header + a commit per each of the 3 events, under the hook.
      # The hook lives on #goal-path-graph which wraps the gitGraph <pre>.
      assert html =~ ~s(phx-hook="PaperMermaid")
      assert html =~ ~s(id="goal-path-graph")
      assert html =~ "gitGraph"

      # One unique, index-suffixed commit id per event, in inserted_at order.
      # HEEx auto-escapes the `"` around each id to `&quot;` in the rendered
      # HTML (the browser DOM hands Mermaid the unescaped text) — so match the
      # escaping-agnostic `commit id:` + the bare id text.
      assert html =~ "commit id:"
      assert html =~ "goal-opened-1"
      assert html =~ "plan-written-2"
      assert html =~ "goal-snapshot-3"

      # Exactly three commits emitted (no stray extra commit lines).
      assert length(String.split(html, "commit id:")) - 1 == 3

      # Event types render in the clickable fallback list, with click wiring.
      assert html =~ "goal-opened"
      assert html =~ "plan-written"
      assert html =~ "goal-snapshot"
      assert html =~ ~s(phx-click="rail-select")
    end

    test "rail-select highlights the chosen event row (selection only, no swap)",
         %{conn: conn} do
      seed_rail_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@rail_slug}")

      # Pick the first event row and click it.
      [event_id | _] =
        Events.list_for_goal(@rail_goal) |> Enum.map(& &1.id)

      rendered =
        view
        |> element(~s([phx-value-event-id="#{event_id}"]))
        |> render_click()

      # The selected row carries the highlight class; the article body is
      # untouched (no swap/diff in v1).
      assert rendered =~ "is-selected"
      assert rendered =~ "Rail demo body."
    end

    test "a paper WITHOUT a goal_id renders NO rail", %{conn: conn} do
      slug = "2026-05-25-no-goal-paper"

      {:ok, _} =
        Content.upsert_paper(%{
          "slug" => slug,
          "style" => "article",
          "body_html" => "<p id=\"no-goal-body\">No goal here.</p>"
        })

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "No goal here."
      # Negative case: no rail element and no emitted gitGraph commits.
      # (The word "gitGraph" alone appears in the layout's CSS comment, so we
      # assert on the rail element + an actual `commit id:` line instead.)
      refute html =~ ~s(id="goal-path-rail")
      refute html =~ "commit id:"
    end
  end

  describe "P6.U3: diff modal" do
    @diff_slug "2026-05-25-diff-modal-demo"
    @diff_goal "g-diff"

    # Seed a paper with a goal_id plus two events whose payload_html differs by
    # one line — so the diff has a stable context line, one removed, one added.
    defp seed_diff_paper do
      {:ok, paper} =
        Content.upsert_paper(%{
          "slug" => @diff_slug,
          "style" => "article",
          "body_html" => "<p id=\"diff-body\">Diff demo body.</p>"
        })

      {:ok, a} =
        Events.create_event(%{
          "goal_id" => @diff_goal,
          "paper_slug" => @diff_slug,
          "event_type" => "plan-written",
          "payload_html" => "shared line\nORIGINAL middle\ntail line"
        })

      {:ok, b} =
        Events.create_event(%{
          "goal_id" => @diff_goal,
          "paper_slug" => @diff_slug,
          "event_type" => "plan-grilled",
          "payload_html" => "shared line\nREVISED middle\ntail line"
        })

      {paper, a, b}
    end

    test "open-diff renders the modal with added/removed lines; close-diff hides it",
         %{conn: conn} do
      {_paper, a, b} = seed_diff_paper()

      {:ok, view, html} = live(conn, "/papers/#{@diff_slug}")

      # Modal is NOT present before any diff is opened.
      refute html =~ ~s(id="bp-diff-modal")

      # Push the open-diff hook event with the two seeded event ids.
      rendered = render_hook(view, "open-diff", %{"from" => a.id, "to" => b.id})

      # The modal renders, titled with both event types...
      assert rendered =~ ~s(id="bp-diff-modal")
      assert rendered =~ "plan-written"
      assert rendered =~ "plan-grilled"

      # ...and shows the diff body: shared context line, removed + added line.
      assert rendered =~ ~s(class="bp-diff")
      assert rendered =~ "shared line"
      assert rendered =~ ~s(bp-diff-del)
      assert rendered =~ "ORIGINAL middle"
      assert rendered =~ ~s(bp-diff-add)
      assert rendered =~ "REVISED middle"

      # Close it via the close button → modal gone.
      closed =
        view
        |> element(~s(button.bp-diff-close))
        |> render_click()

      refute closed =~ ~s(id="bp-diff-modal")
    end

    test "open-diff with a missing event is a no-op (no crash, no modal)",
         %{conn: conn} do
      {_paper, a, _b} = seed_diff_paper()

      {:ok, view, _html} = live(conn, "/papers/#{@diff_slug}")

      missing = Ecto.UUID.generate()
      rendered = render_hook(view, "open-diff", %{"from" => a.id, "to" => missing})

      # No modal, and the LiveView is still alive (the missing event was guarded).
      refute rendered =~ ~s(id="bp-diff-modal")
      assert Process.alive?(view.pid)
    end
  end

  describe "P6.U5: action buttons (routing Option B — record intent as paper_events)" do
    @action_slug "2026-05-25-action-buttons-demo"
    @action_goal "g-action"

    # Seed an article paper whose originating doc is a /plans/ doc and which
    # carries a goal_id — so the action set is the plan pair (build + grill) and
    # a click can be attributed to the goal.
    defp seed_action_paper do
      {:ok, paper} =
        Content.upsert_paper(%{
          "slug" => @action_slug,
          "style" => "article",
          "goal_id" => @action_goal,
          "source_doc" => "/paperflow/plans/2026-05-25-convergence-plan.html",
          "body_html" => "<p id=\"action-body\">Action demo body.</p>"
        })

      paper
    end

    test "a /plans/ paper renders the plan action bar (build + grill)", %{conn: conn} do
      seed_action_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@action_slug}")

      # The bar element + both plan buttons, each wired to "paper-action".
      assert html =~ ~s(id="paper-action-bar")
      assert html =~ "Build this plan"
      assert html =~ "Grill the plan"
      assert html =~ ~s(phx-click="paper-action")
      assert html =~ ~s(phx-value-action="build")
      assert html =~ ~s(phx-value-action="grill")
    end

    test "clicking an action button records an action:<key> paper_events row + acknowledges",
         %{conn: conn} do
      seed_action_paper()

      {:ok, view, _html} = live(conn, "/papers/#{@action_slug}")

      # No action events yet for this goal.
      refute Enum.any?(
               Events.list_for_goal(@action_goal),
               &(&1.event_type == "action:build")
             )

      rendered =
        view
        |> element(~s(button[phx-value-action="build"]))
        |> render_click()

      # The UI acknowledges the click inline.
      assert rendered =~ "Requested: Build this plan"

      # A paper_events row now exists for the goal, typed action:build, with the
      # intent payload — orchestrator-readable + visible in the U2 rail.
      events = Events.list_for_goal(@action_goal)
      build = Enum.find(events, &(&1.event_type == "action:build"))

      assert build
      assert build.paper_slug == @action_slug
      assert build.goal_id == @action_goal
      assert build.branch == "main"
      assert build.payload_html =~ "Action 'build' requested from /papers/#{@action_slug}"
    end

    test "a paper WITHOUT a source_doc renders NO action bar", %{conn: conn} do
      slug = "2026-05-25-no-source-doc-paper"

      {:ok, _} =
        Content.upsert_paper(%{
          "slug" => slug,
          "style" => "article",
          "body_html" => "<p id=\"no-source-body\">No source doc here.</p>"
        })

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "No source doc here."
      refute html =~ ~s(id="paper-action-bar")
      refute html =~ ~s(phx-click="paper-action")
    end
  end

  describe "P6.U4: Simplify control (routing Option B — record simplify intent + decision as paper_events)" do
    @simplify_slug "2026-05-25-simplify-demo"
    @simplify_goal "g-simplify"

    # Seed a goal-bearing article paper. Simplify applies to ANY paper with a
    # goal_id, independent of source_doc — so we deliberately omit source_doc
    # here (no U5 action bar) to prove Simplify is its own control.
    defp seed_simplify_paper do
      {:ok, paper} =
        Content.upsert_paper(%{
          "slug" => @simplify_slug,
          "style" => "article",
          "goal_id" => @simplify_goal,
          "body_html" => "<p id=\"simplify-body\">Simplify demo body.</p>"
        })

      paper
    end

    test "a goal-bearing paper renders the Simplify button", %{conn: conn} do
      seed_simplify_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@simplify_slug}")

      assert html =~ ~s(id="paper-simplify")
      assert html =~ "Simplify"
      assert html =~ ~s(phx-click="simplify-request")
      # No request pending yet → no Accept/Reject controls.
      refute html =~ ~s(phx-click="simplify-accept")
      refute html =~ ~s(phx-click="simplify-reject")
    end

    test "clicking Simplify records a simplify-request on simplified-1 + reveals Accept/Reject",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      # No simplify events yet for this paper.
      refute Enum.any?(
               Events.list_for_paper(@simplify_slug),
               &(&1.event_type == "simplify-request")
             )

      rendered =
        view
        |> element(~s(button[phx-click="simplify-request"]))
        |> render_click()

      # A simplify-request row now exists on the first branch.
      events = Events.list_for_paper(@simplify_slug)
      req = Enum.find(events, &(&1.event_type == "simplify-request"))

      assert req
      assert req.branch == "simplified-1"
      assert req.goal_id == @simplify_goal
      assert req.paper_slug == @simplify_slug
      assert req.payload_html =~ "simplified-1"

      # The UI acknowledges + now offers Accept/Reject.
      assert rendered =~ "Simplify requested — simplified-1"
      assert rendered =~ ~s(phx-click="simplify-accept")
      assert rendered =~ ~s(phx-click="simplify-reject")
    end

    test "a second Simplify click increments the branch index to simplified-2",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      view |> element(~s(button[phx-click="simplify-request"])) |> render_click()
      rendered = view |> element(~s(button[phx-click="simplify-request"])) |> render_click()

      branches =
        Events.list_for_paper(@simplify_slug)
        |> Enum.filter(&(&1.event_type == "simplify-request"))
        |> Enum.map(& &1.branch)
        |> Enum.sort()

      assert branches == ["simplified-1", "simplified-2"]
      assert rendered =~ "Simplify requested — simplified-2"
    end

    test "clicking Accept records a simplify-accept event on the pending branch",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      view |> element(~s(button[phx-click="simplify-request"])) |> render_click()
      rendered = view |> element(~s(button[phx-click="simplify-accept"])) |> render_click()

      accept =
        Events.list_for_paper(@simplify_slug)
        |> Enum.find(&(&1.event_type == "simplify-accept"))

      assert accept
      assert accept.branch == "simplified-1"
      assert accept.goal_id == @simplify_goal
      assert accept.paper_slug == @simplify_slug

      # Ack shown + the decision controls retract (pending cleared).
      assert rendered =~ "Accepted simplified-1"
      refute rendered =~ ~s(phx-click="simplify-accept")
    end

    test "clicking Reject records a simplify-reject event on the pending branch",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      view |> element(~s(button[phx-click="simplify-request"])) |> render_click()
      rendered = view |> element(~s(button[phx-click="simplify-reject"])) |> render_click()

      reject =
        Events.list_for_paper(@simplify_slug)
        |> Enum.find(&(&1.event_type == "simplify-reject"))

      assert reject
      assert reject.branch == "simplified-1"
      assert rendered =~ "Rejected simplified-1"
      refute rendered =~ ~s(phx-click="simplify-reject")
    end

    test "a paper WITHOUT a goal_id renders NO Simplify button", %{conn: conn} do
      slug = "2026-05-25-no-goal-simplify-paper"

      {:ok, _} =
        Content.upsert_paper(%{
          "slug" => slug,
          "style" => "article",
          "body_html" => "<p id=\"no-goal-simplify-body\">No goal, no simplify.</p>"
        })

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "No goal, no simplify."
      refute html =~ ~s(id="paper-simplify")
      refute html =~ ~s(phx-click="simplify-request")
    end
  end
end
