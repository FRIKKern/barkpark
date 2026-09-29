defmodule BarkparkWeb.BulldocsLiveCrossProjectDecisionTest do
  @moduledoc """
  END-TO-END reach proof for the PROJECT rung of
  `Barkpark.Plugins.Bulldocs.Events.check_same_scope/2` (task-369bfc803e02fe0d).

  The sibling unit tests in `test/barkpark/plugins/bulldocs/events_test.exs`
  call `Events.record_decision/1` directly. This file asks the harder question
  main's ruling asked: can a REAL caller, over a REAL socket, present a
  decision whose workspace matches the request's and whose project does not —
  i.e. is the project conjunct REACHABLE, or is it dead code fenced by
  something upstream?

  ## The path

  `BulldocsLive.record_simplify_decision/4` (`bulldocs_live.ex`) takes the
  request id STRAIGHT OFF THE WIRE (`%{"request-id" => id}`, the
  `phx-value-request-id` on the Accept/Reject buttons) and builds the
  decision's scope from `paper_goal_and_scope/3` — the scope of the paper THIS
  socket resolved, `fetch_paper(slug, reader_scope, dataset)`. `fetch_request/1`
  inside `Events.record_decision/1` is a bare, UNSCOPED `get_event(id)`, so a
  socket in project B really does load project A's request row. Only
  `check_same_scope/2` stands between that and an
  `authorization: "authorized"` row.

  ## The scenario driven below

  ONE workspace, TWO projects, ONE slug present in both (papers are unique per
  `{doc_id, type, dataset_id}` and a dataset row is per-project, so the same
  slug living in two projects of one workspace is an ordinary state, not a
  contrivance). The SAME principal — one workspace-scoped api token, so
  `check_same_actor/2` cannot be what refuses — opens project A's copy, clicks
  Simplify (a `simplify-request` row stamped `{ws, proj_a}`), then opens
  project B's copy and pushes `simplify-accept` naming project A's request id.

  `check_decision_type`, `check_actor`, `fetch_request`, `check_same_paper`
  (identical slug), `check_same_actor` (identical token), `check_fresh` and
  `check_undecided` all PASS. The workspace conjunct passes too — both mounts
  are the same workspace. Only the project conjunct can refuse.

  ## Verdict recorded by this file

  On the unmodified tree these tests PASS: the guard HOLDS on the real path —
  no live hole. Deleting `and request.project_id == fetch(attrs, "project_id")`
  from `events.ex` reds `test "a decision raised in project B cannot decide
  project A's request …"` — which is the reach claim: nothing else on the
  LiveView path fences the project rung.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Events

  @dataset "production"

  defp seed_paper!(slug, goal_id, ws, project, body) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "style" => "article",
          "goal_id" => goal_id,
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "body_html" => ~s(<p id="xproj-body">#{body}</p>)
        })
      )

    paper
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  # The scope the socket would stamp on anything it records: the RESOLVED
  # paper's own workspace/project, which is what `paper_goal_and_scope/3`
  # reads. Printed beside every assertion so a reader can see the two sides
  # of the fence actually differ on the project rung ONLY.
  defp socket_scope(view) do
    a = assigns_of(view)
    paper = BarkparkWeb.BulldocsLive.fetch_paper(a.slug, a[:reader_scope], a[:dataset])
    {paper && paper.workspace_id, paper && paper.project_id}
  end

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])

    ws = create_workspace!("xproj-ws-#{suffix}")
    proj_a = create_project!(ws, "xproj-a-#{suffix}")
    proj_b = create_project!(ws, "xproj-b-#{suffix}")

    slug = "xproj-paper-#{suffix}"
    goal_id = "g-xproj-#{suffix}"

    paper_a = seed_paper!(slug, goal_id, ws, proj_a, "Project A copy")
    paper_b = seed_paper!(slug, goal_id, ws, proj_b, "Project B copy")

    # The two copies really are two DISTINCT rows in ONE workspace, differing
    # on the project rung alone. Without this the whole scenario could be one
    # row resolved twice and every assertion below would be vacuous.
    assert paper_a.id != paper_b.id
    assert paper_a.workspace_id == paper_b.workspace_id
    assert paper_a.project_id == proj_a.id
    assert paper_b.project_id == proj_b.id
    assert paper_a.project_id != paper_b.project_id

    # ONE principal for BOTH mounts — a workspace-scoped token. Same actor on
    # the request and on the decision, so `check_same_actor/2` is not what
    # refuses.
    raw = "xproj-reader-#{suffix}"

    {:ok, _token} =
      Auth.create_token(raw, "cross-project reader", @dataset, ["read", "write"], ws.id)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    %{
      conn: conn,
      ws: ws,
      proj_a: proj_a,
      proj_b: proj_b,
      slug: slug,
      goal_id: goal_id,
      path_a: "/w/#{ws.slug}/p/#{proj_a.slug}/papers/#{slug}",
      path_b: "/w/#{ws.slug}/p/#{proj_b.slug}/papers/#{slug}"
    }
  end

  defp raise_request!(conn, path, slug, ws, proj) do
    {:ok, view, _html} = live(conn, path)

    view
    |> element(~s(button[phx-click="simplify-request"]))
    |> render_click()

    request =
      slug
      |> Events.list_for_paper(workspace_id: ws.id, project_id: proj.id)
      |> Enum.find(&(&1.event_type == "simplify-request"))

    {view, request}
  end

  describe "cross-PROJECT simplify decision over the real LiveView socket" do
    test "a decision raised in project B cannot decide project A's request — no authorized row lands",
         %{conn: conn, ws: ws, proj_a: proj_a, proj_b: proj_b, slug: slug, path_a: a, path_b: b} do
      {view_a, request} = raise_request!(conn, a, slug, ws, proj_a)

      assert request, "project A's simplify-request row must exist"
      assert request.workspace_id == ws.id
      assert request.project_id == proj_a.id

      before_rows = Events.list_for_paper(slug)
      # Non-vacuous: the unscoped read DOES see rows for this slug, so a
      # "count unchanged" assertion is measuring a populated table.
      assert length(before_rows) > 0

      {:ok, view_b, _html} = live(conn, b)

      # THE TWO SIDES OF THE FENCE, printed.
      IO.puts("""

      [task-369bfc803e02fe0d] end-to-end scope fence
        request row  : workspace=#{request.workspace_id} project=#{request.project_id}
        socket A     : #{inspect(socket_scope(view_a))}
        socket B     : #{inspect(socket_scope(view_b))}
        workspace equal? #{elem(socket_scope(view_a), 0) == elem(socket_scope(view_b), 0)}
        project  equal? #{elem(socket_scope(view_a), 1) == elem(socket_scope(view_b), 1)}
      """)

      # The socket in project B resolves the SAME workspace and a DIFFERENT
      # project — the project conjunct is the only discriminator left.
      assert elem(socket_scope(view_b), 0) == request.workspace_id
      refute elem(socket_scope(view_b), 1) == request.project_id

      # The actor is IDENTICAL on both sockets (one token), so a refusal
      # cannot come from `check_same_actor/2`.
      assert assigns_of(view_b).viewer == assigns_of(view_a).viewer

      rendered = render_click(view_b, "simplify-accept", %{"request-id" => request.id})

      # The UI refuses.
      assert rendered =~ "not yours to decide"

      # STATE, not flash. No decision row exists anywhere for this slug …
      decisions =
        slug
        |> Events.list_for_paper()
        |> Enum.filter(&(&1.event_type in ["simplify-accept", "simplify-reject"]))

      assert decisions == []

      # … nothing is tied to project A's request …
      refute Enum.any?(Events.list_for_paper(slug), &(&1.request_event_id == request.id))

      # … no authorized row landed in project B's scope …
      assert Events.decision_audit(slug, workspace_id: ws.id, project_id: proj_b.id) == []
      assert Events.decision_audit(slug, workspace_id: ws.id, project_id: proj_a.id) == []

      # … and the history did not grow at all.
      assert length(Events.list_for_paper(slug)) == length(before_rows)
    end

    test "POSITIVE CONTROL: the same actor deciding IN project A does land, authorized",
         %{conn: conn, ws: ws, proj_a: proj_a, slug: slug, path_a: a} do
      {view_a, request} = raise_request!(conn, a, slug, ws, proj_a)

      render_click(view_a, "simplify-accept", %{"request-id" => request.id})

      accept =
        slug
        |> Events.list_for_paper(workspace_id: ws.id, project_id: proj_a.id)
        |> Enum.find(&(&1.event_type == "simplify-accept"))

      assert accept,
             "the in-project decision MUST land — otherwise the refusal above proves nothing"

      assert accept.request_event_id == request.id
      assert accept.authorization == "authorized"
      assert Events.authoritative_decision?(accept)

      audit = Events.decision_audit(slug, workspace_id: ws.id, project_id: proj_a.id)
      assert [%{authoritative?: true, request_event_id: rid}] = audit
      assert rid == request.id
    end

    test "SYMMETRY: a request raised in project B cannot be decided from project A either",
         %{conn: conn, ws: ws, proj_b: proj_b, slug: slug, path_a: a, path_b: b} do
      {_view_b, request} = raise_request!(conn, b, slug, ws, proj_b)

      assert request.project_id == proj_b.id

      {:ok, view_a, _html} = live(conn, a)
      rendered = render_click(view_a, "simplify-accept", %{"request-id" => request.id})

      assert rendered =~ "not yours to decide"
      refute Enum.any?(Events.list_for_paper(slug), &(&1.request_event_id == request.id))
      assert Events.decision_audit(slug, workspace_id: ws.id, project_id: proj_b.id) == []
    end
  end
end
