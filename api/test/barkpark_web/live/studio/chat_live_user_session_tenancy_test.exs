defmodule BarkparkWeb.Studio.ChatLiveUserSessionTenancyTest do
  @moduledoc """
  task-787766c0cf6604f1 — the USER-SESSION half of the ChatLive lifecycle
  tenancy guard, which PR #14593 did not close.

  ## The mechanism

  `ChatLive`'s four id-addressed lifecycle clauses (`session-rename`,
  `session-archive`, `session-unarchive`, `session-delete`) are guarded by
  `tenancy_permits?/2` → `principal_permits_owner?/2` →
  `principal_workspace_id/1`. That last function reads ONE assign:

      socket.assigns[:api_token].workspace_id

  and `principal_permits_owner?/2` returns `true` UNCONDITIONALLY when it is
  `nil`. #14593 wrote that branch for the genuinely unbound superuser TOKEN.
  But a USER-SESSION principal carries no `:api_token` assign at all —
  `LiveAuth.authorize_user/3` and `LiveAuth.scoped_admin_authorize_user/3`
  assign `:current_user` and nothing else — so every session-backed admin
  landed in the same `nil` branch.

  ## Why the SCOPED mount makes it unarguable

  `LiveAuth.on_mount(:scoped_admin)`'s user arm is
  `Tenancy.Auth.workspace_admin?(user, ws.id)` against the URL workspace and
  NOTHING ELSE — its own comment says "a legit target-workspace admin needs NO
  Default role at all". So a person who is an admin of workspace B **only** can
  mount `/w/<B>/p/<proj>/studio/chat`, and on origin/main the id-addressed
  clauses then let that person DELETE a chat session owned by workspace A.

  The asymmetry is the tell: the LOAD seam (`load_permits?/2`) already reads
  `read_workspace_id/1`, the URL workspace, on the scoped mount — so the
  sidebar and deep-link reads ARE confined there. Only the write guard skipped
  that binding. Same socket, same mount, two different answers.

  ## The arms

    * `scoped_delete` / `scoped_rename` — the REACH. A ws-B-only user admin
      drives the clause at a ws-A-owned row.
    * `scoped_delete_own` — the POSITIVE CONTROL. The SAME principal deletes a
      ws-B row and it goes. Without it a guard that simply broke delete would
      satisfy the refusal arms.
    * the precondition assertions — the socket really took the USER arm
      (`:api_token` absent, `:current_user` present) and the foreign row really
      is workspace A's. A refusal proved against a socket that turned out to
      hold a bound token would be measuring #14593's fix, not this one.
  ## The FLAT mount is a second population, and it is NOT the superuser

  `LiveAuth.authorize_user/3` admits the flat user arm on an owner/admin-grade
  role in the DEFAULT workspace and says so in its own comment. That is the
  same grant a Default-BOUND token holds, so it takes the same confinement —
  the Default workspace plus NULL-owned legacy rows (`K3` below). The genuinely
  unbound superuser charter D17/D18 reserves is a TOKEN whose `workspace_id` is
  NULL, which `Auth.create_token/5` will not produce; `K2` proves it keeps its
  instance-wide reach.

  The fake runtime is enabled in every test: `ChatLive.mount/3` refuses when no
  provider is enabled and redirects to the same `/studio` an authz denial does,
  so a runtime-less mount would make every refusal assertion vacuously green.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    {default_ws, _default_proj} = ensure_default!()

    ws_a = workspace!("usertenancy-a")
    ws_b = workspace!("usertenancy-b")

    # ── The SCOPED principal: an admin of workspace B and of NOTHING else.
    # No Default role, no membership in A. `scoped_admin_authorize_user/3`
    # admits it for B's URL; nothing else on the instance is its business.
    user_b = register_user("usertenancy-b-#{System.unique_integer([:positive])}@example.test")
    {:ok, user_b_raw} = Accounts.create_user_session_token(user_b)
    {:ok, _} = TenancyAuth.create_membership(ws_b.id, user_b.id, "admin", "user")

    # ── The FLAT principal: an admin of Default and of nothing else.
    # `authorize_user/3` checks exactly that role, so this is the flat mount's
    # user arm in its canonical form.
    user_flat =
      register_user("usertenancy-flat-#{System.unique_integer([:positive])}@example.test")

    {:ok, user_flat_raw} = Accounts.create_user_session_token(user_flat)
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, user_flat.id, "admin", "user")

    enable_fake_chat()

    foreign = session_owned_by!(ws_a, "ws-A private chat")
    own = session_owned_by!(ws_b, "ws-B own chat")

    # Fixture guards. A refusal asserted against a row that was never A's, or a
    # control asserted against a row that was never B's, proves nothing.
    assert Repo.get(StudioChatSession, foreign.id).owner_workspace_id == ws_a.id,
           "fixture did not produce a workspace-A-owned session — the refusal arms are vacuous"

    assert Repo.get(StudioChatSession, own.id).owner_workspace_id == ws_b.id,
           "fixture did not produce a workspace-B-owned session — the control arm is vacuous"

    refute foreign.id == own.id

    %{
      conn: conn,
      default_ws: default_ws,
      ws_a: ws_a,
      ws_b: ws_b,
      scoped_path: "/w/#{ws_b.slug}/p/default/studio/chat",
      user_b_raw: user_b_raw,
      user_flat_raw: user_flat_raw,
      foreign: foreign,
      own: own
    }
  end

  describe "scoped /w/:ws/p/:proj/studio/chat — a ws-B-ONLY user admin" do
    test "took the USER arm: :current_user present, :api_token absent", ctx do
      view = mount!(ctx.conn, ctx.user_b_raw, ctx.scoped_path)
      assigns = live_assigns(view)

      # THE PRECONDITION for every other arm in this module. If this socket
      # carried a token, the clauses below would be re-proving #14593.
      assert is_nil(assigns[:api_token]),
             "the scoped mount handed this socket an :api_token — then it is not the " <>
               "user-session principal this row is about (got #{inspect(assigns[:api_token])})"

      assert match?(%Accounts.User{}, assigns[:current_user]),
             "the scoped mount did not assign :current_user — the user arm was not taken " <>
               "(got #{inspect(assigns[:current_user])})"

      # And the mount really is the SCOPED one, whose read seam is already
      # confined by `read_workspace_id/1`. That asymmetry is the defect.
      assert assigns[:scoped_mount?],
             "the scoped route did not set :scoped_mount? — this is not the mount whose " <>
               "LOAD seam is confined, so there is no asymmetry to report"
    end

    test "session-delete on a workspace-A row is REFUSED", ctx do
      view = mount!(ctx.conn, ctx.user_b_raw, ctx.scoped_path)

      before_row = Repo.get(StudioChatSession, ctx.foreign.id)

      assert match?(%StudioChatSession{}, before_row),
             "the foreign row vanished before the event — the read-back is unsound " <>
               "(got #{inspect(before_row)})"

      render_click(view, "session-delete", %{"id" => ctx.foreign.id})

      surviving = Repo.get(StudioChatSession, ctx.foreign.id)

      assert match?(%StudioChatSession{}, surviving),
             "a user-session admin of workspace B ONLY DELETED a workspace-A chat session " <>
               "from the SCOPED mount for B — cross-tenant destructive reach"

      assert surviving.owner_workspace_id == ctx.ws_a.id,
             "the surviving row changed owner — that is not the row the probe protected"
    end

    test "session-rename on a workspace-A row is REFUSED", ctx do
      view = mount!(ctx.conn, ctx.user_b_raw, ctx.scoped_path)

      before_title = Repo.get(StudioChatSession, ctx.foreign.id).title

      assert before_title == "ws-A private chat",
             "the foreign row does not carry its seeded title — the read-back is unsound"

      marker = "USER-SESSION-REACH-#{System.unique_integer([:positive])}"

      render_click(view, "session-rename", %{"id" => ctx.foreign.id, "value" => marker})

      assert Repo.get(StudioChatSession, ctx.foreign.id).title == before_title,
             "a user-session admin of workspace B ONLY renamed a workspace-A chat session " <>
               "from the SCOPED mount for B"
    end

    test "POSITIVE CONTROL: the same principal deletes its OWN ws-B row", ctx do
      view = mount!(ctx.conn, ctx.user_b_raw, ctx.scoped_path)

      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.own.id)

      render_click(view, "session-delete", %{"id" => ctx.own.id})

      refute Repo.get(StudioChatSession, ctx.own.id),
             "the ws-B admin could not delete its OWN session — the guard is over-tight, " <>
               "and the refusal arms above would pass for a broken feature"
    end
  end

  # ── THE PRINCIPAL-KIND ENUMERATION ────────────────────────────────────────
  #
  # DERIVED FROM `BarkparkWeb.LiveAuth`'s on_mount arms, not from the filing.
  # ChatLive is reachable through exactly two hooks (router.ex: `:admin_studio`
  # → `{LiveAuth, :admin}`, `:scoped_admin_studio` → `{LiveAuth, :scoped_admin}`),
  # and each hook has a token arm and a user arm plus the dev fallback:
  #
  #   K1 flat  + `authorize/4` token arm, workspace_id SET       → its workspace
  #   K2 flat  + `authorize/4` token arm, workspace_id NULL      → nil, unbound
  #   K3 flat  + `authorize_user/3` user arm (Default admin)     → Default ws
  #   K4 scoped + `scoped_admin_authorize/3` token arm           → the URL ws
  #   K5 scoped + `scoped_admin_authorize_user/3` user arm       → the URL ws
  #   K6 either + `dev_browser_token_fallback/0` (dev_root)      → K1/K2, and
  #      INERT outside :dev — `:dev_browser_token` is set only in config/dev.exs.
  #
  # K5 is the class this row is about and is proved in the describe above. The
  # rest are here so the enumeration is a run, not a list.
  describe "principal kinds — what the lifecycle guard resolves to for each" do
    test "K6: the dev_root fallback is INERT in this env, so K1/K2 cover the tokens", _ctx do
      # Stated as a run because the enumeration would otherwise carry an
      # untested sixth row. `authorize/4` and `scoped_admin_candidates/1` both
      # call `dev_browser_token_fallback/0` unconditionally; the config key is
      # what makes it nil here.
      assert is_nil(Application.get_env(:barkpark, :dev_browser_token)),
             "the dev-browser token is configured in this env — K6 is then a LIVE " <>
               "principal kind and needs its own arm, not this exemption"
    end

    test "K2: an UNBOUND admin TOKEN keeps its cross-owner delete (the superuser path)", ctx do
      raw = "usertenancy-unbound-#{System.unique_integer([:positive])}"

      {:ok, token} =
        Auth.create_token(
          raw,
          "usertenancy unbound",
          "production",
          ["read", "write", "admin"]
        )

      # `create_token/5` defaults an omitted workspace to Default, so the NULL
      # binding has to be written directly — which is exactly why this principal
      # is the dev-root/explicitly-unbound credential and not a customer admin.
      {:ok, _} = token |> Ecto.Changeset.change(%{workspace_id: nil}) |> Repo.update()

      assert is_nil(Repo.get(Barkpark.Auth.ApiToken, token.id).workspace_id),
             "the unbound fixture still carries a binding — this arm would not " <>
               "exercise the nil-principal path at all"

      view = mount_token!(ctx.conn, raw, "/studio/chat")

      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.foreign.id)

      render_click(view, "session-delete", %{"id" => ctx.foreign.id})

      refute Repo.get(StudioChatSession, ctx.foreign.id),
             "the UNBOUND superuser token lost its instance-wide delete — the " <>
               "deliberate nil branch was closed along with the session-admin one"
    end

    test "K1: a ws-B-BOUND admin TOKEN on the flat mount is confined to ws B", ctx do
      raw = "usertenancy-bound-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(
          raw,
          "usertenancy bound b",
          "production",
          ["read", "write", "admin"],
          ctx.ws_b.id
        )

      view = mount_token!(ctx.conn, raw, "/studio/chat")

      render_click(view, "session-delete", %{"id" => ctx.foreign.id})

      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.foreign.id)

      # POSITIVE CONTROL on the same socket.
      render_click(view, "session-delete", %{"id" => ctx.own.id})

      refute Repo.get(StudioChatSession, ctx.own.id),
             "the ws-B-bound token could not delete its OWN row — the refusal above " <>
               "would then be a dead feature"
    end

    test "K3: a user-session admin on the FLAT mount is confined to Default + NULL-owned", ctx do
      default_row = session_owned_by!(ctx.default_ws, "Default-owned chat")
      legacy = legacy_unowned_session!(ctx.ws_a, "pre-tenancy chat")

      view = mount!(ctx.conn, ctx.user_flat_raw, "/studio/chat")

      assigns = live_assigns(view)

      assert is_nil(assigns[:api_token]),
             "the flat mount handed this socket an :api_token — not the user arm"

      refute assigns[:scoped_mount?],
             "the flat route set :scoped_mount? — then this is not the flat population"

      # REFUSED on a workspace this admin holds no role in.
      render_click(view, "session-delete", %{"id" => ctx.foreign.id})

      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.foreign.id)

      # LANDS on the workspace whose admin role IS the grant
      # (`LiveAuth.authorize_user/3` checked exactly that role).
      render_click(view, "session-delete", %{"id" => default_row.id})

      refute Repo.get(StudioChatSession, default_row.id),
             "the Default admin could not delete a DEFAULT-owned row — the grant it " <>
               "holds is an admin role in that very workspace"

      # LANDS on a NULL-owned legacy row — the same carve-out a Default-BOUND
      # token gets, and the reason this is not a wholesale narrowing.
      render_click(view, "session-delete", %{"id" => legacy.id})

      refute Repo.get(StudioChatSession, legacy.id),
             "a pre-tenancy NULL-owned row became unmanageable from the flat admin " <>
               "surface — the legacy carve-out was dropped"
    end

    test "K4: a Default-bound admin TOKEN on ws B's SCOPED mount acts in ws B", ctx do
      # The binding that makes this kind distinct: `create_token/5` pins an
      # omitted workspace to Default, so a scoped admin acting in B routinely
      # holds a DEFAULT-bound token. The URL workspace is the truth, not the
      # token's binding — which is why the guard must read the same
      # `read_workspace_id/1` the LOAD seam does.
      raw = "usertenancy-scopedtok-#{System.unique_integer([:positive])}"

      {:ok, token} =
        Auth.create_token(
          raw,
          "usertenancy scoped tok",
          "production",
          ["read", "write", "admin"],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      assert Repo.get(Barkpark.Auth.ApiToken, token.id).workspace_id == ctx.default_ws.id,
             "the fixture token is not Default-bound — this arm would not separate " <>
               "the token binding from the URL workspace"

      {:ok, _} = TenancyAuth.create_membership(ctx.ws_b.id, token.id, "admin")

      view = mount_token!(ctx.conn, raw, ctx.scoped_path)

      render_click(view, "session-delete", %{"id" => ctx.foreign.id})

      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.foreign.id)

      # POSITIVE CONTROL — and a second correction: under the token-binding
      # guard this DEFAULT-bound token was refused its own ws-B row, because the
      # write axis asked Default while the read axis asked B.
      render_click(view, "session-delete", %{"id" => ctx.own.id})

      refute Repo.get(StudioChatSession, ctx.own.id),
             "the scoped ws-B admin could not delete a ws-B row — the write guard is " <>
               "still reading the token binding instead of the URL workspace"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp mount_token!(conn, raw, path) do
    result = live(init_test_session(conn, %{"api_token" => raw}), path)

    assert match?({:ok, _view, _html}, result),
           "the token principal failed to mount #{path} — every assertion that " <>
             "follows would be vacuous (got #{inspect(result)})"

    {:ok, view, _html} = result
    view
  end

  # A pre-tenancy row: `create_session/2` always stamps an owner from its scope,
  # so the NULL owner is written directly.
  defp legacy_unowned_session!(ws, title) do
    session = session_owned_by!(ws, title)

    {:ok, session} =
      session |> Ecto.Changeset.change(%{owner_workspace_id: nil}) |> Repo.update()

    assert is_nil(Repo.get(StudioChatSession, session.id).owner_workspace_id),
           "the legacy fixture still carries an owner — the NULL carve-out arm is vacuous"

    session
  end

  defp live_assigns(view) do
    %{socket: %Phoenix.LiveView.Socket{assigns: assigns}} = :sys.get_state(view.pid)
    assigns
  end

  defp mount!(conn, user_session_raw, path) do
    result = live(init_test_session(conn, %{"user_session" => user_session_raw}), path)

    # `assert pattern = expr, msg` would make this message dead code
    # (scripts/unreachable-assert-message-check.sh) — assert on match?/2 first.
    assert match?({:ok, _view, _html}, result),
           "the user-session admin failed to mount #{path} — every assertion that " <>
             "follows would be vacuous (got #{inspect(result)})"

    {:ok, view, _html} = result
    view
  end

  defp workspace!(prefix) do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "#{prefix}-#{System.unique_integer([:positive])}",
        name: String.upcase(prefix)
      })

    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    ws
  end

  defp session_owned_by!(ws, title) do
    {:ok, session} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), title: title, title_source: "human"},
        {:workspace, ws.id}
      )

    session
  end

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    proj =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, p} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
          p

        p ->
          p
      end

    {ws, proj}
  end

  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end
end
