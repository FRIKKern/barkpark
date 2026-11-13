defmodule Barkpark.StudioChat.RecorderHostInterruptTest do
  @moduledoc """
  A Stop on a registered-host turn (task-bb50d873c868f411). The Go host now ends
  an interrupted Claude turn as `turn_completed` with `terminal_state:
  "interrupted"` instead of kind `error`. These tests send the host's own event
  payloads through `ChatHosts.accept_event/2` — the fenced ingress a real host
  posts to, which projects into the session's live Recorder — and read back what
  the Recorder stored.
  """
  use Barkpark.DataCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors and registries.
  @moduletag :requires_plugins

  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    # The Recorder only needs SOME runtime to start; `cat` runs no CLI. The turn's
    # events arrive through the host ingress, not from this process.
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

    :ok
  end

  test "an interrupted host turn stores the partial reply, marked interrupted, and the session stays usable" do
    {sid, post} = host_turn()

    post.(%{"kind" => "turn_started"})
    post.(%{"kind" => "text_delta", "delta" => "Here is the first half of"})
    post.(%{"kind" => "control_completed", "operation" => "interrupt"})
    post.(%{"kind" => "turn_completed", "terminal_state" => "interrupted"})

    assert [reply] = assistant_rows(sid)
    assert reply.source_markdown == "Here is the first half of"
    assert reply.metadata["turn_outcome"] == "interrupted"
    assert StudioChat.get_session(sid).status == "active"
  end

  test "a host turn that completes is not marked interrupted" do
    {sid, post} = host_turn()

    post.(%{"kind" => "turn_started"})
    post.(%{"kind" => "text_delta", "delta" => "All done."})
    post.(%{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert [reply] = assistant_rows(sid)
    assert reply.source_markdown == "All done."
    refute Map.has_key?(reply.metadata, "turn_outcome")
  end

  test "a host turn that fails keeps its partial reply, unmarked, and the session exits" do
    {sid, post} = host_turn()

    post.(%{"kind" => "turn_started"})
    post.(%{"kind" => "text_delta", "delta" => "Partial before a crash"})

    post.(%{
      "kind" => "error",
      "terminal_state" => "failed",
      "error" => %{"type" => "result", "is_error" => true}
    })

    assert [reply] = assistant_rows(sid)
    assert reply.source_markdown == "Partial before a crash"
    refute Map.has_key?(reply.metadata, "turn_outcome")
    assert StudioChat.get_session(sid).status == "exited"
  end

  # One registered-host Claude session with a live Recorder and a leased
  # send_turn; returns the session id and a function that posts one host event
  # on that lease, the way the Go host's Runner does (cursor by cursor).
  defp host_turn do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-stop-#{suffix}", name: "Stop"})
    root = System.tmp_dir!()

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "laptop-#{suffix}",
        approved_roots: [root],
        capabilities: capabilities()
      })

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: capabilities()})
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)

    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host.id
        },
        ws.id
      )

    {:ok, _recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: sid,
      idempotency_key: "stop-#{suffix}",
      payload: %{cwd: root, content: "write a lot"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    cursor = :counters.new(1, [])

    post = fn event ->
      :counters.add(cursor, 1, 1)
      n = :counters.get(cursor, 1)

      assert {:ok, :accepted} =
               ChatHosts.accept_event(host, %{
                 lease_id: fence.lease_id,
                 epoch: fence.epoch,
                 cursor: n,
                 idempotency_key: "stop-#{suffix}-#{n}",
                 event: event
               })
    end

    {sid, post}
  end

  defp assistant_rows(sid),
    do: sid |> StudioChat.list_messages(:global) |> Enum.filter(&(&1.role == "assistant"))

  defp capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
    }
  end
end
