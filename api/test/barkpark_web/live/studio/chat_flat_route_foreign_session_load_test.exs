defmodule BarkparkWeb.Studio.ChatFlatRouteForeignSessionLoadTest do
  @moduledoc """
  task-60df475d8333e040 — can a foreign session be LOADED onto the socket on the
  flat `/studio/chat/:session_id` route, turning every socket-own-session clause
  into a cross-tenant write by a second hop?

  ## The question, and why the load seam is the whole exposure

  `#14593` closed the four ID-ADDRESSED lifecycle clauses (`session-rename`,
  `session-archive`, `session-unarchive`, `session-delete`) with
  `ChatLive.tenancy_permits?/2`, which reads the acting TOKEN's binding
  (`principal_workspace_id/1`) and refuses a row owned by another workspace.

  The remaining ~34 `handle_event` clauses — `send`, `stop_turn`, `approve`,
  `deny`, `plan-approve`, `question-*`, `set-model`, `set-effort`, `set-mode`,
  … — never take an id off the wire. They act on `socket.assigns.store_session_id`.
  `tenancy_permits?/2` therefore does not and cannot cover them: there is no id
  to check. Their tenancy is decided ENTIRELY by what put a value in
  `store_session_id`, which is `load_stored_session/2`, whose only caller is the
  `handle_params/3` clause that reads the `:session_id` URL segment.

  So the question is a LOAD question, and it is answered here by run, not by
  reading: mount the flat route with a workspace-B-bound admin token, navigate
  to a workspace-A-owned session id, and look at PRESENCE — `store_session_id`,
  the rendered transcript, and whether a subsequent socket-own-session event
  (`set-model`) lands on workspace A's row.

  ## The fixture cannot make the answer vacuous

  Both directions are pinned before the navigation: the target session is
  asserted `owner_workspace_id == ws_a.id`, the acting token is minted with an
  EXPLICIT `ws_b.id` (`Auth.create_token/5` silently binds an omitted workspace
  to the seeded Default, which is workspace A here — that default is exactly how
  this fixture would go vacuous), and the two workspace ids are asserted
  different. A NULL-owned session, or two sessions in one workspace, would prove
  nothing in either direction.

  The mount is asserted too: `ChatLive.mount/3` refuses when no provider is
  enabled, and a mount that never happened would make every assertion below
  green for the wrong reason.

  ## The control

  The refusal arm only means something beside a LANDS arm on the SAME socket:
  the ws-B principal opens its OWN ws-B session and `set-model` lands there.
  A guard that simply broke session loading outright would satisfy the refusal
  assertion; only the LANDS arm tells a tenancy check apart from a dead feature.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy

  @flat_path "/studio/chat"

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    {ws_a, _proj_a} = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "chatflat-b-#{System.unique_integer([:positive])}",
        name: "Chat Flat B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    enable_fake_chat()

    # The PRINCIPAL: an admin token bound EXPLICITLY to workspace B. The explicit
    # id matters — omitting it binds the token to the seeded Default workspace,
    # which is workspace A here, and the cross-tenant question would evaporate.
    raw = "chatflat-bound-b-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "chat flat ws-b admin", "production", ["read", "write", "admin"], ws_b.id)

    foreign = session_owned_by!(ws_a, "ws-A private chat")
    own = session_owned_by!(ws_b, "ws-B own chat")

    {:ok, _} =
      StudioChat.append_message(foreign.id, %{
        role: "user",
        source_markdown: "WS-A-SECRET-TRANSCRIPT-LINE"
      })

    # ── Non-vacuity preconditions (criterion 2) ────────────────────────────────
    refute ws_a.id == ws_b.id,
           "the two workspaces are the same row — there is no tenancy line to cross"

    assert Repo.get(StudioChatSession, foreign.id).owner_workspace_id == ws_a.id,
           "the target session is not workspace-A-OWNED — the navigation would prove nothing"

    assert Repo.get(StudioChatSession, own.id).owner_workspace_id == ws_b.id,
           "the control session is not workspace-B-OWNED — the LANDS arm would be vacuous"

    %{
      conn: init_test_session(conn, %{"api_token" => raw}),
      ws_a: ws_a,
      ws_b: ws_b,
      foreign: foreign,
      own: own
    }
  end

  describe "flat :admin_studio — /studio/chat/:session_id with a ws-B-bound admin token" do
    test "a workspace-A session is REFUSED onto the socket, and no second hop can reach it",
         %{conn: conn, foreign: foreign} do
      {view, html} = mount_flat!(conn, "#{@flat_path}/#{foreign.id}")

      assigns = :sys.get_state(view.pid).socket.assigns

      # PRESENCE #1 — the socket never adopts the foreign id.
      refute assigns[:store_session_id] == foreign.id,
             "a ws-B-bound admin LOADED workspace-A's chat session onto the socket " <>
               "(store_session_id == #{inspect(assigns[:store_session_id])}) — every " <>
               "socket-own-session clause is now a cross-tenant write by a second hop"

      # PRESENCE #2 — workspace A's transcript is not on the screen. The string
      # was written to the store in setup, so its absence is a refusal and not a
      # missing fixture.
      refute html =~ "WS-A-SECRET-TRANSCRIPT-LINE",
             "workspace-A's transcript rendered on a ws-B-bound admin's socket"

      # PRESENCE #3 — the SECOND HOP. `set-model` takes no id off the wire; it
      # writes to whatever `store_session_id` holds. With the load refused there
      # is nothing for it to reach, and workspace A's row keeps the value read
      # back a statement earlier.
      before_choice = Repo.get(StudioChatSession, foreign.id).model_choice

      render_click(view, "set-model", %{"model" => "opus"})

      assert Repo.get(StudioChatSession, foreign.id).model_choice == before_choice,
             "a socket-own-session clause wrote workspace-A's session row " <>
               "(model_choice #{inspect(before_choice)} -> " <>
               "#{inspect(Repo.get(StudioChatSession, foreign.id).model_choice)})"
    end

    test "the SAME principal's OWN ws-B session loads and takes the same second hop",
         %{conn: conn, own: own} do
      {view, _html} = mount_flat!(conn, "#{@flat_path}/#{own.id}")

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns[:store_session_id] == own.id,
             "the ws-B admin could not open its OWN session on the flat route — " <>
               "the refusal arm above would be a dead feature, not a tenancy check " <>
               "(got #{inspect(assigns[:store_session_id])})"

      refute Repo.get(StudioChatSession, own.id).model_choice == "opus",
             "the control row already carries the value the write is about to set"

      render_click(view, "set-model", %{"model" => "opus"})

      assert Repo.get(StudioChatSession, own.id).model_choice == "opus",
             "the socket-own-session clause did not land on the principal's OWN row"
    end

    test "an UNBOUND admin token keeps the :global superuser load (charter D17/D18)",
         %{conn: conn, foreign: foreign} do
      # `principal_workspace_id/1` is nil only when the token carries no
      # workspace at all. That principal is the genuine instance superuser the
      # flat route exists for, and the binding added here must not clamp it.
      raw = "chatflat-unbound-#{System.unique_integer([:positive])}"

      {:ok, token} =
        Auth.create_token(raw, "chat flat unbound admin", "production", ["read", "write", "admin"])

      {:ok, _} = token |> Ecto.Changeset.change(%{workspace_id: nil}) |> Repo.update()

      assert Repo.get(Barkpark.Auth.ApiToken, token.id).workspace_id == nil,
             "the unbound fixture still carries a workspace binding — this arm would " <>
               "not exercise the nil-principal path"

      conn = init_test_session(conn, %{"api_token" => raw})
      {view, html} = mount_flat!(conn, "#{@flat_path}/#{foreign.id}")

      assert :sys.get_state(view.pid).socket.assigns[:store_session_id] == foreign.id,
             "the unbound instance superuser lost the :global load the flat route is for"

      assert html =~ "WS-A-SECRET-TRANSCRIPT-LINE",
             "the unbound instance superuser lost the replayed transcript"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp session_owned_by!(ws, title) do
    {:ok, session} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), title: title, title_source: "human"},
        {:workspace, ws.id}
      )

    session
  end

  # Mount and PROVE it mounted. `assert match?/2` first, then destructure —
  # `assert pattern = expr, msg` would make the message dead code
  # (scripts/unreachable-assert-message-check.sh).
  defp mount_flat!(conn, path) do
    result = live(conn, path)

    assert match?({:ok, _view, _html}, result),
           "the admin token failed to mount #{path} — every assertion in this test " <>
             "would be vacuous (got #{inspect(result)})"

    {:ok, view, html} = result
    {view, html}
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

  # ChatLive.mount refuses when no provider is enabled.
  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) -> DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
        _ -> :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end
end
