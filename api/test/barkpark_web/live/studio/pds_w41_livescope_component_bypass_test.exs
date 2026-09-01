defmodule BarkparkWeb.Studio.PdsW41LiveScopeComponentBypassTest do
  @moduledoc """
  pds-bl-w41-livescope-component-bypass-unrun — the RUN the wave-41 claim never
  had.

  Wave 41 proved BY RUN that a `phx-target`ed event bypasses `Caps`' socket-level
  `:studio_caps_gate` (PDS-D596), and closed it by sending the capability INTO
  the component as `write_capable`. The generalisation to `LiveScope`'s two
  hooks — `:live_scope_readonly` and `:live_scope_write_scope` — was asserted
  from `phoenix_live_view/channel.ex` source only. This file runs it.

  ## ⚠ THIS SUITE CONTAINS A REPRODUCTION, NOT ONLY REGRESSION PROOF

  The test named "…and the COMPONENT route WRITES" asserts that the escalated
  bytes REACH THE STORE. It is GREEN because the bypass is REAL and OPEN. When
  the fix lands, that assertion must be INVERTED (store stays `@orig`) — a red
  there is the FIX arriving, not a regression. Every OTHER test in this file is
  an ordinary standing regression proof and must stay green.

  ## What the run finds — three different answers, one per grade

    * `:share_read` (`:live_scope_readonly`) — GATED. Not by the hook (the hook
      really is unreachable from a component event) but by the D596 prop:
      `Caps.write_capable?/2`'s `readonly_posture?/1` arm reads
      `share_access: :read`, so the component receives `write_capable: false`
      and `SheetGrid.Ops.send_ops/2`'s last wall drops the op.

    * `{:grant, ctx}` with a READ-only grant (`:live_scope_readonly`) — GATED,
      same mechanism via `readonly_gate?: true`.

    * `{:grant, ctx}` with a WRITE grant NARROWER than the desk
      (`:live_scope_write_scope`) — **BYPASSED**. This hook is not a presence
      check, it is a per-event TARGET check: it resolves
      `%{workspace_id, project_id, dataset, type, doc_id}` from the loaded
      editor doc and requires `Access.validate(grant, :write, target) == :ok`.
      The D596 prop cannot reproduce that answer, because
      `Caps.write_capable?/2` takes NO target: it short-circuits on
      `caps.write == true`, and `Caps.derive/1` computes `write` through
      `Access.admits_desk?/3`, which OVERWRITES the request's `type`/`doc_id`
      with the GRANT'S OWN (access.ex:329-336) before validating. A doc-scoped
      write grant therefore self-satisfies at desk granularity and the prop
      arrives `true` on EVERY sheet of the desk.

  So the bypass is REAL, and it is a GRANULARITY gap, not a missing gate:
  socket route = doc-granular, component route = desk-granular.

  This is the SHEET twin of `pds_w44_grant_door_test.exs`, which found and
  closed the same gap on the PAPER route via
  `Shared.Paper.grant_target_denied?/3`. `grep -rn 'grant_target_denied?' lib/`
  returns `shared/paper.ex` only — the sheet surface has no such door, and
  `SheetGrid.Ops.send_ops/2`'s `write_capable: false` wall is the only thing
  between this principal and the Sheets session.

  ## `StudioChrome`'s `:studio_chrome_nav` — the third hook the row names

  Equally unreachable, and the run PROVES the mechanism: a `scope-open` event
  routed at the component dies with `:function_clause` in
  `SheetGrid.handle_event/3`, through
  `Phoenix.LiveView.Channel.inner_component_handle_event/4` — the cid branch,
  with the parent's hook list never consulted. But that hook gates NAVIGATION
  events and NO Studio LiveComponent implements one (the whole set is
  `SheetGrid`, `PaperFieldBlock`, `GraphView`), so there is nothing to bypass it
  WITH. The sheet finding does NOT transfer to `:studio_chrome_nav`.

  ## The oracle is PERSISTED STATE, never a flash

  Every assertion reads A1 back through `Session.peek/2` (a live session's
  memory is authoritative when one exists) falling back to the stored row. A
  refute-on-absence under async logging would prove nothing; these assert on
  PRESENCE — the escalated bytes ARE in the store on the bypass path, and the
  original bytes ARE still there on the gated paths, printed by value on
  failure.

  `async: false` — sheet sessions are globally-registered processes reading
  through the SQL sandbox in shared mode, same as the sibling SheetGrid suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @granted_slug "w41cb-granted-sheet"
  @other_slug "w41cb-other-sheet"
  @orig %{"v" => "orig"}
  @escalated "1337"
  @outside_grant_flash "That action is outside your access grant's scope"

  setup %{conn: conn} do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # No debounce-driven persistence race: the session holds the write in
    # memory and `Session.peek/2` is the authoritative read while it lives.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)

    # An UNSHARED, NON-default workspace: unshared so `Sharing.shared?/4` cannot
    # answer before the grant arm, non-default because the Default workspace is
    # an open public-demo posture in test.
    ws = create_workspace!("w41cb-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "w41cb-proj")
    seed_sheet_schema!(ws, proj)

    create_sheet!(ws, proj, @granted_slug)
    create_sheet!(ws, proj, @other_slug)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # Schemas are TENANT-SCOPED: without a `sheet` schema row in THIS workspace the
  # desk has no sheet type and the editor pane never opens — every "the store did
  # not change" assertion would then pass for the wrong reason.
  defp seed_sheet_schema!(ws, proj) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )
  end

  defp create_sheet!(ws, proj, slug) do
    content = %{
      "locale" => "nb-NO",
      "tabs" => [%{"name" => "Data", "cells" => %{"A1" => @orig}}]
    }

    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => content},
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    null_dataset_id!(doc)
  end

  # WHY THE ROW'S `dataset_id` IS NULLED (a real, separate defect this suite had
  # to route around — NOT a relaxation of anything under test).
  #
  # `Sheets.Session.load_doc/2` (session.ex:749) calls `Content.get_document/3`
  # with NO scope opts. `WriteScope.resolve_read_dataset_id/2` then falls back to
  # the SEEDED DEFAULT project (write_scope.ex:315-320, the `true ->` arm, taken
  # because the caller passed no `:workspace_id` key at all) and returns the
  # DEFAULT project's `dataset_id`. `Query.scope_to_dataset/3` applies that as
  # `dataset_id == default_ds_id or (is_nil(dataset_id) and dataset == "production")`.
  # A sheet stamped with a NON-Default workspace's own `production` dataset row
  # matches NEITHER arm, so the session gets `{:error, :not_found}`, never starts,
  # and `SheetGrid.Ops.send_ops/2` reports `notice: "edit failed: :not_found"`.
  # Observed verbatim on the first run of this suite.
  #
  # Consequence: without this line every "the store did not change" assertion
  # below would pass VACUOUSLY — not because a gate held, but because the Sheets
  # session cannot open the sheet at all. Nulling `dataset_id` puts the row in
  # the LEGACY shape the same query explicitly tolerates, which BOTH the scoped
  # desk read (project-scoped: `dataset_id == ws_ds_id OR is_nil(dataset_id)`)
  # and the session's unscoped read admit.
  #
  # It touches NO authorization axis: `workspace_id`, `project_id` and the grant
  # ladder are untouched, and `Access.validate/3` compares the `dataset` STRING
  # (`socket.assigns[:dataset]`), never `dataset_id`.
  defp null_dataset_id!(doc) do
    import Ecto.Query

    {1, _} =
      Barkpark.Repo.update_all(
        from(d in Barkpark.Content.Document, where: d.id == ^doc.id),
        set: [dataset_id: nil]
      )

    doc
  end

  # ── the principals ──────────────────────────────────────────────────────────

  defp user_session(conn) do
    email = "w41cb-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # THE ESCALATING POPULATION (same shape as pds_w44_grant_door_test):
  #   * a PROJECT-scoped READ grant — the READ REACH. Without it
  #     `Content.Scope.scope_to_grants/3` hides the non-granted sheet, the pane
  #     never loads, and "store unchanged" would prove nothing.
  #   * a DOC-scoped WRITE grant naming exactly ONE sheet — the write source
  #     `Access.admits_desk?/3` auto-satisfies at desk granularity.
  defp write_grantee_session(conn, ws, proj) do
    {user, conn} = user_session(conn)

    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

    bind_grant!(ws, user, %{
      capabilities: ["read", "write"],
      project_id: proj.id,
      dataset: @dataset,
      type: "sheet",
      doc_id: @granted_slug
    })

    {user, conn}
  end

  # A grantee with NO write grant anywhere — LiveScope grades this
  # `{:grant, ctx}` and attaches `:live_scope_readonly` (`readonly_gate?: true`).
  defp read_grantee_session(conn, ws, proj) do
    {user, conn} = user_session(conn)
    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})
    {user, conn}
  end

  defp open_sheet!(conn, ws, proj, slug) do
    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/sheet/#{slug}")

    {view, html}
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # The SheetGrid LiveComponent's OWN socket assigns, read out of the channel's
  # component store. This is how the suite proves the component received the
  # capability prop and processed the cid-routed event — a parent-socket read
  # cannot tell those apart.
  defp component_assigns(view) do
    {cid_map, _, _} = :sys.get_state(view.pid).components

    Enum.find_value(cid_map, fn
      {_cid, {BarkparkWeb.Studio.SheetGrid, _id, assigns, _private, _}} -> assigns
      _ -> nil
    end)
  end

  # ── the oracle ──────────────────────────────────────────────────────────────

  # A1 as PERSISTED STATE reports it. A live session's memory is authoritative
  # when one exists; with no session the stored document is the truth. Reading
  # both ways is what makes the assertion falsifiable in either direction — a
  # write that starts a session is caught, and so is one that never does.
  defp persisted_a1(slug) do
    cells =
      case Session.peek(slug, @dataset) do
        {:ok, content} ->
          get_in(content, ["tabs", Access.at(0), "cells"]) || %{}

        {:error, :no_session} ->
          get_in(stored_content(slug), ["tabs", Access.at(0), "cells"]) || %{}
      end

    Map.get(cells, "A1")
  end

  defp stored_content(slug) do
    import Ecto.Query

    Barkpark.Content.Document
    |> where([d], d.doc_id in ^[slug, "drafts." <> slug] and d.type == "sheet")
    |> Barkpark.Repo.all()
    |> Enum.map(& &1.content)
    |> Enum.find(%{}, &is_map/1)
  end

  # THE ANTI-VACUITY GUARD. `with_target/2` on an id that is NOT in the DOM does
  # not fail — the event falls through to the parent, which has no `edit-commit`
  # head, and the run would report a bypass-that-wasn't (or a gate-that-wasn't).
  # Every route through the component asserts the grid rendered FIRST.
  defp grid_target!(view, slug) do
    assert render(view) =~ ~s(id="sheet-grid-#{slug}")
    with_target(view, "#sheet-grid-#{slug}")
  end

  # The real component route: select the cell, then commit a value into it.
  defp component_write(view, slug, value) do
    target = grid_target!(view, slug)
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => value, "move" => "none"})
    render(view)
    :ok
  end

  # ── 1. the grade, reproduced from the LIVE socket ───────────────────────────

  describe "the socket grade a DOC-scoped write grantee actually mounts with" do
    test "is {:grant, ctx} with :live_scope_write_scope armed and no read-only posture", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = write_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @other_slug)
      assigns = socket_of(view).assigns

      # The armed grade. `write_gate?` is the assign `attach_write_gate/2` sets
      # alongside `attach_hook(:live_scope_write_scope, :handle_event, …)`, so
      # this IS the hook's presence, read off the running socket.
      refute is_nil(assigns[:caller_context])
      assert assigns[:write_gate?] == true
      assert assigns[:share_access] == nil
      assert assigns[:readonly_gate?] == nil
      assert %Barkpark.Accounts.User{} = assigns[:current_user]

      # READ REACH on the NON-granted sheet — required, or the write below would
      # be a no-op against an unloaded pane.
      assert Content.published_id(assigns[:sheet_doc].doc_id) == @other_slug
      assert assigns[:editor_type] == "sheet"

      # THE GRANULARITY GAP, stated as two values from the running socket: the
      # prop the component receives is `true`, while the socket-level hook's own
      # predicate on this exact target is `{:error, :forbidden}`.
      caps = Caps.derive(socket_of(view))
      assert caps.write == true
      assert Caps.write_capable?(assigns, caps) == true

      target = %{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        type: "sheet",
        doc_id: @other_slug
      }

      refute Enum.any?(
               assigns[:caller_context].grants,
               &(Barkpark.Access.validate(&1, :write, target) == :ok)
             )
    end
  end

  # ── 2. THE BYPASS: same socket, same sheet, two routes ──────────────────────

  describe "component-targeted write vs :live_scope_write_scope" do
    @tag :reproduction
    test "REPRODUCTION: SOCKET route is HALTED by the hook, and the COMPONENT route WRITES", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = write_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @other_slug)

      assert persisted_a1(@other_slug) == @orig

      # ROUTE A — straight at the LiveView. `save` classifies `:write` and
      # `Caps` PASSES it (caps.write is true), so the halt below is
      # `:live_scope_write_scope`'s and nothing else's: it resolved the target
      # to the NON-granted sheet and no grant validated.
      render_hook(view, "save", %{"document" => %{}})
      assert flash_error(view) == @outside_grant_flash
      assert persisted_a1(@other_slug) == @orig

      # ROUTE B — the SAME socket, the SAME sheet, targeted at the component.
      # The parent's hook list is never consulted on this path; the only wall is
      # the `write_capable` prop, which is desk-granular and says `true`.
      #
      component_write(view, @other_slug, @escalated)

      # THE ORACLE: persisted state, by value. Bound to a variable so a
      # regression prints `left: %{"v" => "orig"}` rather than a custom message.
      after_component_event = persisted_a1(@other_slug)

      assert after_component_event == %{"v" => 1337},
             "the component route did not write; the bypass did not reproduce"

      # …and the value the two routes disagree about, read off the COMPONENT's
      # own socket: the capability really arrived `true` here while the socket
      # hook's own predicate on the same target is `{:error, :forbidden}`.
      assert component_assigns(view)[:write_capable] == true

      # And the SOCKET route still refuses the same target on the same socket —
      # the two routes disagree, which is the finding.
      assert flash_error(view) == @outside_grant_flash
    end

    test "the sheet the grant DOES name is written too — the prop is not blanket-open", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = write_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @granted_slug)

      # PROOF THE COMPONENT HANDLER RUNS (not a silent fall-through to the
      # parent): C3 is not the mount default, so a changed `active` on the
      # COMPONENT socket is presence-evidence that the cid-routed event was
      # dispatched into `SheetGrid.handle_event/3`.
      render_hook(grid_target!(view, @granted_slug), "cell-click", %{
        "ref" => "C3",
        "shift" => false
      })

      assert component_assigns(view)[:active] == {3, 3}

      component_write(view, @granted_slug, @escalated)

      assert persisted_a1(@granted_slug) == %{"v" => 1337}

      # The capability really did travel in as a prop, and the write path
      # reported no error (a `notice` here is how the first run of this suite
      # surfaced the session's `:not_found`, see `null_dataset_id!/1`).
      assert component_assigns(view)[:write_capable] == true
      assert component_assigns(view)[:notice] == nil
    end
  end

  # ── 3. the OTHER two grades: :live_scope_readonly, and share-read ───────────
  #
  # These are the grades the row names first. They are GATED — not by the hook
  # (which really is unreachable here) but by the D596 prop reading the
  # read-only POSTURE. Asserting them keeps the finding honest: the bypass is
  # the write-SCOPE hook's granularity, not LiveScope's read-only gates.

  describe "a READ-only grantee (:live_scope_readonly) through the component" do
    test "is GATED — write_capable is false and the stored bytes are unchanged", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = read_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @other_slug)
      assigns = socket_of(view).assigns

      assert assigns[:readonly_gate?] == true
      assert Caps.write_capable?(assigns, Caps.derive(socket_of(view))) == false

      # NON-VACUITY: the component IS reachable (a non-default cell selection
      # lands on its own socket) and it received `write_capable: false`. So the
      # unchanged store below is a REFUSAL, not an undelivered event.
      render_hook(grid_target!(view, @other_slug), "cell-click", %{
        "ref" => "C3",
        "shift" => false
      })

      assert component_assigns(view)[:active] == {3, 3}

      component_write(view, @other_slug, @escalated)

      # THE ORACLE FIRST — persisted state, by value. Revert the capability at
      # the SheetGrid callsite (`write_capable={true}`) and THIS line reds with
      # `left: %{"v" => 1337}`; the mechanism assertion below reds too, but the
      # store is the one that matters and it must be the one that speaks.
      assert persisted_a1(@other_slug) == @orig

      # …and the MECHANISM that held it: the capability the component itself
      # received.
      assert component_assigns(view)[:write_capable] == false
    end
  end

  # ── 4. StudioChrome's :studio_chrome_nav — the third hook the row names ─────

  describe "StudioChrome's :studio_chrome_nav on the component route" do
    @tag :capture_log
    test "is equally unreachable — but has NO component surface to be bypassed FROM", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      Process.flag(:trap_exit, true)

      {_user, conn} = write_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @other_slug)

      # `scope-open` is a `:studio_chrome_nav` event. Routed at the LiveView the
      # hook SEES it and HALTs it — the socket survives and the menu state moves.
      render_hook(view, "scope-open", %{})
      assert Process.alive?(view.pid)

      # Routed at the COMPONENT, the SAME event never reaches that hook. It is
      # dispatched straight into `SheetGrid.handle_event/3`, which has no clause
      # for it, and the LiveView dies with a `:function_clause` NAMING the
      # component function. That crash is the run-proof for this hook: the stack
      # is `Phoenix.LiveView.Channel.inner_component_handle_event/4`, i.e. the
      # cid branch — the parent's hook list was never consulted.
      target = grid_target!(view, @other_slug)

      assert {{:function_clause, stack}, _} = catch_exit(render_hook(target, "scope-open", %{}))

      # The dispatch target, NAMED by the runtime: the component's own
      # `handle_event/3`…
      assert [{BarkparkWeb.Studio.SheetGrid, :handle_event, ["scope-open" | _], _} | _] = stack

      # …reached through the CID branch of the channel. This frame is the whole
      # mechanism the row asked to see RUN rather than read.
      assert Enum.any?(stack, fn
               {Phoenix.LiveView.Channel, fun, _, _} ->
                 fun |> Atom.to_string() |> String.contains?("inner_component_handle_event")

               _ ->
                 false
             end)

      # THE VERDICT FOR THIS HOOK: unreachable, yes — but `:studio_chrome_nav`
      # gates NAVIGATION events, and no Studio LiveComponent implements one, so
      # there is nothing to bypass it WITH. The sheet finding above does NOT
      # transfer to `:studio_chrome_nav`; it needed a component that WRITES.
      assert persisted_a1(@other_slug) == @orig
    end
  end

  describe "a share-read viewer through the component" do
    setup %{ws: ws, proj: proj} do
      prior = Application.get_env(:barkpark, :shares)

      Application.put_env(
        :barkpark,
        :shares,
        Barkpark.Sharing.parse("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")
      )

      on_exit(fn ->
        if is_nil(prior),
          do: Application.delete_env(:barkpark, :shares),
          else: Application.put_env(:barkpark, :shares, prior)
      end)

      assert Barkpark.Sharing.shared?(ws.slug, proj.slug, @dataset, :docs)
      :ok
    end

    test "is GATED — share_access :read makes write_capable false", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {view, _html} = open_sheet!(conn, ws, proj, @other_slug)
      assigns = socket_of(view).assigns

      assert assigns[:share_access] == :read
      assert assigns[:readonly_gate?] == true
      assert Caps.write_capable?(assigns, Caps.derive(socket_of(view))) == false

      # NON-VACUITY: the component IS reachable (a non-default cell selection
      # lands on its own socket) and it received `write_capable: false`. So the
      # unchanged store below is a REFUSAL, not an undelivered event.
      render_hook(grid_target!(view, @other_slug), "cell-click", %{
        "ref" => "C3",
        "shift" => false
      })

      assert component_assigns(view)[:active] == {3, 3}

      component_write(view, @other_slug, @escalated)

      # THE ORACLE FIRST — persisted state, by value. Revert the capability at
      # the SheetGrid callsite (`write_capable={true}`) and THIS line reds with
      # `left: %{"v" => 1337}`; the mechanism assertion below reds too, but the
      # store is the one that matters and it must be the one that speaks.
      assert persisted_a1(@other_slug) == @orig

      # …and the MECHANISM that held it: the capability the component itself
      # received.
      assert component_assigns(view)[:write_capable] == false
    end
  end
end
