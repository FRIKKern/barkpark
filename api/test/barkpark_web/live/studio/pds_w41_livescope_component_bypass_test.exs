defmodule BarkparkWeb.Studio.PdsW41LiveScopeComponentBypassTest do
  @moduledoc """
  pds-bl-w41-livescope-component-bypass-unrun — the RUN the wave-41 claim never
  had.

  Wave 41 proved BY RUN that a `phx-target`ed event bypasses `Caps`' socket-level
  `:studio_caps_gate` (PDS-D596), and closed it by sending the capability INTO
  the component as `write_capable`. The generalisation to `LiveScope`'s two
  hooks — `:live_scope_readonly` and `:live_scope_write_scope` — was asserted
  from `phoenix_live_view/channel.ex` source only. This file runs it.

  ## ✅ THE GUARD IS NOW CLOSED — THIS SUITE IS ALL REGRESSION PROOF

  This banner previously read "⚠ THIS SUITE CONTAINS A REPRODUCTION": the test
  below named "…and the COMPONENT route WRITES" asserted that the escalated
  bytes REACHED THE STORE, and it was GREEN because the bypass was REAL and
  OPEN. `task-6c2352ce57f8ef20` closed it, and that test is now INVERTED — it
  asserts the store stays `@orig` and the component receives
  `write_capable: false`. Every test in this file is an ordinary standing
  regression proof and must stay green.

  THE FIX, in one line: `sheet_write_capable?/1` at the `SheetGrid` callsite
  (`grep -n 'sheet_grant_target_denied?' lib/barkpark_web/live/studio/studio_live/components.ex`)
  now requires, for a GRANT-graded socket only, that some active grant
  `Access.validate/3`-admits `:write` at the MOUNTED SHEET's real
  `type` + canonical `doc_id` — not merely at desk granularity. Same door
  `Shared.Paper.grant_target_denied?/3` built for the paper surface in wave 44,
  travelled into the component as the prop rather than as a fourth
  `attach_hook` (a `phx-target`ed event never consults the parent's hook list —
  that is the whole bug).

  ## What the run finds — three different answers, one per grade

    * `:share_read` (`:live_scope_readonly`) — GATED. Not by the hook (the hook
      really is unreachable from a component event) but by the D596 prop:
      `Caps.write_capable?/2`'s `readonly_posture?/1` arm reads
      `share_access: :read`, so the component receives `write_capable: false`
      and `SheetGrid.Ops.send_ops/2`'s last wall drops the op.

    * `{:grant, ctx}` with a READ-only grant (`:live_scope_readonly`) — GATED,
      same mechanism via `readonly_gate?: true`.

    * `{:grant, ctx}` with a WRITE grant NARROWER than the desk
      (`:live_scope_write_scope`) — **WAS BYPASSED; now GATED by the prop's own
      target narrowing.** This hook is not a presence
      check, it is a per-event TARGET check: it resolves
      `%{workspace_id, project_id, dataset, type, doc_id}` from the loaded
      editor doc and requires `Access.validate(grant, :write, target) == :ok`.
      The D596 prop cannot reproduce that answer, because
      `Caps.write_capable?/2` takes NO target: it short-circuits on
      `caps.write == true`, and `Caps.derive/1` computes `write` through
      `Access.admits_desk?/3`, which OVERWRITES the request's `type`/`doc_id`
      with the GRANT'S OWN before validating. A doc-scoped write grant therefore
      self-satisfies at desk granularity and the prop USED TO arrive `true` on
      EVERY sheet of the desk. It no longer does: `sheet_write_capable?/1`
      now ANDs a per-target `Access.validate/3` on top of that desk answer.

  So the bypass was REAL, and it was a GRANULARITY gap, not a missing gate:
  socket route = doc-granular, component route = desk-granular. The fix makes
  the component route doc-granular too, so the two agree.

  This is the SHEET twin of `pds_w44_grant_door_test.exs`, which found and
  closed the same gap on the PAPER route via
  `Shared.Paper.grant_target_denied?/3`. That predicate is a `defp` on the
  paper module, so the sheet callsite states the same ladder over the same
  public core primitive (`Barkpark.Access.validate/3`) rather than reaching
  into it; `SheetGrid.Ops.send_ops/2`'s `write_capable: false` wall is what
  now stops this principal at the Sheets session.

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
  PRESENCE by VALUE — the ORIGINAL bytes ARE still there on every gated path,
  and the ESCALATED bytes ARE there on the granted sheet, printed by value on
  failure. Each gated assertion is PAIRED with that positive control through
  the SAME component route, so "the fence works" cannot be confused with
  "sheet writing is broken for everyone".

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

    # THE ROW KEEPS ITS REAL `dataset_id` — the ordinary Studio write path
    # stamps one, and this suite used to have to NULL it.
    #
    # WHY IT DID (task-f0c064a406e8d363, fixed): `Sheets.Session.load_doc/2`
    # called `Content.get_document/3` with NO scope opts.
    # `WriteScope.resolve_read_dataset_id/2` then took its "no scope at all"
    # arm and returned the SEEDED DEFAULT project's `dataset_id`, which
    # `Query.scope_to_dataset/3` applies as `dataset_id == default_ds_id or
    # (is_nil(dataset_id) and dataset == "production")`. A sheet stamped with
    # THIS non-Default workspace's own `production` dataset row matched NEITHER
    # arm: the session got `{:error, :not_found}`, never started, and
    # `SheetGrid.Ops.send_ops/2` reported `notice: "edit failed: :not_found"`.
    # Every "the store did not change" assertion in this file then passed
    # VACUOUSLY — not because a gate held, but because the session could not
    # open the sheet at all.
    #
    # The session is now keyed `{dataset, workspace_id, published-id}` and
    # loads SCOPED to that workspace, so the real `dataset_id` is admitted.
    # RESTORE the `null_dataset_id!/1` workaround (or revert the scoping) and
    # the pds-w44 harness test below reds on `{:error, :no_session}` — that
    # test is this line's guard.
    assert is_binary(doc.dataset_id)
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
  defp persisted_a1(ws, slug) do
    cells =
      case Session.peek(slug, @dataset, ws.id) do
        {:ok, content} ->
          get_in(content, ["tabs", Access.at(0), "cells"]) || %{}

        {:error, :no_session} ->
          get_in(stored_content(slug), ["tabs", Access.at(0), "cells"]) || %{}
      end

    Map.get(cells, "A1")
  end

  # The DB row's cells, AFTER forcing the live session to persist. The
  # STORED-bytes oracle the pds-w44 criteria ask for: it reads what actually
  # reached storage, so an escalated in-memory cell cannot hide behind a
  # 60s debounce.
  defp flushed_cells(slug) do
    :ok = Session.flush(slug, @dataset)
    get_in(stored_content(slug), ["tabs", Access.at(0), "cells"]) || %{}
  end

  # Which workspaces hold a row for this sheet. One, and it must be the test's
  # own — the session's debounced persist runs through
  # `Content.upsert_document/4`, whose prev-doc lookup is SCOPE-SCOPED: an
  # unscoped persist resolves the seeded Default workspace, finds no prev doc
  # there, and INSERTS a SECOND copy of the sheet into Default.
  defp row_workspaces(slug) do
    import Ecto.Query

    Barkpark.Content.Document
    |> where([d], d.doc_id in ^[slug, "drafts." <> slug] and d.type == "sheet")
    |> select([d], d.workspace_id)
    |> Barkpark.Repo.all()
    |> MapSet.new()
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

      # THE GRANULARITY GAP THE FIX CLOSES, stated as three values from the
      # running socket. `Caps.write_capable?/2` is DELIBERATELY still `true`:
      # it is the DESK answer, it takes no target, and it is the socket gate's
      # predicate too — widening it was explicitly out of scope. The narrowing
      # lives at the callsite, so the value that changed is the PROP.
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

      # …and THAT is the answer the component now receives: the desk-granular
      # capability said `true`, the target-granular one says `false`. These two
      # lines side by side ARE the fix.
      assert component_assigns(view)[:write_capable] == false
    end
  end

  # ── 2. THE BYPASS: same socket, same sheet, two routes ──────────────────────

  describe "component-targeted write vs :live_scope_write_scope" do
    # WAS `@tag :reproduction`, and WAS asserting `%{"v" => 1337}` — the leak.
    # INVERTED by task-6c2352ce57f8ef20: the same run, the same socket, the same
    # two routes, and now they AGREE. A red here means the fence came back off.
    test "BOTH routes now REFUSE the non-granted sheet — socket by the hook, component by the prop",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = write_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @other_slug)

      assert persisted_a1(ws, @other_slug) == @orig

      # ROUTE A — straight at the LiveView. `save` classifies `:write` and
      # `Caps` PASSES it (caps.write is true), so the halt below is
      # `:live_scope_write_scope`'s and nothing else's: it resolved the target
      # to the NON-granted sheet and no grant validated.
      render_hook(view, "save", %{"document" => %{}})
      assert flash_error(view) == @outside_grant_flash
      assert persisted_a1(ws, @other_slug) == @orig

      # NON-VACUITY, BEFORE the write: the component IS reachable on this socket
      # and the cid-routed event really is dispatched into its own
      # `handle_event/3` — C3 is not the mount default, so a changed `active` on
      # the COMPONENT socket is presence-evidence. Without this, an unchanged
      # store below could just mean the event never arrived.
      render_hook(grid_target!(view, @other_slug), "cell-click", %{
        "ref" => "C3",
        "shift" => false
      })

      assert component_assigns(view)[:active] == {3, 3}

      # ROUTE B — the SAME socket, the SAME sheet, targeted at the component.
      # The parent's hook list is still never consulted on this path (that is
      # structural and unchanged); the wall is the `write_capable` prop, which
      # is now TARGET-granular and says `false`.
      component_write(view, @other_slug, @escalated)

      # THE ORACLE FIRST — persisted state, by value. Bound to a variable so a
      # regression prints `left: %{"v" => 1337}` rather than a custom message,
      # and asserted BEFORE any mechanism assertion so a mutation run reports
      # the BYTES rather than the flag that shadowed them.
      after_component_event = persisted_a1(ws, @other_slug)

      assert after_component_event == @orig

      # …and the MECHANISM that held it, read off the COMPONENT's own socket:
      # the capability arrived `false`, which is the value that used to be
      # `true` while the socket hook's predicate on the same target was
      # `{:error, :forbidden}`. The two routes now agree.
      assert component_assigns(view)[:write_capable] == false

      # And the SOCKET route still refuses the same target on the same socket.
      assert flash_error(view) == @outside_grant_flash

      # THE PAIRED POSITIVE CONTROL, SAME PRINCIPAL, SAME RUN, SAME ROUTE: the
      # sheet the grant DOES name is still written through the component. This
      # is what separates "the fence is target-selective" from "I closed the
      # sheet surface for everyone" — without it the assertion above is
      # satisfied by a blanket denial.
      {granted_view, _html} = open_sheet!(conn, ws, proj, @granted_slug)
      component_write(granted_view, @granted_slug, @escalated)

      assert persisted_a1(ws, @granted_slug) == %{"v" => 1337}
      assert component_assigns(granted_view)[:write_capable] == true
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

      assert persisted_a1(ws, @granted_slug) == %{"v" => 1337}

      # The capability really did travel in as a prop, and the write path
      # reported no error (a `notice` here is how the first run of this suite
      # surfaced the session's `:not_found`, see `null_dataset_id!/1`).
      assert component_assigns(view)[:write_capable] == true
      assert component_assigns(view)[:notice] == nil
    end
  end

  # ── 2b. pds-w44 — THE WRITE-LANDING HARNESS, in a SCOPED PRIVATE workspace ──
  #
  # pds-w44-bl-sheetgrid-write-landing-unproven. Wave 44 proved the capability
  # PROP flips, but never landed a sheet write in a scoped private workspace:
  # `Session.peek/2` answered `{:error, :no_session}` in BOTH arms and the
  # stored cell stayed unchanged either way, so a "store unchanged" assertion
  # there would have been VACUOUS IN BOTH ARMS.
  #
  # The reason was task-f0c064a406e8d363: the session's load was dataset_id-
  # blind, so it could not open a sheet outside the Default workspace at all.
  # These tests are the harness that row asked for, in the order it asked for
  # it — OPEN, then LAND, and only then assert a refusal.

  describe "the Sheets session in a NON-Default, unshared, private workspace" do
    test "OPENS the sheet — peek returns the stored cell, not {:error, :no_session}", %{
      ws: ws
    } do
      # Nothing is live yet: `peek/3` never starts a session.
      assert Session.peek(@granted_slug, @dataset, ws.id) == {:error, :no_session}

      # The session starts LAZILY on the first op. Before the fix THIS call
      # returned `{:error, :not_found}` — `init/1` could not read the row,
      # because the unscoped `Content.get_document/3` resolved the seeded
      # DEFAULT project's `dataset_id` and this workspace's sheet carries its
      # OWN. Delete the `workspace_id` argument here (or revert `load_doc/3`)
      # and the assertion below reds with `{:error, :not_found}`.
      assert {:ok, %{applied: 1, errors: []}} =
               Session.apply_ops(
                 @granted_slug,
                 @dataset,
                 [%{"op" => "set_cell", "tab" => 0, "ref" => "B2", "raw" => "harness"}],
                 nil,
                 ws.id
               )

      # CRITERION 1 — a REAL session is live for a doc in a scoped private
      # workspace, and `peek/3` returns the STORED cell (the row's own `A1`,
      # loaded from storage) rather than `{:error, :no_session}`.
      assert {:ok, content} = Session.peek(@granted_slug, @dataset, ws.id)
      cells = get_in(content, ["tabs", Access.at(0), "cells"]) || %{}
      assert Map.get(cells, "A1") == @orig
      assert Map.get(cells, "B2") == %{"v" => "harness"}
    end

    test "LANDS a write — the harness write reaches STORAGE, in THIS workspace only", %{
      ws: ws
    } do
      {:ok, _} =
        Session.apply_ops(
          @granted_slug,
          @dataset,
          [%{"op" => "set_cell", "tab" => 0, "ref" => "B2", "raw" => "harness"}],
          nil,
          ws.id
        )

      # CRITERION 2 — the positive control, on the STORED bytes. The debounce
      # is 60s in this suite, so nothing reaches the row until the flush; that
      # is exactly what makes this a landing proof and not a memory read.
      assert Map.get(flushed_cells(@granted_slug), "B2") == %{"v" => "harness"}

      # …and it landed in THIS tenant, not a second copy in Default. The
      # session's persist runs `Content.upsert_document/4`, whose prev-doc
      # lookup is scope-scoped: unscoped, it resolves the seeded Default
      # workspace, finds no prev doc, and INSERTS. Drop the `write_scope/1`
      # opts from `Session.persist_result/1` and this set gains the Default
      # workspace's id.
      assert row_workspaces(@granted_slug) == MapSet.new([ws.id])
    end

    test "is TENANT-KEYED — another workspace's identically-slugged sheet is a DIFFERENT session",
         %{ws: ws} do
      # A second tenant holding the SAME slug in the SAME dataset. Before this
      # fix the registry key was `{dataset, published-id}`, so these two shared
      # ONE session process — the residual the `/ops` tenant gate declared.
      other_ws = create_workspace!("w41cb-other-#{System.unique_integer([:positive])}")
      other_proj = create_project!(other_ws, "w41cb-proj")
      seed_sheet_schema!(other_ws, other_proj)
      create_sheet!(other_ws, other_proj, @granted_slug)

      {:ok, _} =
        Session.apply_ops(
          @granted_slug,
          @dataset,
          [%{"op" => "set_cell", "tab" => 0, "ref" => "B2", "raw" => "tenant-a"}],
          nil,
          ws.id
        )

      # Tenant A's session is live; tenant B's is NOT — different key.
      assert {:ok, _} = Session.peek(@granted_slug, @dataset, ws.id)
      assert Session.peek(@granted_slug, @dataset, other_ws.id) == {:error, :no_session}

      # And when B starts its own, it reads B's row: A's `B2` is not there.
      assert {:ok, _} =
               Session.apply_ops(
                 @granted_slug,
                 @dataset,
                 [%{"op" => "set_cell", "tab" => 0, "ref" => "C3", "raw" => "tenant-b"}],
                 nil,
                 other_ws.id
               )

      assert {:ok, b_content} = Session.peek(@granted_slug, @dataset, other_ws.id)
      b_cells = get_in(b_content, ["tabs", Access.at(0), "cells"]) || %{}
      assert Map.get(b_cells, "C3") == %{"v" => "tenant-b"}
      refute Map.has_key?(b_cells, "B2")

      # …and A never saw B's cell either.
      assert {:ok, a_content} = Session.peek(@granted_slug, @dataset, ws.id)
      a_cells = get_in(a_content, ["tabs", Access.at(0), "cells"]) || %{}
      assert Map.get(a_cells, "B2") == %{"v" => "tenant-a"}
      refute Map.has_key?(a_cells, "C3")
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
      assert persisted_a1(ws, @other_slug) == @orig

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
      assert persisted_a1(ws, @other_slug) == @orig
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

      # pds-w44 CRITERION 2, INSIDE this arm: the harness LANDS a write on the
      # very sheet the refusal below covers, in this scoped private workspace.
      # Without it "the store did not change" is satisfied by a session that
      # could never open the sheet — which is exactly how wave 44 found it.
      assert {:ok, %{applied: 1, errors: []}} =
               Session.apply_ops(
                 @other_slug,
                 @dataset,
                 [%{"op" => "set_cell", "tab" => 0, "ref" => "B2", "raw" => "harness"}],
                 nil,
                 ws.id
               )

      component_write(view, @other_slug, @escalated)

      # pds-w44 CRITERION 3 — THE ORACLE IS THE STORED BYTES. `flushed_cells/1`
      # forces the live session to persist and reads the ROW back, so this is
      # what actually reached storage, not a memory peek.
      #
      # The SAME flush carries both cells, which is what makes the refusal
      # non-vacuous: `B2` proves writes DO land on this sheet in this
      # workspace through this session, while `A1` proves the share-read
      # viewer's escalation did NOT.
      stored = flushed_cells(@other_slug)

      assert Map.get(stored, "A1") == @orig
      assert Map.get(stored, "B2") == %{"v" => "harness"}

      assert persisted_a1(ws, @other_slug) == @orig

      # …and the MECHANISM that held it: the capability the component itself
      # received.
      assert component_assigns(view)[:write_capable] == false
    end

    # pds-w44 CRITERION 4 — NON-VACUOUS BY MUTATION, and it needs THIS
    # principal, not the anonymous viewer above.
    #
    # `Caps.write_capable?/2` is a `cond`, and its arms are ORDERED:
    #
    #     readonly_posture?(assigns) -> false     # PDS-D635, the arm under test
    #     Map.get(caps, :write) == true -> true   # short-circuits BEFORE restricted?/1
    #     restricted?(assigns) -> false
    #
    # For the ANONYMOUS share viewer `caps.write` is FALSE, so deleting the
    # first arm changes nothing: `restricted?/1` catches it on `readonly_gate?`
    # and the answer stays `false`. Measured, not assumed — that mutation ran
    # 9 tests, 0 failures.
    #
    # The arm is load-bearing for exactly the population PDS-D635 names: a
    # SIGNED-IN grantee holding an ACTIVE WRITE GRANT who mounts a `:docs`-shared
    # desk. `LiveScope.authorize_read/4` offers the public-share arm BEFORE the
    # grant arm, so they land on grade `:share_read` (`share_access: :read`,
    # `readonly_gate?: true`, NO `caller_context`, NO `write_gate?`) — while
    # `Caps.derive/1` still reads their grants off `current_user` and reports
    # `write: true`. Delete the arm and the SECOND arm fires: the write lands.
    test "a signed-in WRITE GRANTEE on the shared desk is gated by the read-only POSTURE alone",
         %{
           conn: conn,
           ws: ws,
           proj: proj
         } do
      {_user, conn} = write_grantee_session(conn, ws, proj)
      {view, _html} = open_sheet!(conn, ws, proj, @granted_slug)
      assigns = socket_of(view).assigns
      caps = Caps.derive(socket_of(view))

      # THE PRECONDITION THAT MAKES THE MUTATION BITE, stated as values from the
      # running socket: a read-only POSTURE sitting on top of a TRUE write
      # capability. Without `caps.write == true` this test degrades into the
      # anonymous one above and the mutation is absorbed by `restricted?/1`.
      assert assigns[:share_access] == :read
      assert assigns[:readonly_gate?] == true
      assert assigns[:write_gate?] == nil
      assert is_nil(assigns[:caller_context])
      assert %Barkpark.Accounts.User{} = assigns[:current_user]
      assert caps.write == true

      # NON-VACUITY: the component is reachable and the cid-routed event really
      # is dispatched into its own `handle_event/3` (C3 is not the mount
      # default), so an unchanged store below is a REFUSAL, not a lost event.
      render_hook(grid_target!(view, @granted_slug), "cell-click", %{
        "ref" => "C3",
        "shift" => false
      })

      assert component_assigns(view)[:active] == {3, 3}

      # THE HARNESS LANDS A WRITE on this very sheet, in this scoped private
      # workspace — so the refusal below is selective, not "sheets are broken".
      assert {:ok, %{applied: 1, errors: []}} =
               Session.apply_ops(
                 @granted_slug,
                 @dataset,
                 [%{"op" => "set_cell", "tab" => 0, "ref" => "B2", "raw" => "harness"}],
                 nil,
                 ws.id
               )

      component_write(view, @granted_slug, @escalated)

      # THE ORACLE FIRST, and it is the STORED bytes — read back off the ROW
      # after forcing the live session to persist. The mechanism assertions are
      # deliberately BELOW it: on a mutation run they red too, and the store is
      # the one that must speak.
      #
      # RUN-PROVEN MUTATION (pds-w44 criterion 4): delete the
      # `readonly_posture?(assigns) -> false` arm from
      # `BarkparkWeb.Studio.Caps.write_capable?/2` and the A1 line below reds
      # with `left: %{"v" => 1337}` — the ESCALATED STORED value, named.
      stored = flushed_cells(@granted_slug)

      assert Map.get(stored, "A1") == @orig
      assert Map.get(stored, "B2") == %{"v" => "harness"}

      # …and the MECHANISM that held them: the posture arm answering `false`
      # over a TRUE write capability, and the `false` the component received.
      assert Caps.write_capable?(assigns, caps) == false
      assert component_assigns(view)[:write_capable] == false
    end
  end
end
