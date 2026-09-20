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
  The FLAT `/studio/chat` mount is a SECOND population with its own ruling
  (see the PR body); its arm lands with the fix, not in this RED-first commit.

  The fake runtime is enabled in every test: `ChatLive.mount/3` refuses when no
  provider is enabled and redirects to the same `/studio` an authz denial does,
  so a runtime-less mount would make every refusal assertion vacuously green.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
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

  # ── Helpers ─────────────────────────────────────────────────────────────

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
