defmodule BarkparkWeb.Studio.PdsW42CapsLiveDeriveTest do
  @moduledoc """
  pds-w42-caps-prop-is-a-mount-snapshot — the `SheetGrid` capability prop stops
  being a mount-time snapshot.

  ## THE HOLE, IN ONE SENTENCE

  `sheet_write_capable?/1` read `Map.get(assigns, :caps)` — the `:caps` ASSIGN.
  `StudioLive.refresh_caps/1` has exactly three callers and ALL THREE are
  GRANT-shaped (the mount seed, `:airdrop_granted`, and the grant
  expiry/revoke tick), so NOTHING re-stamped it on a membership deletion, a
  role downgrade, or a permissions change. The socket-level `Caps` deny-gate
  derives FRESH on every event and halted `save`; the SAME socket's
  cid-targeted `edit-commit` read the stale prop and PERSISTED.

  ## THE SHAPE OF THE LIE IS THE ASSERTION

  Every revocation arm asserts ONE tuple —
  `{fresh_derive_write, stale_caps_assign_write, what_landed_in_A1}` — so a
  regression prints the two disagreeing booleans AND the escalated value, not
  merely a consequence. `{false, true, %{"v" => "orig"}}` is the fixed shape:
  the snapshot is STILL a lie (nothing re-stamps it, and this change does not
  pretend to), and the write is stopped anyway because the authorization no
  longer reads it.

  ## WHY A PER-RENDER DERIVATION ALONE WOULD NOT HAVE BEEN A FIX

  A `phx-target`ed event does NOT re-render the parent. Recomputing the prop at
  the callsite therefore only shortens the window between a revocation and the
  next parent render — it does not close it, and against the exact repro below
  (revoke, then write, with no intervening parent event) it would not fire at
  all. The close is the SECOND derivation: `write_authz` carries the
  authorization INPUTS into the component and `SheetGrid`'s own write seam
  (`commit/3` / `send_ops/2`, which every mutation in that module rides)
  re-asks `Shared.sheet_write_capable?/1` — freshly-read membership and grant
  rows — before `Ops.send_ops/2`'s last wall reads the assign.

  ## SO THE RENDER CALLSITE STAYS A SNAPSHOT, AND SECTION 5 HOLDS IT THERE

  Because the derive buys nothing at the callsite, it does not get to cost a
  `Repo` round trip per parent render — the prohibition `components.ex` has
  always carried at that line. The render prop reads
  `Shared.sheet_write_capable_snapshot?/1` (the `:caps` assign, zero queries)
  and the write seam reads `Shared.sheet_write_capable?/1` (fresh). Section 5
  asserts BOTH halves — the query budget and the wiring — so re-pointing the
  callsite at the deriving twin reds.

  ## THE SECOND STALENESS IS NOT CLOSED, AND IS ASSERTED OPEN

  `Tenancy.Auth.permits?/2` reads the `%ApiToken{}` STRUCT captured at mount by
  the session plug, so a token downgraded to `["read"]` (or revoked) IN THE DB
  still derives `write == true` on an already-mounted socket. The last test in
  this file asserts that gap BY RUN — an escalated 1337 reaching the store —
  so the word "fresh" cannot be read as covering it. See the pds-w42 PR body.

  `async: false` — sheet sessions are globally-registered processes reading
  through the SQL sandbox in shared mode, same as the sibling SheetGrid suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Auth, Content, Repo}
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Tenancy.{Membership, Role, RolePermission}
  alias Barkpark.QueryCounter
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "production"
  @orig %{"v" => "orig"}

  setup %{conn: conn} do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # No debounce-driven persistence race: the session holds the write in
    # memory and `Session.peek/3` is the authoritative read while it lives.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)

    {default_ws, default_proj} = ensure_default_scope!()
    seed_sheet_schema!(default_ws, default_proj)

    {:ok, conn: conn, default_ws: default_ws, default_proj: default_proj}
  end

  # ── harness ─────────────────────────────────────────────────────────────────

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

  # Schemas are TENANT-SCOPED: without a `sheet` schema row in THIS workspace
  # the desk has no sheet type and the editor pane never opens — every "the
  # store did not change" assertion would then pass for the wrong reason.
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
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{
            "locale" => "nb-NO",
            "tabs" => [%{"name" => "Data", "cells" => %{"A1" => @orig}}]
          }
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc
  end

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp user_session(conn) do
    email = "w42-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp member!(ws, %Accounts.User{} = user, role) do
    Repo.insert!(%Membership{
      workspace_id: ws.id,
      principal_type: "user",
      principal_id: user.id,
      role: role
    })
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # THE ANTI-VACUITY GUARD. `with_target/2` on an id that is NOT in the DOM
  # does not fail — the event falls through to the parent, which has no
  # `edit-commit` head, and the run would report a gate-that-wasn't.
  defp grid_target!(view, sheet) do
    assert render(view) =~ ~s(id="sheet-grid-#{sheet}")
    with_target(view, "#sheet-grid-#{sheet}")
  end

  defp component_write(view, sheet, value) do
    target = grid_target!(view, sheet)
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => value, "move" => "none"})
    render(view)
    :ok
  end

  # A1 as PERSISTED STATE reports it. A live session's memory is authoritative
  # when one exists; with no session the stored row is the truth. Reading both
  # ways is what makes the assertion falsifiable in either direction — a write
  # that starts a session is caught, and so is one that never does.
  defp persisted_a1(ws, sheet) do
    cells =
      case Session.peek(sheet, @dataset, ws.id) do
        {:ok, content} ->
          get_in(content, ["tabs", Access.at(0), "cells"]) || %{}

        {:error, :no_session} ->
          get_in(stored_content(sheet), ["tabs", Access.at(0), "cells"]) || %{}
      end

    Map.get(cells, "A1")
  end

  defp stored_content(sheet) do
    Barkpark.Content.Document
    |> where([d], d.doc_id in ^[sheet, "drafts." <> sheet] and d.type == "sheet")
    |> Repo.all()
    |> Enum.map(& &1.content)
    |> Enum.find(%{}, &is_map/1)
  end

  # THE ORACLE THE ROW ASKS FOR: {fresh derive, stale mount-time assign, what
  # landed}. All three read off the SAME live socket at the SAME instant.
  defp lie_shape(view, ws, sheet) do
    assigns = socket_of(view).assigns
    {Caps.derive(socket_of(view)).write, assigns.caps.write, persisted_a1(ws, sheet)}
  end

  # ── 1. the proven repro: a membership deleted mid-session ───────────────────

  describe "a membership revoked mid-session" do
    test "the socket route halts AND the cid-targeted route no longer persists", %{
      conn: conn,
      default_ws: ws,
      default_proj: proj
    } do
      sheet = slug("w42-revoke")
      create_sheet!(ws, proj, sheet)

      raw = slug("w42-tok")
      {:ok, token} = Auth.create_token(raw, "w42 writer", @dataset, ["read", "write"])

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> live(scoped_studio("/d/#{@dataset}/studio/sheet/#{sheet}"))

      # PRE-CONDITION, not decoration: the socket really was write-capable, so
      # the post-revocation refusal cannot be "sheets never wrote here".
      assert socket_of(view).assigns.caps.write == true
      assert Caps.derive(socket_of(view)).write == true

      # THE PRODUCTION TRIGGER: an org-admin removes the member. One row edit,
      # no re-mount, no event on this socket.
      {1, _} =
        Membership
        |> where([m], m.principal_id == ^token.id and m.workspace_id == ^ws.id)
        |> Repo.delete_all()

      # Route A — straight at the LiveView. `Caps.gate/3` derives fresh and
      # halts (`edit-commit` is unclassified ⇒ the default-DENY tier).
      render_hook(view, "edit-commit", %{"value" => "1337", "move" => "none"})
      assert flash_error(view) == "You don't have access to do that."

      # Route B — the SAME event string, the SAME socket, at the component.
      component_write(view, sheet, "1337")

      # ONE TUPLE. The mount-time assign is STILL true — nothing re-stamps it,
      # and this fix does not pretend to; what changed is that the
      # authorization stopped reading it.
      assert lie_shape(view, ws, sheet) == {false, true, @orig}
    end

    test "NO OVER-DENY: the same principal, not revoked, still writes", %{
      conn: conn,
      default_ws: ws,
      default_proj: proj
    } do
      sheet = slug("w42-ok")
      create_sheet!(ws, proj, sheet)

      raw = slug("w42-tok")
      {:ok, _token} = Auth.create_token(raw, "w42 writer", @dataset, ["read", "write"])

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> live(scoped_studio("/d/#{@dataset}/studio/sheet/#{sheet}"))

      component_write(view, sheet, "1337")

      assert persisted_a1(ws, sheet) == %{"v" => 1337}
      assert render(view) =~ ~s(data-v="1337")
    end
  end

  # ── 2. the ROLE-DOWNGRADE variant (a USER member) ───────────────────────────

  describe "a membership ROLE downgraded mid-session" do
    test "a downgrade to a non-write CUSTOM role stops the cid-targeted write", %{
      conn: conn,
      default_ws: ws,
      default_proj: proj
    } do
      sheet = slug("w42-role")
      create_sheet!(ws, proj, sheet)

      {user, conn} = user_session(conn)
      membership = member!(ws, user, "member")

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{sheet}"))

      assert socket_of(view).assigns.caps.write == true

      # A CUSTOM role carrying `read` and NOT `write` — the realistic
      # downgrade. `Tenancy.Auth.role_permits?/3` resolves a non-built-in name
      # purely from `role_permissions`, so this is a genuine data-driven denial
      # and not a missing-row artefact.
      role = Repo.insert!(%Role{workspace_id: ws.id, name: slug("w42-reader"), built_in: false})
      Repo.insert!(%RolePermission{role_id: role.id, action: "read"})

      # `Membership.changeset/2` only accepts the built-in names, so the
      # downgrade goes in as the raw column edit an admin surface performs.
      {1, _} =
        Membership
        |> where([m], m.id == ^membership.id)
        |> Repo.update_all(set: [role: role.name])

      component_write(view, sheet, "1337")

      assert lie_shape(view, ws, sheet) == {false, true, @orig}
    end
  end

  # ── 3. NO OVER-DENY for the two other principal shapes (c4) ─────────────────

  describe "the caps.write-FIRST order is preserved" do
    test "a principal-LESS socket still passes the :write tier BY DESIGN", %{
      default_ws: ws,
      default_proj: proj
    } do
      # The public-demo posture, at the predicate: no api_token, no
      # current_user, no read-only posture, no grant grade. `caps.write` is
      # false (no principal to derive it from) and the fall-through arm — the
      # LAST clause of `Caps.write_capable?/2` — is what admits it. If a
      # re-derivation ever moved that arm, this reds.
      ctx = %{
        current_workspace: ws,
        current_project: proj,
        dataset: @dataset,
        sheet_doc: %{type: "sheet", doc_id: "anything"}
      }

      assert Caps.derive_from_assigns(ctx).write == false
      assert Shared.sheet_write_capable?(ctx) == true
    end

    test "a grantee whose WRITE grant admits this sheet still writes through the component", %{
      conn: conn
    } do
      # An UNSHARED, NON-default workspace: the Default workspace is an open
      # public-demo posture in test, which would make this control vacuous.
      ws = create_workspace!(slug("w42g"))
      proj = create_project!(ws, slug("w42g-proj"))
      seed_sheet_schema!(ws, proj)
      sheet = slug("w42-granted")
      create_sheet!(ws, proj, sheet)

      {user, conn} = user_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

      bind_grant!(ws, user, %{
        capabilities: ["read", "write"],
        project_id: proj.id,
        dataset: @dataset,
        type: "sheet",
        doc_id: sheet
      })

      {:ok, view, _html} =
        live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/sheet/#{sheet}")

      # The grant grade, read off the running socket — this arm is only
      # meaningful while the socket really is grant-derived.
      assert socket_of(view).assigns[:write_gate?] == true
      refute is_nil(socket_of(view).assigns[:caller_context])

      component_write(view, sheet, "1337")

      assert persisted_a1(ws, sheet) == %{"v" => 1337}
    end
  end

  # ── 4. THE SECOND STALENESS — asserted OPEN, by run ─────────────────────────

  describe "token permissions are NOT fresh (the gap this change does not close)" do
    test "downgrading the token to [\"read\"] in the DB leaves the derive write-capable", %{
      conn: conn,
      default_ws: ws,
      default_proj: proj
    } do
      sheet = slug("w42-tokdown")
      create_sheet!(ws, proj, sheet)

      raw = slug("w42-tok")
      {:ok, token} = Auth.create_token(raw, "w42 writer", @dataset, ["read", "write"])

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> live(scoped_studio("/d/#{@dataset}/studio/sheet/#{sheet}"))

      {1, _} =
        Barkpark.Auth.ApiToken
        |> where([t], t.id == ^token.id)
        |> Repo.update_all(set: [permissions: ["read"]])

      # The membership row is re-read and still says member; the PERMISSIONS
      # come off the struct the session plug captured at mount, so the fresh
      # derive is fresh only for MEMBERSHIP. This is a KNOWN-OPEN gap, asserted
      # so it cannot be papered over by the word "fresh": flipping it to a
      # denial is a deliberate follow-up, and this test is where it lands.
      assert Caps.derive(socket_of(view)).write == true

      component_write(view, sheet, "1337")
      assert persisted_a1(ws, sheet) == %{"v" => 1337}
    end
  end

  # ── 5. THE RENDER CALLSITE IS A SNAPSHOT, AND COSTS NO QUERY ────────────────

  describe "the render-time twin issues no query" do
    test "snapshot? is 0 statements and write_capable_now? is not — same assigns", %{
      conn: conn,
      default_ws: ws,
      default_proj: proj
    } do
      {user, _conn} = user_session(conn)
      member!(ws, user, "member")

      ctx = %{
        current_user: user,
        current_workspace: ws,
        current_project: proj,
        dataset: @dataset,
        sheet_doc: %{type: "sheet", doc_id: "anything"},
        caps: %{read: true, write: true, admin: false}
      }

      {snapshot, snapshot_n} =
        QueryCounter.count(fn -> Shared.sheet_write_capable_snapshot?(ctx) end)

      {fresh, fresh_n} = QueryCounter.count(fn -> Shared.sheet_write_capable?(ctx) end)

      # THE POSITIVE CONTROL IS THE SECOND COUNT. A counter that cannot see any
      # statement would report 0 for both and this test would pass over a
      # render callsite that queries on every frame. The authorizing twin MUST
      # be non-zero — it is the whole reason the split exists.
      assert fresh_n > 0,
             "the counter saw nothing at all — it cannot certify the snapshot's zero"

      assert snapshot_n == 0,
             "the render-time predicate issued #{snapshot_n} statement(s); " <>
               "render is a hot path and this is the prohibition pds-w42 restored"

      # Same verdict from both, on assigns where the snapshot is not yet a lie:
      # the split is about PROVENANCE and cost, never about the rule.
      assert snapshot == true
      assert fresh == true
    end

    test "the components.ex prop is wired to the snapshot twin, not the deriving one" do
      src = File.read!("lib/barkpark_web/live/studio/studio_live/components.ex")

      callsite =
        src
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "defp sheet_write_capable?(assigns)"))

      # Positive control: the grep found the definition it is judging. Without
      # this, a renamed function makes both assertions below vacuously true.
      assert length(callsite) == 1,
             "expected exactly one `defp sheet_write_capable?(assigns)`, found #{length(callsite)}"

      line = hd(callsite)
      assert String.contains?(line, "Shared.sheet_write_capable_snapshot?")

      refute String.contains?(line, "Shared.sheet_write_capable?("),
             "the render prop is calling the DERIVING twin — that is a Repo round trip " <>
               "per parent render, and it closes no window a cid-targeted event travels"
    end
  end
end
