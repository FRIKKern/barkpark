defmodule BarkparkWeb.Studio.ChatCoviewHostGateTest do
  @moduledoc """
  task-ec484ce3ff311a3a: a Studio tab that CO-VIEWS a session whose runtime is
  already running is handed the live Session pid by `load_stored_session/2`
  with no `HostExecutionGate` check. The spawn path is gated
  (`spawn_session/3`), but a co-viewer never spawns, so with the operator
  allowlist armed a non-operator Default admin could approve, plan-approve,
  answer a question, or send a turn into an instance-host session — the acts
  `POST /v1/chat/sessions/:id/approval` (allow) and `/messages` refuse with 403
  `host_execution_not_permitted` for the same principal.

  The wire is a `tee` of the runtime's stdin. Each refusal is proven by
  ORDERING, not by a sleep: the refused act and a later act that must pass go
  through the same Session, so the first frame for that request id (or the
  later turn's text) is on the wire only after the refused one would have been.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]
  import Barkpark.TenancyFixtures, only: [ensure_default_scope!: 0]

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.HostExecution
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ChatHostGate

  setup %{conn: conn} do
    {default_ws, _} = ensure_default_scope!()

    wire = Path.join(System.tmp_dir!(), "coview-gate-#{System.unique_integer([:positive])}")

    prev = %{
      claude_chat: Application.get_env(:barkpark, :claude_chat),
      public_demo_studio: Application.get_env(:barkpark, :public_demo_studio),
      operator_emails: Application.get_env(:barkpark, :operator_emails),
      operator_token_ids: Application.get_env(:barkpark, :operator_token_ids)
    }

    # Explicit global :self_hosted — a managed claude turn then runs on the
    # instance host, the case the gate exists for.
    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      execution_profile: :self_hosted,
      command: {"sh", ["-c", "tee '#{wire}' >/dev/null"]}
    )

    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
      end

      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end

      File.rm(wire)
    end)

    %{conn: conn, default_ws: default_ws, wire: wire}
  end

  # A Default-bound admin token — the instance principal once named on the
  # allowlist. Returns {raw, token}.
  defp default_admin_token!(default_ws) do
    raw = "coview-op-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(raw, "operator", "production", ["read", "write", "admin"], default_ws.id)

    {raw, token}
  end

  defp arm_allowlist!(token),
    do: Application.put_env(:barkpark, :operator_token_ids, [token.id])

  defp default_admin_user!(default_ws) do
    user = register_user("coview-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, user.id, "admin", "user")
    user
  end

  defp mount_token(conn, raw, path) do
    {:ok, view, _} = live(init_test_session(conn, %{"api_token" => raw}), path)
    view
  end

  defp mount_user(conn, user, path) do
    {:ok, session} = Accounts.create_user_session_token(user)
    {:ok, view, _} = live(init_test_session(conn, %{"user_session" => session}), path)
    view
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The Studio refusal line as it renders (HTML-escaped: "instance&#39;s").
  defp refusal,
    do: HostExecution.message() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @host_caps %{
    "protocol_version" => 1,
    "providers" => %{
      "claude" => %{
        "installed" => true,
        "auth_ready" => true,
        "operations" => ~w(send_turn steer interrupt answer_approval close),
        "task_hands" => true
      }
    }
  }

  # The operator starts a live host session and leaves it running.
  defp start_live_session!(conn, op_raw, wire) do
    view = mount_token(conn, op_raw, "/studio/chat")
    render_submit(element(view, "form[phx-submit=send]"), %{"message" => "operator turn one"})
    sid = lv_assigns(view)[:store_session_id]
    assert is_pid(lv_assigns(view)[:session]), "the operator's spawn did not come up"
    assert await_wire(wire, &String.contains?(&1, "operator turn one"))
    {view, sid}
  end

  defp ask!(sid, rid, tool, input) do
    recorder = Recorder.whereis(sid)
    assert is_pid(recorder), "no live recorder for #{sid}"

    send(
      recorder,
      {:claude_chat_permission,
       %{request_id: rid, tool_name: tool, input: input, title: nil, decision_reason: nil}}
    )

    :sys.get_state(recorder)
    :ok
  end

  defp wire_text(wire), do: if(File.exists?(wire), do: File.read!(wire), else: "")

  defp await_wire(wire, pred, tries \\ 200) do
    cond do
      pred.(wire_text(wire)) -> true
      tries <= 0 -> flunk("the wire never matched: #{inspect(wire_text(wire))}")
      true -> Process.sleep(20) && await_wire(wire, pred, tries - 1)
    end
  end

  # The FIRST control_response on the wire for `rid`.
  defp first_response(wire, rid) do
    find = fn ->
      wire
      |> wire_text()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode/1)
      |> Enum.find_value(fn
        {:ok, %{"type" => "control_response", "response" => %{"request_id" => ^rid} = r}} -> r
        _ -> nil
      end)
    end

    await_wire(wire, fn _ -> find.() != nil end)
    find.()
  end

  defp approval_status(sid, rid) do
    StudioChat.list_messages(sid, :global)
    |> Enum.find(&(&1.metadata["request_id"] == rid))
    |> then(&(&1 && &1.metadata["approval_status"]))
  end

  describe "allowlist armed: a non-operator Default admin co-viewing a live host session" do
    setup %{conn: conn, default_ws: default_ws, wire: wire} do
      {op_raw, op_token} = default_admin_token!(default_ws)
      arm_allowlist!(op_token)
      {op_view, sid} = start_live_session!(conn, op_raw, wire)

      coviewer = mount_user(conn, default_admin_user!(default_ws), "/studio/chat/#{sid}")
      assert is_pid(lv_assigns(coviewer)[:session]), "the co-view precondition: a live pid"

      %{op_view: op_view, sid: sid, coviewer: coviewer}
    end

    test "cannot approve a tool ask (a deny still goes through)", ctx do
      ask!(ctx.sid, "r-allow", "Bash", %{"command" => "cat /opt/barkpark/.env"})

      html =
        render_click(element(ctx.coviewer, ~s(button[phx-click=approve][phx-value-rid=r-allow])))

      assert approval_status(ctx.sid, "r-allow") == "pending"
      assert html =~ refusal()

      render_click(element(ctx.coviewer, ~s(button[phx-click=deny][phx-value-rid=r-allow])))
      assert %{"response" => %{"behavior" => "deny"}} = first_response(ctx.wire, "r-allow")
    end

    test "cannot approve a plan (keep-planning still goes through)", ctx do
      ask!(ctx.sid, "r-plan", "ExitPlanMode", %{"plan" => "# Plan\n\n1. run a shell"})

      html =
        render_click(
          element(ctx.coviewer, ~s(button[phx-click=plan-approve][phx-value-rid=r-plan]))
        )

      assert approval_status(ctx.sid, "r-plan") == "pending"
      assert html =~ refusal()

      render_click(element(ctx.coviewer, ~s(button[phx-click=plan-keep][phx-value-rid=r-plan])))
      assert %{"response" => %{"behavior" => "deny"}} = first_response(ctx.wire, "r-plan")
    end

    test "cannot answer a question (dismiss still goes through)", ctx do
      ask!(ctx.sid, "r-q", "AskUserQuestion", %{
        "questions" => [%{"question" => "Go?", "options" => [%{"label" => "Yes"}]}]
      })

      render(ctx.coviewer)

      render_click(
        element(
          ctx.coviewer,
          ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Yes"])
        )
      )

      html =
        render_click(
          element(ctx.coviewer, ~s(button[phx-click=question-submit][phx-value-rid="r-q"]))
        )

      assert approval_status(ctx.sid, "r-q") == "pending"
      assert html =~ refusal()

      render_click(
        element(ctx.coviewer, ~s(button[phx-click=question-dismiss][phx-value-rid="r-q"]))
      )

      assert %{"response" => %{"behavior" => "deny"}} = first_response(ctx.wire, "r-q")
    end

    test "cannot send a turn (the words come back to the composer)", ctx do
      render_submit(element(ctx.coviewer, "form[phx-submit=send]"), %{
        "message" => "coviewer forbidden turn"
      })

      html = render(ctx.coviewer)

      # The operator's later turn reaches the same Session after the refused one
      # would have: once it is on the wire, the refused one never will be.
      render_submit(element(ctx.op_view, "form[phx-submit=send]"), %{
        "message" => "operator turn two"
      })

      assert await_wire(ctx.wire, &String.contains?(&1, "operator turn two"))
      refute wire_text(ctx.wire) =~ "coviewer forbidden turn"
      assert html =~ refusal()
      assert lv_assigns(ctx.coviewer)[:composer_draft] == "coviewer forbidden turn"
    end
  end

  describe "CONTROLS: legit co-viewers keep resolving asks" do
    test "a second operator tab (allowlist armed) approves", %{conn: conn} = ctx do
      {op_raw, op_token} = default_admin_token!(ctx.default_ws)
      arm_allowlist!(op_token)
      {_op_view, sid} = start_live_session!(conn, op_raw, ctx.wire)

      tab2 = mount_token(conn, op_raw, "/studio/chat/#{sid}")
      ask!(sid, "r-op", "Bash", %{"command" => "ls"})

      html = render_click(element(tab2, ~s(button[phx-click=approve][phx-value-rid=r-op])))
      refute html =~ refusal()
      assert %{"response" => %{"behavior" => "allow"}} = first_response(ctx.wire, "r-op")
      assert approval_status(sid, "r-op") == "allowed"
    end

    test "with no operator allowlist, a Default admin co-viewer approves and sends",
         %{conn: conn} = ctx do
      {op_raw, _} = default_admin_token!(ctx.default_ws)
      {_op_view, sid} = start_live_session!(conn, op_raw, ctx.wire)

      coviewer = mount_user(conn, default_admin_user!(ctx.default_ws), "/studio/chat/#{sid}")
      ask!(sid, "r-default", "Bash", %{"command" => "ls"})

      render_click(element(coviewer, ~s(button[phx-click=approve][phx-value-rid=r-default])))
      assert %{"response" => %{"behavior" => "allow"}} = first_response(ctx.wire, "r-default")

      render_submit(element(coviewer, "form[phx-submit=send]"), %{"message" => "default turn"})
      render(coviewer)
      assert await_wire(ctx.wire, &String.contains?(&1, "default turn"))
    end
  end

  describe "ChatHostGate.authorize/2 (allowlist armed, a non-operator principal)" do
    setup ctx do
      {_raw, op_token} = default_admin_token!(ctx.default_ws)
      arm_allowlist!(op_token)
      %{assigns: %{current_user: default_admin_user!(ctx.default_ws), api_token: nil}}
    end

    defp row!(ws, attrs) do
      {:ok, row} =
        StudioChat.create_session(
          Map.merge(%{id: Ecto.UUID.generate(), title: "gate", title_source: "human"}, attrs),
          {:workspace, ws.id}
        )

      row
    end

    test "refuses a managed host session, passes a deny", ctx do
      row = row!(ctx.default_ws, %{execution_target: "managed"})
      assigns = Map.put(ctx.assigns, :store_session_id, row.id)

      assert {:error, :host_execution_not_permitted} = ChatHostGate.authorize(assigns, :allow)
      assert :ok = ChatHostGate.authorize(assigns, {:deny, "no"})
    end

    test "passes a registered_host session", ctx do
      {:ok, issued} =
        ChatHosts.issue_enrollment(ctx.default_ws.id, %{
          name: "gate-host-#{System.unique_integer([:positive])}",
          approved_roots: [System.tmp_dir!()],
          capabilities: @host_caps
        })

      {:ok, %{credential: credential}} =
        ChatHosts.enroll(issued.enrollment_token, %{capabilities: @host_caps})

      {:ok, host} = ChatHosts.authenticate(credential)

      row =
        row!(ctx.default_ws, %{execution_target: "registered_host", execution_host_id: host.id})

      assert :ok =
               ChatHostGate.authorize(Map.put(ctx.assigns, :store_session_id, row.id), :allow)
    end

    test "passes a managed session under the cloud profile", ctx do
      {:ok, _} =
        Tenancy.set_workspace_chat_settings(ctx.default_ws.id, %{"execution_profile" => "cloud"})

      row = row!(ctx.default_ws, %{execution_target: "managed"})

      assert :ok =
               ChatHostGate.authorize(Map.put(ctx.assigns, :store_session_id, row.id), :allow)
    end
  end
end
