defmodule BarkparkWeb.Studio.PdsW43CapsReadonlyShareTest do
  @moduledoc """
  pds-w43-caps-readonly-share-write-bypass (PDS-D635) — a READ-ONLY SHARE
  posture used to lose to `caps.write`.

  MECHANISM (source, not prose). `Caps.write_capable?/2` tested
  `Map.get(caps, :write) == true` BEFORE `restricted?/1`, and `Caps.derive/1`
  computes `write` from membership+grants ONLY — it never reads `share_access`,
  `readonly_gate?`, `write_gate?` or `caller_context`. So a socket that is BOTH
  read-only by POSTURE and holds a write SOURCE short-circuited past its own
  restriction, and the predicate's docstring ("a RESTRICTED socket does not
  [pass]") was false for it.

  REACHABLE WITHOUT ANY ADMIN STEP. `LiveScope.authorize_read/4` offers the
  public-share arm BEFORE the grant arm (deliberately — "grants only ADD
  access, never REMOVE it"), so a signed-in NON-MEMBER holding an ACTIVE WRITE
  GRANT who mounts a desk that is also `:docs`-shared read-only is graded
  `:share_read`: `share_access: :read`, `readonly_gate?: true`, and NO
  `caller_context`, NO `write_gate?` — so neither `Content.Scope.scope_to_grants/3`'s
  read-narrowing nor the per-event `Access.validate/3` write-narrowing is armed,
  while `derive/1` still returns `write: true`. The write lands through the
  paper editor's component route (`inner-change` at `#paper-fb-<id>` →
  `send(self(), {:paper_op, op})` → `handle_info` → `Shared.Paper.paper_pane_op/2`
  → `write_denied?/1` → `Caps.write_capable?/2`), which is exactly where the
  predicate is the only thing standing.

  AND IT ESCALATED: a write grant naming ONE doc wrote a DIFFERENT paper on the
  same desk, because `Access.admits_desk?/3` auto-satisfies the grant's own
  type/doc_id and defers the narrowing to a mechanism this grade never arms.

  THE FIX IS NARROW, NOT THE OBVIOUS REORDER. Hoisting `restricted?/1` whole
  would also deny GRANT-graded sockets (`write_gate?` / `caller_context`),
  whose narrowing IS armed. So only a `readonly_posture?/1` arm moved above
  `caps.write`; the last describe here pins that a grant-graded socket still
  writes.

  WHAT THIS SUITE DOES **NOT** SAY: nothing here clears the pure `{:grant, ctx}`
  grade of the component-route bypass — `pds-w42-bl-grant-graded-component-arm-unbuilt`
  stays open. This file proves the grant grade is not DENIED by the fix, which
  is a different claim.

  `async: false` — the `:shares` registry and the paper-canvas flag are
  process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @block_id "fb-price"
  @orig %{"amount" => "299", "currency" => "NOK"}
  @attempt %{"amount" => "REACHED", "currency" => "NOK"}
  @deny_flash "You don't have access to do that."

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    # THE DEFAULT canvas editor, pinned rather than inherited. Two reasons it
    # must not be the legacy per-block editor: (a) canvas-on is the default
    # posture, and (b) reaching the legacy editor needs `paper-toggle-edit`,
    # which `LiveScope`'s readonly gate HALTS on a share_read socket — so a
    # canvas-off run would never render the component and every "the write did
    # not land" assertion below would pass VACUOUSLY, against a pane that was
    # not there.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # arpss-w8: snapshots :shares AND :shares_env (Sharing.refresh/0 reads both).
    Barkpark.SharingFixtures.snapshot_shares!()

    # A NON-default workspace. The Default workspace is an open public-demo in
    # test (`public_demo_studio: true`), and that arm is offered BEFORE the
    # share arm — a share on Default would never produce the `:share_read`
    # grade this suite is about.
    ws = create_workspace!("w43-share-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "w43-proj")

    # The desk is `:docs`-shared READ-ONLY. This is the whole precondition:
    # a scope any signed-in user may READ, which the grant arm never gets to
    # narrow because the share arm answered first.
    Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")

    seed_paper_schema!(ws, proj)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # Schemas are TENANT-SCOPED, so the private workspace needs its own `paper`
  # schema row — without it the desk has no paper type and the editor pane
  # never opens (the suite would then pass vacuously, asserting a write did not
  # land on a pane that was not there).
  defp seed_paper_schema!(ws, proj) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )
  end

  # A paper carrying ONE v2 `composite` field block — the block kind that
  # renders as a nested `PaperFieldBlock` LiveComponent, and a canvas run
  # BOUNDARY, so this component is its editor under BOTH canvas settings.
  defp create_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W43"},
      %{
        "id" => @block_id,
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => @orig
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "blocks" => blocks,
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  # The composite block's value as PERSISTED STATE would report it — read back
  # from the store, never from an assign, so the assertion is falsifiable in
  # both directions.
  defp stored_value(ws, proj, slug) do
    paper = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id)

    blocks =
      get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  # A signed-in, NON-member USER (no membership row anywhere near `ws`).
  defp user_session(conn) do
    email = "w43-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp paper_rev(view), do: socket_of(view).assigns.paper_rev
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # The component event, THEN a round-trip on the parent. `persist/2` does
  # `send(self(), {:paper_op, …})`, so the write happens in a LATER
  # `handle_info` — reading the store straight after `render_hook/3` reads it
  # BEFORE the message is processed and reports a false "no write". The
  # trailing `render/1` forces the parent to drain its mailbox first.
  # THE ANTI-VACUITY GUARD. `with_target/2` on an id that is not in the DOM
  # does not fail — the event falls through to the parent LiveView, which logs
  # "unhandled event" and writes nothing, and the "store unchanged" assertion
  # then passes for the wrong reason. So every drive asserts the component is
  # rendered first.
  defp assert_editor_rendered!(view) do
    assert render(view) =~ ~s(id="paper-fb-#{@block_id}")
    :ok
  end

  defp inner_change(view, params) do
    assert_editor_rendered!(view)

    target = with_target(view, "#paper-fb-" <> @block_id)
    render_hook(target, "inner-change", params)

    render_hook(target, "inner-flush", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "values" => params
    })

    render(view)
    :ok
  end

  # `write_capable?/2` AS IT STOOD BEFORE THIS SLICE, transcribed from
  # `lib/barkpark_web/studio/caps.ex` at the parent commit: the identical cond
  # minus the `readonly_posture?/1` arm. It lives here, not in the lib, so the
  # bypass stays reproducible without shipping the hole — and so criterion 1
  # ("the pre-fix predicate returned true") is proven by RUN rather than by
  # git archaeology.
  defp pre_fix_write_capable?(assigns, caps) do
    cond do
      Map.get(caps, :write) == true -> true
      pre_fix_restricted?(assigns) -> false
      pre_fix_has_principal?(assigns) -> false
      true -> true
    end
  end

  defp pre_fix_restricted?(assigns) do
    Map.get(assigns, :readonly_gate?) == true or
      Map.get(assigns, :write_gate?) == true or
      not is_nil(Map.get(assigns, :caller_context)) or
      Map.get(assigns, :share_access) == :read
  end

  defp pre_fix_has_principal?(assigns) do
    not is_nil(Map.get(assigns, :api_token)) or not is_nil(Map.get(assigns, :current_user))
  end

  # ── 1. the grade, the derive map, and both predicates ───────────────────────

  describe "a share_read socket holding an ACTIVE WRITE GRANT" do
    test "mounts as :share_read with write: true — and the PRE-FIX predicate passed it", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      slug = "w43-grade"
      create_paper!(ws, proj, slug)

      {user, conn} = user_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"]})

      view = open_paper!(conn, ws, proj, slug)
      assigns = socket_of(view).assigns

      # THE GRADE, from the live socket. `:share_read` and nothing else: no
      # caller_context (so `scope_to_grants/3` never narrows the reads) and no
      # write_gate? (so `Access.validate/3` never narrows the writes).
      assert assigns[:share_access] == :read
      assert assigns[:readonly_gate?] == true
      assert assigns[:caller_context] == nil
      assert assigns[:write_gate?] == nil
      assert %Barkpark.Accounts.User{} = assigns[:current_user]

      # THE DERIVE MAP. `write` is TRUE — derive/1 is an authority function and
      # this slice deliberately does NOT make it lie: the grant really does
      # confer write in this workspace. Posture is the gate's job, not
      # derive's.
      caps = Caps.derive(socket_of(view))
      assert caps.read == true
      assert caps.write == true
      assert caps.admin == false

      # THE BYPASS, REPRODUCED. The pre-fix cond hit `caps.write == true`
      # first and returned TRUE for this exact socket.
      assert pre_fix_write_capable?(assigns, caps) == true

      # THE FIX. Same assigns, same caps, shipped predicate.
      assert Caps.write_capable?(assigns, caps) == false
    end

    test "the component route no longer writes — stored block UNCHANGED, deny flash raised", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      slug = "w43-component"
      create_paper!(ws, proj, slug)

      {user, conn} = user_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"]})

      view = open_paper!(conn, ws, proj, slug)
      assert Caps.write_capable?(socket_of(view).assigns, Caps.derive(socket_of(view))) == false

      # Denied WRITE is not denied READ: the paper and its editor render.
      assert render(view) =~ "W43"
      assert_editor_rendered!(view)

      before_write = stored_value(ws, proj, slug)
      assert before_write == @orig

      inner_change(view, @attempt)

      # NON-VACUOUS: read back from the STORE, bound to a variable so a
      # regression prints `left: %{"amount" => "REACHED", …}`.
      after_component_event = stored_value(ws, proj, slug)
      assert after_component_event == @orig
      assert flash_error(view) == @deny_flash
    end

    test "a PROJECT-scoped write grant is refused the same way (grant breadth is not the reason)",
         %{conn: conn, ws: ws, proj: proj} do
      slug = "w43-canvas"
      create_paper!(ws, proj, slug)

      {user, conn} = user_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"], project_id: proj.id})

      view = open_paper!(conn, ws, proj, slug)

      inner_change(view, @attempt)

      after_component_event = stored_value(ws, proj, slug)
      assert after_component_event == @orig
    end
  end

  # ── 2. the doc-scoped ESCALATION ────────────────────────────────────────────

  describe "a write grant naming ONE doc" do
    test "no longer writes a DIFFERENT paper on the same desk", %{conn: conn, ws: ws, proj: proj} do
      create_paper!(ws, proj, "w43-granted-doc")
      create_paper!(ws, proj, "w43-other-doc")

      {user, conn} = user_session(conn)

      # The narrowest write grant the ladder allows: ONE type, ONE doc.
      # `Access.admits_desk?/3` auto-satisfies the grant's OWN type/doc_id at
      # desk granularity, so `derive/1` still reports write: true here — the
      # per-doc narrowing was supposed to happen in a mechanism the
      # `:share_read` grade never arms.
      bind_grant!(ws, user, %{
        capabilities: ["read", "write"],
        project_id: proj.id,
        dataset: @dataset,
        type: "paper",
        doc_id: "w43-granted-doc"
      })

      view = open_paper!(conn, ws, proj, "w43-other-doc")

      caps = Caps.derive(socket_of(view))
      assert caps.write == true
      assert pre_fix_write_capable?(socket_of(view).assigns, caps) == true

      inner_change(view, %{"amount" => "ESCALATED", "currency" => "NOK"})

      stored_other = stored_value(ws, proj, "w43-other-doc")
      assert stored_other == @orig
    end
  end

  # ── 3. both controls ────────────────────────────────────────────────────────

  describe "controls" do
    test "NEGATIVE: an identical setup with a READ-only grant is still refused", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      slug = "w43-neg"
      create_paper!(ws, proj, slug)

      {user, conn} = user_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      view = open_paper!(conn, ws, proj, slug)
      caps = Caps.derive(socket_of(view))

      # The control's whole point: this one was ALREADY denied before the fix
      # (no write source at all), so it cannot be the reason the positive case
      # passes.
      assert caps.write == false
      assert Caps.write_capable?(socket_of(view).assigns, caps) == false

      inner_change(view, @attempt)

      stored_negative_control = stored_value(ws, proj, slug)
      assert stored_negative_control == @orig
    end

    test "POSITIVE: an admin MEMBER (share_access nil) still writes", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      slug = "w43-pos"
      create_paper!(ws, proj, slug)

      {user, conn} = user_session(conn)
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "admin", "user")

      view = open_paper!(conn, ws, proj, slug)
      assigns = socket_of(view).assigns

      # The member arm answers BEFORE the share arm, so the very same shared
      # desk grades `:member` for this principal: no read-only posture at all.
      assert assigns[:share_access] == nil
      assert assigns[:readonly_gate?] == nil

      caps = Caps.derive(socket_of(view))
      assert caps.write == true
      assert Caps.write_capable?(assigns, caps) == true

      inner_change(view, @attempt)

      stored_positive_control = stored_value(ws, proj, slug)
      assert stored_positive_control == @attempt
    end
  end

  # ── 4. the fix is not a blanket reorder ─────────────────────────────────────

  describe "GRANT grades are not denied by the fix" do
    test "a REAL grant-graded socket (caller_context, no read-only posture) still writes", %{
      conn: conn
    } do
      # An UNSHARED private workspace: the share arm cannot answer, so a
      # non-member with a write grant lands on `{:grant, ctx}` — the grade
      # whose read-narrowing (`scope_to_grants/3`) and per-event write-
      # narrowing (`Access.validate/3`) ARE armed, and which a wholesale
      # `restricted?/1` hoist would have wrongly denied.
      unshared_ws = create_workspace!("w43-unshared-#{System.unique_integer([:positive])}")
      unshared_proj = create_project!(unshared_ws, "w43-unshared-proj")
      seed_paper_schema!(unshared_ws, unshared_proj)

      {user, conn} = user_session(conn)
      bind_grant!(unshared_ws, user, %{capabilities: ["read", "write"]})

      {:ok, view, _html} =
        live(conn, "/w/#{unshared_ws.slug}/p/#{unshared_proj.slug}/d/#{@dataset}/studio")

      assigns = socket_of(view).assigns

      assert assigns[:share_access] == nil
      assert assigns[:readonly_gate?] == nil
      refute is_nil(assigns[:caller_context])

      caps = Caps.derive(socket_of(view))
      assert caps.write == true

      # THE PREDICATE RESULT FOR THAT SHAPE — unchanged by the fix, and
      # identical to what the pre-fix cond answered.
      grant_grade_predicate = Caps.write_capable?(assigns, caps)
      assert grant_grade_predicate == true
      assert pre_fix_write_capable?(assigns, caps) == true

      # A real write on that socket still persists.
      before_count = Barkpark.Repo.aggregate(Content.Document, :count)
      render_click(view, "new-document", %{"type" => "paper"})
      assert Barkpark.Repo.aggregate(Content.Document, :count) > before_count
    end

    test "a write_gate? socket without a read-only posture still passes the predicate" do
      # The other armed grade, as a pure predicate case: `write_gate?` is set by
      # `LiveScope` for a grant-graded socket that HAS a write-capable grant, and
      # its per-event `Access.validate/3` narrowing is what contains it. The fix
      # must not touch it.
      assigns = %{
        write_gate?: true,
        share_access: nil,
        readonly_gate?: nil,
        caller_context: nil,
        current_user: %Barkpark.Accounts.User{id: Ecto.UUID.generate()}
      }

      write_gate_predicate =
        Caps.write_capable?(assigns, %{read: true, write: true, admin: false})

      assert write_gate_predicate == true
    end
  end
end
