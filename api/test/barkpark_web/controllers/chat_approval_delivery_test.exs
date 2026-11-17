defmodule BarkparkWeb.ChatApprovalDeliveryTest do
  @moduledoc """
  `POST /v1/chat/sessions/:id/approval` flips the stored ask before it delivers
  the answer (task-035d3495dae536cf). When the delivery then fails or exits,
  the flip is undone, so the ask is pending again and a resend delivers it
  (rev26731, #26895 probes R2 and R3). Before, the ask stayed "allowed" with
  nothing delivered, and every resend was a no-op.

  The runtime is a scripted adapter: each `answer_approval/3` call takes the
  next step off a script (`:error`, `:exit` or `:ok`) and reports a delivery
  to the test process only on `:ok`.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  defmodule ScriptedAdapter do
    @moduledoc false

    def capabilities, do: %{modes: ["default"], models: ["gpt-5.6"], efforts: ["high"]}
    def cwd, do: "/tmp/codex-managed"

    def answer_approval(_ref, request_id, _decision) do
      script = Application.fetch_env!(:barkpark, :chat_approval_delivery_script)

      case Agent.get_and_update(script, fn [step | rest] -> {step, rest} end) do
        :error ->
          {:error, :host_offline}

        :exit ->
          exit(:app_server_gone)

        :ok ->
          send(
            Application.fetch_env!(:barkpark, :chat_approval_delivery_pid),
            {:delivered, request_id}
          )

          :ok
      end
    end
  end

  setup do
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_adapters = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev_adapters || %{}, :codex, ScriptedAdapter)
    )

    Application.put_env(:barkpark, :chat_approval_delivery_pid, self())

    on_exit(fn ->
      reap_runtimes()

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_adapters,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, prev_adapters),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)

      Application.delete_env(:barkpark, :chat_approval_delivery_script)
      Application.delete_env(:barkpark, :chat_approval_delivery_pid)
    end)

    raw = "chat-delivery-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "chat-delivery", @dataset, ["read", "write", "admin"])

    {:ok, session} =
      StudioChat.create_session(%{
        id: Ecto.UUID.generate(),
        cwd: ClaudeChat.cwd(),
        mode: "plan",
        provider: "codex"
      })

    {:ok, _} =
      StudioChat.append_message(session, %{
        role: "approval",
        source_markdown: "Allow Write /tmp/example?",
        metadata: %{
          "request_id" => "req-1",
          "tool_name" => "Write",
          "input" => %{"file_path" => "/tmp/example"},
          "approval_status" => "pending"
        }
      })

    {:ok, _} = Recorder.ensure(%{session_id: session.id, mode: "plan", resume: false})

    %{raw: raw, sid: session.id}
  end

  for first <- [:error, :exit] do
    test "a delivery that #{if first == :error, do: "fails", else: "exits"} leaves the ask pending, and a resend delivers once",
         %{raw: raw, sid: sid} do
      script!([unquote(first), :ok])

      resp = approve(raw, sid)
      assert resp.status == 503, "the failed delivery answered #{resp.status}: #{resp.resp_body}"
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "runtime_unavailable"
      refute_received {:delivered, _}
      assert approval_status(sid) == "pending", "an undelivered answer must not stand"
      assert StudioChat.get_session(sid).pending_approvals == 1

      assert approve(raw, sid).status == 204
      assert_received {:delivered, "req-1"}
      refute_received {:delivered, _}
      assert approval_status(sid) == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end
  end

  test "a delivered answer stands and a repeat delivers nothing", %{raw: raw, sid: sid} do
    script!([:ok])

    assert approve(raw, sid).status == 204
    assert approve(raw, sid).status == 204
    assert_received {:delivered, "req-1"}
    refute_received {:delivered, _}
    assert approval_status(sid) == "allowed"
  end

  defp script!(steps) do
    {:ok, script} = Agent.start_link(fn -> steps end)
    Application.put_env(:barkpark, :chat_approval_delivery_script, script)
  end

  defp approve(raw, sid) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/chat/sessions/#{sid}/approval",
      Jason.encode!(%{request_id: "req-1", decision: "allow"})
    )
  end

  defp approval_status(sid),
    do: StudioChat.get_needs_you_message(sid, "req-1").metadata["approval_status"]

  defp reap_runtimes do
    if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
      for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
        DynamicSupervisor.terminate_child(pid, child)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
