defmodule BarkparkWeb.Studio.ChatOwnerClampTest do
  @moduledoc """
  Owner ruling #30 Q2 + Q3 (2026-10-03, task-1631e0fa917452d9).

  Q2 — the FLAT `/studio/chat` sidebar listed every tenant's chat sessions to a
  Default-workspace admin USER, whose session LOADS were already confined to
  Default. The list now shows exactly what the socket may load: the acting
  workspace's rows. Only the genuinely unbound superuser token keeps the
  instance-wide list.

  Q3 — owner-less (NULL `owner_workspace_id`, pre-tenancy) chat sessions were
  readable, resumable and deletable by every workspace admin on SCOPED mounts.
  A scoped mount now shows only its own workspace's rows. On the flat mount a
  NULL-owned row is open to the instance operator only: the unbound token, or a
  principal `RequirePlatformOperator.permits?/1` admits (when the operator
  allowlist is unset, a single-tenant instance's admins are its operators — the
  plug's own rule).

  The fake runtime is enabled in every test: `ChatLive.mount/3` refuses when no
  provider is enabled.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

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
    default_ws = ensure_default!()
    ws_a = workspace!("clamp-a")
    ws_b = workspace!("clamp-b")

    enable_fake_chat()

    prev_ops = {
      Application.get_env(:barkpark, :operator_emails),
      Application.get_env(:barkpark, :operator_token_ids)
    }

    on_exit(fn ->
      {emails, ids} = prev_ops
      restore(:operator_emails, emails)
      restore(:operator_token_ids, ids)
    end)

    %{
      conn: conn,
      default_ws: default_ws,
      ws_a: ws_a,
      ws_b: ws_b,
      foreign: session_owned_by!(ws_a, "clamp ws-A chat"),
      own_b: session_owned_by!(ws_b, "clamp ws-B chat"),
      default_row: session_owned_by!(default_ws, "clamp Default chat"),
      legacy: legacy_unowned_session!(ws_a, "clamp pre-tenancy chat")
    }
  end

  describe "Q2: the flat sidebar lists what the socket may load" do
    test "a Default admin USER does not see other workspaces' chats", ctx do
      view = mount_user!(ctx.conn, default_admin_user!(ctx.default_ws), "/studio/chat")
      ids = listed_ids(view)

      assert ctx.default_row.id in ids, "the Default admin lost its own workspace's chat"
      refute ctx.foreign.id in ids, "a workspace-A chat is listed to a Default-only admin"
      refute ctx.own_b.id in ids, "a workspace-B chat is listed to a Default-only admin"
    end

    test "a ws-B-bound admin TOKEN lists ws-B chats and not ws-A chats", ctx do
      view = mount_token!(ctx.conn, bound_admin_token!(ctx.ws_b), "/studio/chat")
      ids = listed_ids(view)

      assert ctx.own_b.id in ids
      refute ctx.foreign.id in ids
    end

    test "the unbound superuser token keeps the instance-wide list", ctx do
      view = mount_token!(ctx.conn, unbound_admin_token!(), "/studio/chat")
      ids = listed_ids(view)

      assert ctx.foreign.id in ids
      assert ctx.own_b.id in ids
      assert ctx.legacy.id in ids
    end
  end

  describe "Q3: owner-less chats are the operator's" do
    test "a ws-B admin on B's scoped mount neither lists nor deletes an owner-less chat", ctx do
      user = register_user("clamp-b-#{System.unique_integer([:positive])}@example.test")
      {:ok, _} = TenancyAuth.create_membership(ctx.ws_b.id, user.id, "admin", "user")

      view = mount_user!(ctx.conn, user, "/w/#{ctx.ws_b.slug}/p/default/studio/chat")
      ids = listed_ids(view)

      assert ctx.own_b.id in ids, "the ws-B admin lost its own chat"
      refute ctx.legacy.id in ids, "an owner-less chat is listed on a workspace's scoped mount"

      render_click(view, "session-delete", %{"id" => ctx.legacy.id})
      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.legacy.id)

      # Positive control on the same socket.
      render_click(view, "session-delete", %{"id" => ctx.own_b.id})
      refute Repo.get(StudioChatSession, ctx.own_b.id)
    end

    test "with the operator allowlist armed, a Default admin cannot reach an owner-less chat",
         ctx do
      operator_raw = unbound_admin_token_raw("clamp-op")

      {:ok, operator} =
        Auth.create_token(
          operator_raw,
          "operator",
          "production",
          ["read", "write", "admin"],
          ctx.default_ws.id
        )

      Application.put_env(:barkpark, :operator_token_ids, [operator.id])

      view = mount_user!(ctx.conn, default_admin_user!(ctx.default_ws), "/studio/chat")
      refute ctx.legacy.id in listed_ids(view)

      render_click(view, "session-delete", %{"id" => ctx.legacy.id})
      assert %StudioChatSession{} = Repo.get(StudioChatSession, ctx.legacy.id)

      # The named operator reaches it.
      op_view = mount_token!(ctx.conn, operator_raw, "/studio/chat")
      assert ctx.legacy.id in listed_ids(op_view)

      render_click(op_view, "session-delete", %{"id" => ctx.legacy.id})
      refute Repo.get(StudioChatSession, ctx.legacy.id)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp listed_ids(view) do
    %{socket: %Phoenix.LiveView.Socket{assigns: assigns}} = :sys.get_state(view.pid)
    Enum.map(assigns[:sessions] || [], & &1.id)
  end

  defp default_admin_user!(default_ws) do
    user = register_user("clamp-flat-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, user.id, "admin", "user")
    user
  end

  defp unbound_admin_token_raw(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp bound_admin_token!(ws) do
    raw = unbound_admin_token_raw("clamp-bound")

    {:ok, _} =
      Auth.create_token(raw, "clamp bound", "production", ["read", "write", "admin"], ws.id)

    raw
  end

  defp unbound_admin_token! do
    raw = unbound_admin_token_raw("clamp-unbound")

    {:ok, token} =
      Auth.create_token(raw, "clamp unbound", "production", ["read", "write", "admin"])

    {:ok, _} = token |> Ecto.Changeset.change(%{workspace_id: nil}) |> Repo.update()
    raw
  end

  defp mount_user!(conn, user, path) do
    {:ok, raw} = Accounts.create_user_session_token(user)
    result = live(init_test_session(conn, %{"user_session" => raw}), path)
    assert match?({:ok, _view, _html}, result), "user mount of #{path} failed: #{inspect(result)}"
    {:ok, view, _html} = result
    view
  end

  defp mount_token!(conn, raw, path) do
    result = live(init_test_session(conn, %{"api_token" => raw}), path)

    assert match?({:ok, _view, _html}, result),
           "token mount of #{path} failed: #{inspect(result)}"

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

  defp legacy_unowned_session!(ws, title) do
    session = session_owned_by!(ws, title)
    {:ok, session} = session |> Ecto.Changeset.change(%{owner_workspace_id: nil}) |> Repo.update()
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

    if is_nil(Tenancy.get_default_project()),
      do: {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    ws
  end

  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if(Process.whereis(Barkpark.StudioChat.RuntimeSupervisor),
        do: DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
        else: []
      )
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
