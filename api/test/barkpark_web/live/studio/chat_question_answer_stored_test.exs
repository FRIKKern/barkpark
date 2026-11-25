defmodule BarkparkWeb.Studio.ChatQuestionAnswerStoredTest do
  @moduledoc """
  task-48d523fa9c04c354: a question answered from Studio's form was delivered
  and its row flipped to "allowed", but the picked options were not stored, so
  a reader after a reload (BarkBot, task-189078c39ac04e2d) saw no selection.
  The HTTP answer stores them since task-70baa54b6bc7b54f; Studio's
  `ApprovalAnswer.resolve/4` now does the same for a question row.

  The session is real: the operator's tab sends a turn into a `tee` runtime,
  the Recorder asks (so the ask is a stored row), and the tab answers it.
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
    wire = Path.join(System.tmp_dir!(), "studio-answers-#{System.unique_integer([:positive])}")
    keys = [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]
    prev = Map.new(keys, &{&1, Application.get_env(:barkpark, &1)})

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

    raw = "studio-answers-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "operator", "production", ["read", "write", "admin"], default_ws.id)

    {:ok, view, _} = live(init_test_session(conn, %{"api_token" => raw}), "/studio/chat")
    render_submit(element(view, "form[phx-submit=send]"), %{"message" => "turn one"})
    sid = :sys.get_state(view.pid).socket.assigns[:store_session_id]
    assert is_binary(sid), "the tab never stored its session"
    assert await_wire(wire, &String.contains?(&1, "turn one"))

    %{view: view, sid: sid, wire: wire}
  end

  defp wire_text(wire), do: if(File.exists?(wire), do: File.read!(wire), else: "")

  defp await_wire(wire, pred, tries \\ 200) do
    cond do
      pred.(wire_text(wire)) -> true
      tries <= 0 -> flunk("the wire never matched: #{inspect(wire_text(wire))}")
      true -> Process.sleep(20) && await_wire(wire, pred, tries - 1)
    end
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

  defp row(sid, rid),
    do: Enum.find(StudioChat.list_messages(sid, :global), &(&1.metadata["request_id"] == rid))

  defp responded?(wire, rid),
    do: await_wire(wire, &String.contains?(&1, ~s("request_id":"#{rid}")))

  @ask %{
    "questions" => [
      %{"question" => "Go?", "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
    ]
  }

  test "a question answered from the form keeps the picked options on its row",
       %{view: view, sid: sid, wire: wire} do
    ask!(sid, "r-q", "AskUserQuestion", @ask)
    render(view)

    render_click(
      element(
        view,
        ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Yes"])
      )
    )

    render_click(element(view, ~s(button[phx-click=question-submit][phx-value-rid="r-q"])))
    assert responded?(wire, "r-q")

    stored = row(sid, "r-q")
    assert stored.metadata["approval_status"] == "allowed"
    assert stored.metadata["answers"] == %{"Go?" => "Yes"}
  end

  test "CONTROL: a dismissed question stores denied and no answers",
       %{view: view, sid: sid, wire: wire} do
    ask!(sid, "r-d", "AskUserQuestion", @ask)
    render(view)

    render_click(element(view, ~s(button[phx-click=question-dismiss][phx-value-rid="r-d"])))
    assert responded?(wire, "r-d")

    stored = row(sid, "r-d")
    assert stored.metadata["approval_status"] == "denied"
    refute Map.has_key?(stored.metadata, "answers")
  end

  test "CONTROL: an approved tool ask stores allowed and no answers",
       %{view: view, sid: sid, wire: wire} do
    ask!(sid, "r-a", "Bash", %{"command" => "ls"})
    render(view)

    render_click(element(view, ~s(button[phx-click=approve][phx-value-rid=r-a])))
    assert responded?(wire, "r-a")

    stored = row(sid, "r-a")
    assert stored.metadata["approval_status"] == "allowed"
    refute Map.has_key?(stored.metadata, "answers")
  end
end
