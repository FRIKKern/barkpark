defmodule BarkparkWeb.Studio.ChatResolveSettledAskTest do
  @moduledoc """
  Studio's Allow goes through `ApprovalAnswer` (task-52de5429fbdcb68c). A tab
  keeps a card pending in its own memory, while the store can cancel the ask (a
  teardown, a newer lease's turn) or answer it (`POST /approval` from another
  client) without telling that tab. Before, the click checked only the tab's
  copy: it sent the answer to the runtime and drew "allowed" over the stored
  outcome.

  The wire is a `tee` of the runtime's stdin. "Nothing was sent" is proven by
  ORDER: a later ask is answered through the same Session, and its frame is on
  the wire only after the refused one would have been.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures, only: [ensure_default_scope!: 0]

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  setup %{conn: conn} do
    {default_ws, _} = ensure_default_scope!()
    wire = Path.join(System.tmp_dir!(), "resolve-settled-#{System.unique_integer([:positive])}")
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      execution_profile: :self_hosted,
      command: {"sh", ["-c", "tee '#{wire}' >/dev/null"]}
    )

    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
      end

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      File.rm(wire)
    end)

    raw = "resolve-settled-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "resolve-settled", "production", ~w(read write admin), default_ws.id)

    {:ok, view, _} = live(init_test_session(conn, %{"api_token" => raw}), "/studio/chat")
    render_submit(element(view, "form[phx-submit=send]"), %{"message" => "turn one"})
    sid = :sys.get_state(view.pid).socket.assigns[:store_session_id]
    await_wire(wire, &String.contains?(&1, "turn one"))

    %{view: view, sid: sid, wire: wire}
  end

  test "Allow on a card the store canceled sends nothing and shows canceled", ctx do
    ask!(ctx, "r-gone")
    assert StudioChat.cancel_pending_approvals(ctx.sid) == 1

    html = render_click(element(ctx.view, ~s(button[phx-click=approve][phx-value-rid=r-gone])))

    assert_not_sent(ctx, "r-gone")
    assert status(ctx.sid, "r-gone") == "canceled"
    assert html =~ "✗ canceled"
    refute html =~ "✓ allowed"
  end

  test "Allow on a card another client already denied sends nothing and shows denied", ctx do
    ask!(ctx, "r-elsewhere")
    {:ok, _} = StudioChat.update_approval_status(ctx.sid, "r-elsewhere", "denied")

    html =
      render_click(element(ctx.view, ~s(button[phx-click=approve][phx-value-rid=r-elsewhere])))

    assert_not_sent(ctx, "r-elsewhere")
    assert status(ctx.sid, "r-elsewhere") == "denied"
    assert html =~ "✗ denied"
    refute html =~ "✓ allowed"
  end

  # A later ask, answered through the same Session, is the ordering witness.
  defp assert_not_sent(ctx, rid) do
    ask!(ctx, "r-witness")
    render_click(element(ctx.view, ~s(button[phx-click=approve][phx-value-rid=r-witness])))
    await_wire(ctx.wire, &(responses(&1) |> Enum.member?("r-witness")))
    refute rid in responses(wire_text(ctx.wire)), "the answer to #{rid} reached the runtime"
  end

  defp ask!(ctx, rid) do
    recorder = Recorder.whereis(ctx.sid)
    assert is_pid(recorder), "no live recorder for #{ctx.sid}"

    send(
      recorder,
      {:claude_chat_permission,
       %{request_id: rid, tool_name: "Bash", input: %{}, title: nil, decision_reason: nil}}
    )

    :sys.get_state(recorder)
    assert has_element?(ctx.view, ~s(button[phx-click=approve][phx-value-rid=#{rid}]))
  end

  defp status(sid, rid),
    do: StudioChat.get_needs_you_message(sid, rid).metadata["approval_status"]

  defp responses(text) do
    for line <- String.split(text, "\n", trim: true),
        {:ok, %{"type" => "control_response", "response" => %{"request_id" => rid}}} <-
          [Jason.decode(line)],
        do: rid
  end

  defp wire_text(wire), do: if(File.exists?(wire), do: File.read!(wire), else: "")

  defp await_wire(wire, pred, tries \\ 200) do
    cond do
      pred.(wire_text(wire)) -> true
      tries <= 0 -> flunk("the wire never matched: #{inspect(wire_text(wire))}")
      true -> Process.sleep(20) && await_wire(wire, pred, tries - 1)
    end
  end
end
