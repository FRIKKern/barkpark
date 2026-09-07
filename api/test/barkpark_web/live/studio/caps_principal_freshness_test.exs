defmodule BarkparkWeb.Studio.CapsPrincipalFreshnessTest do
  @moduledoc """
  task-02925b8af783e517 — THE STUDIO SOCKET STOPS AUTHORIZING OFF THE
  MOUNT-TIME `%ApiToken{}` STRUCT.

  ## THE HOLE, IN ONE SENTENCE

  `BarkparkWeb.LiveAuth.on_mount(:fetch_api_token)` verifies the bearer ONCE,
  at mount, and assigns the resulting `%ApiToken{}`. There is no
  `handle_event` hook re-verifying it (VERIFIED 2026-09-07 by reading
  `live_auth.ex`: every clause in that module is an `on_mount/4`), so every
  later capability decision — `Caps.derive/1`, `Caps.derive_from_assigns/1`,
  `Tenancy.Auth.permits?/2` behind them — read `permissions` off a struct that
  could be arbitrarily old. A token DOWNGRADED to `["read"]`, REVOKED,
  DISABLED or EXPIRED in the database kept writing through an already-mounted
  socket until it reconnected.

  The DOWNGRADE half of the repro lives, and was flipped, where it was first
  asserted open: section 4 of `pds_w42_caps_live_derive_test.exs`. THIS file
  carries the three arms that file never had — REVOKE, EXPIRY, and the
  disable/`kind` flip — plus the two things the criteria wording alone would
  not have caught.

  ## THE TRAP THIS FILE EXISTS FOR: DENYING BY ESCALATING

  `Caps.write_capable?/2` ends:

      readonly_posture?(assigns) -> false
      caps.write == true         -> true
      restricted?(assigns)       -> false
      has_principal?(assigns)    -> false
      true                       -> true      # <- the anonymous public demo

  A principal-LESS socket is the INTENTIONALLY-OPEN public-demo posture and
  falls through to `true`. So the obvious revoke handling — nil the
  `:api_token` assign, or drop the principal somewhere `has_principal?/1` can
  see it — would not deny a revoked token. It would promote it to the OPEN
  posture: an ESCALATION wearing a denial's clothes, and one that
  "denied the same way" as a criterion does not spell out.

  `describe "the anonymous-escalation trap"` below asserts BOTH ends of that
  fork on the SAME assigns map — the revoked-token socket denies, and the
  identical map with the token removed PASSES — so the test can only be green
  if the fix landed on the deny side of a fork that demonstrably has two sides.
  Without that second assertion the first one is not evidence: a predicate
  that denied everything would satisfy it.

  ## THE MECHANISM UNDER TEST

  `Caps.fresh_api_token/1` reloads the row per derive through
  `Auth.verify_token/1`'s own liveness predicate (`kind == "api"`,
  `revoked_at IS NULL`, `expires_at IS NULL OR expires_at > now`) and drops the
  principal from the LOCAL list when it comes back `nil` — never from
  `assigns`. Cost: +1 `Repo.one` per derive on a token-carrying socket, 0 on
  every other, pinned in `pds_w43_caps_derive_cost_test.exs`
  (`@builtin_token_q` 1 -> 2) and in `caps_authorization_parity_test.exs`.

  `async: false` — the live arm drives a globally-registered sheet session
  through the SQL sandbox, same as the sibling Studio suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @orig %{"v" => "orig"}

  setup %{conn: conn} do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)

    {ws, proj} = ensure_default_scope!()
    seed_sheet_schema!(ws, proj)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # ── harness (spelled as in pds_w42_caps_live_derive_test.exs) ───────────────

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

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # THE ANTI-VACUITY GUARD, inherited deliberately: `with_target/2` on an id
  # that is NOT in the DOM does not fail — the event falls through to the
  # parent, which has no `edit-commit` head, and the run reports a
  # gate-that-wasn't.
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
    Content.Document
    |> where([d], d.doc_id in ^[sheet, "drafts." <> sheet] and d.type == "sheet")
    |> Repo.all()
    |> Enum.map(& &1.content)
    |> Enum.find(%{}, &is_map/1)
  end

  defp writer_token! do
    raw = slug("freshness-tok")
    {:ok, token} = Auth.create_token(raw, "principal freshness", @dataset, ["read", "write"])
    {raw, token}
  end

  defp mount_studio(conn, raw, sheet) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => raw})
      |> live(scoped_studio("/d/#{@dataset}/studio/sheet/#{sheet}"))

    view
  end

  defp update_token!(token, set) do
    {1, _} = ApiToken |> where([t], t.id == ^token.id) |> Repo.update_all(set: set)
    :ok
  end

  # A bare assigns map carrying exactly what `derive_from_assigns/1` and
  # `write_capable?/2` read. Deliberately NOT a mounted LiveView: the arms below
  # are about the DECISION, and a mount would drown it in unrelated queries.
  defp assigns(ws, proj, extra),
    do:
      Map.merge(
        %{
          __changed__: %{},
          current_workspace: ws,
          current_project: proj,
          dataset: @dataset,
          api_token: nil,
          current_user: nil
        },
        extra
      )

  # ── 1. REVOKE, on a LIVE socket, both write routes ──────────────────────────

  describe "a token REVOKED mid-session" do
    test "both write routes deny, nothing lands, and the socket does not crash", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      sheet = slug("fresh-revoke")
      create_sheet!(ws, proj, sheet)
      {raw, token} = writer_token!()

      view = mount_studio(conn, raw, sheet)

      # PRE-CONDITION: this socket really was write-capable. Without it the
      # refusal below could be "sheets never wrote here".
      assert Caps.derive(socket_of(view)).write == true

      # THE PRODUCTION TRIGGER: an admin revokes the token. One column edit; no
      # remount, no event on this socket.
      update_token!(token, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))

      # Route A — straight at the LiveView, where `Caps.gate/3` derives fresh.
      render_hook(view, "edit-commit", %{"value" => "1337", "move" => "none"})
      assert flash_error(view) == "You don't have access to do that."

      # THE CRASH ARM (criterion 2). The socket is STILL ALIVE after the event
      # that met a revoked principal — a `FunctionClauseError` on a nil
      # principal would have taken the process down and `render/1` would raise
      # instead of returning HTML.
      assert Process.alive?(view.pid)
      assert is_binary(render(view))

      # Route B — the SAME event, the SAME socket, at the COMPONENT, where
      # `gate/3` is structurally unreachable.
      component_write(view, sheet, "1337")

      assert Process.alive?(view.pid)
      assert {Caps.derive(socket_of(view)).write, persisted_a1(ws, sheet)} == {false, @orig}
    end

    test "a token row DELETED outright denies the same way", %{conn: conn, ws: ws, proj: proj} do
      # The other shape of "revoke": the row is gone, not flagged. The reload
      # returns nil from a `Repo.one` that matched nothing, which is the same
      # nil the flag produces — one code path, two production triggers.
      sheet = slug("fresh-delete")
      create_sheet!(ws, proj, sheet)
      {raw, token} = writer_token!()

      view = mount_studio(conn, raw, sheet)
      assert Caps.derive(socket_of(view)).write == true

      {1, _} = ApiToken |> where([t], t.id == ^token.id) |> Repo.delete_all()

      component_write(view, sheet, "1337")

      assert Process.alive?(view.pid)
      assert {Caps.derive(socket_of(view)).write, persisted_a1(ws, sheet)} == {false, @orig}
    end
  end

  # ── 2. THE ANONYMOUS-ESCALATION TRAP — the fork, both sides ─────────────────

  describe "the anonymous-escalation trap" do
    test "a revoked token DENIES while a principal-LESS socket PASSES — same map, one field",
         %{ws: ws, proj: proj} do
      {_raw, token} = writer_token!()

      bearing = assigns(ws, proj, %{api_token: token})

      # Baseline: while the token is live, this map is write-capable.
      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == true

      update_token!(token, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))

      # THE DENY SIDE. `caps.write` is false because the reload dropped the
      # principal from the LOCAL list — and the socket is still recognisably
      # principal-BEARING, so `write_capable?/2` lands on the `has_principal?`
      # arm (false), NOT on the fall-through.
      assert Caps.derive_from_assigns(bearing).write == false
      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == false

      # The assign was NEVER touched. This is the load-bearing half: it is what
      # keeps `has_principal?/1` true and therefore what keeps the denial a
      # denial. If a future edit nils the assign to "clean up", this reds here
      # rather than silently in production.
      assert bearing.api_token == token
      refute is_nil(bearing.api_token)

      # THE PASS SIDE, on the SAME map with ONE field removed. This is the
      # positive control that makes the assertion above evidence rather than a
      # tautology: the fork really has two outcomes, the public-demo posture
      # really does pass, and the revoked token landed on the other side.
      anonymous = %{bearing | api_token: nil}
      assert Caps.derive_from_assigns(anonymous).write == false
      assert Caps.write_capable?(anonymous, Caps.derive_from_assigns(anonymous)) == true
    end

    test "a DOWNGRADED token denies without becoming anonymous either", %{ws: ws, proj: proj} do
      # The downgrade path reaches `write_capable?/2` differently from the
      # revoke path — the principal SURVIVES the reload and is denied by
      # `Tenancy.Auth.permits?/2` on the FRESH permissions — so the
      # no-escalation property has to be asserted on it separately. A fix that
      # got revoke right and downgrade wrong would pass the arm above.
      {_raw, token} = writer_token!()
      bearing = assigns(ws, proj, %{api_token: token})

      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == true

      update_token!(token, permissions: ["read"])

      caps = Caps.derive_from_assigns(bearing)
      assert caps.write == false
      # READ survives — the membership is intact and the fresh token still
      # carries "read". A blanket denial would fail here, which is what stops
      # this fix from being "deny tokens".
      assert caps.read == true
      assert Caps.write_capable?(bearing, caps) == false
    end
  end

  # ── 3. EXPIRY — the row said "verify, do not assume" ────────────────────────

  describe "token EXPIRY mid-session" do
    test "an expired token denies within one derive", %{ws: ws, proj: proj} do
      # WHAT THE VERIFICATION FOUND, stated because the row asked for it either
      # way: expiry was NOT covered before this change. `Auth.verify_token/1`
      # filters `expires_at` in its WHERE clause, but `LiveAuth` calls it from
      # an `on_mount` hook ONLY — there is no per-event re-verification
      # anywhere in that module — so a token that expired at 14:00 kept
      # authorizing a socket mounted at 13:59 for as long as it stayed
      # connected. The reload carries the same `expires_at` predicate, so
      # expiry is covered now for the same reason revocation is.
      {_raw, token} = writer_token!()
      bearing = assigns(ws, proj, %{api_token: token})

      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == true

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      update_token!(token, expires_at: past)

      assert Caps.derive_from_assigns(bearing).write == false
      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == false
      refute is_nil(bearing.api_token)
    end

    test "a token flipped to the low-trust `ticket` kind stops authorizing", %{ws: ws, proj: proj} do
      # The `kind == "api"` conjunct is carried across from `verify_token/1`
      # deliberately, so the reload is the SAME liveness predicate as the door
      # rather than a lookalike. Asserted so a future simplification that drops
      # it ("it is always api") reds here.
      {_raw, token} = writer_token!()
      bearing = assigns(ws, proj, %{api_token: token})

      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == true

      update_token!(token, kind: "ticket")

      assert Caps.derive_from_assigns(bearing).write == false
      assert Caps.write_capable?(bearing, Caps.derive_from_assigns(bearing)) == false
    end
  end

  # ── 4. admin?/1, the FORKED TWIN, moves with derive/1 ───────────────────────

  describe "Caps.admin?/1 is fresh too" do
    test "a revoked ADMIN token is no longer a Studio admin", %{ws: ws, proj: proj} do
      raw = slug("fresh-admin-tok")
      {:ok, token} = Auth.create_token(raw, "principal freshness admin", @dataset, ["admin"])

      sock = %Phoenix.LiveView.Socket{assigns: assigns(ws, proj, %{api_token: token})}

      # `create_token/5` mints a perms-derived membership in the token's home
      # workspace, so this really is an admin seat before the revoke.
      assert Caps.admin?(sock) == true
      assert Caps.derive(sock).admin == true

      update_token!(token, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))

      # BOTH halves of the forked pair. `derive/1`'s `:admin` key and
      # `admin?/1` are documented as a pair that must move together, and the
      # parity table asserts they agree cell by cell — a fix that freshened one
      # and not the other would fork them on exactly this axis.
      assert Caps.derive(sock).admin == false
      assert Caps.admin?(sock) == false
    end

    test "the read-only short-circuit still costs ZERO and still denies", %{ws: ws, proj: proj} do
      # `admin?/1` keeps `permits?/2` on the MOUNT-TIME struct as its first
      # conjunct so a read-only token never pays for a reload. That is only
      # sound because the stale conjunct can DENY but never GRANT — this arm
      # pins the denial; the 0.0 q/op figure is pinned in
      # caps_authorization_parity_test.exs.
      {_raw, token} = writer_token!()
      sock = %Phoenix.LiveView.Socket{assigns: assigns(ws, proj, %{api_token: token})}

      refute Caps.admin?(sock)
    end
  end

  # ── 5. NO NEW OVER-DENY at the decision layer ──────────────────────────────

  describe "no new over-deny" do
    test "a LIVE write token is admitted exactly as before", %{ws: ws, proj: proj} do
      {_raw, token} = writer_token!()
      a = assigns(ws, proj, %{api_token: token})

      assert Caps.derive_from_assigns(a) == %{read: true, write: true, admin: false}
      assert Caps.write_capable?(a, Caps.derive_from_assigns(a)) == true
    end

    test "a token with a FUTURE expires_at is admitted — the predicate is not `is_nil`", %{
      ws: ws,
      proj: proj
    } do
      # The inverse of the expiry arm, and not a duplicate of it: a reload
      # spelled `is_nil(t.expires_at)` alone would deny every token that has an
      # expiry at all, which is a silent, total over-deny that the expiry arm
      # above cannot see.
      {_raw, token} = writer_token!()
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      update_token!(token, expires_at: future)

      a = assigns(ws, proj, %{api_token: token})
      assert Caps.derive_from_assigns(a).write == true
      assert Caps.write_capable?(a, Caps.derive_from_assigns(a)) == true
    end

    test "a socket with NO principal is untouched — still the open public-demo posture", %{
      ws: ws,
      proj: proj
    } do
      a = assigns(ws, proj, %{})
      assert Caps.derive_from_assigns(a).write == false
      assert Caps.write_capable?(a, Caps.derive_from_assigns(a)) == true
    end

    test "an UNRESOLVED workspace still costs ZERO queries on a TOKEN socket", %{proj: proj} do
      # FOUND BY RUN, not by reading: the first draft of `fresh_api_token/1` ran
      # unconditionally, and `caps_authorization_parity_test.exs`'s nil-workspace
      # GUARD reddened at 1.0 q/op against a documented "costs NOTHING"
      # guarantee. The reload is now gated on the same `is_binary(ws_id)` shape
      # guard `load_memberships/2` carries. That guard's own test uses a USER
      # principal and could never have seen this; this arm carries the TOKEN
      # shape, which is the only one the reload touches.
      {_raw, token} = writer_token!()

      a = assigns(nil, proj, %{api_token: token, current_workspace: nil})

      {caps, n} = Barkpark.QueryCounter.count(fn -> Caps.derive_from_assigns(a) end)

      assert caps == %{read: false, write: false, admin: false}
      assert n == 0, "an unresolved workspace issued #{n} statement(s) — the gate is gone"
    end
  end
end
