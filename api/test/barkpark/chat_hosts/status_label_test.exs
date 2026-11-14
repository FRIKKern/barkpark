defmodule Barkpark.ChatHosts.StatusLabelTest do
  @moduledoc """
  A registered host's turn status label (task-a9983f9aeffb5430): the Go host
  posts `%{"kind" => "status", "label" => "Explaining ocean tides"}` early in a
  turn. The server takes it through the fenced ingress (`ChatHosts.accept_event/2`),
  passes it to the session stream as a runtime event of kind `:status`, never
  stores it as a message and never changes the session's status. A label that
  is not text is refused (and moves no cursor); a long one is cut.
  """
  use Barkpark.DataCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors and registries.
  @moduletag :requires_plugins

  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.Tenancy
  alias BarkparkWeb.ChatController

  setup do
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

    :ok
  end

  test "a status label reaches the session stream as a runtime event, stores no row and leaves the status alone" do
    {sid, post} = host_turn()
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

    assert {:ok, :accepted} = post.(%{"kind" => "turn_started"})
    status_before = StudioChat.get_session(sid).status
    rows_before = StudioChat.list_messages(sid, :global)

    assert {:ok, :accepted} = post.(%{"kind" => "status", "label" => "Explaining ocean tides"})

    assert_receive {:studio_chat_runtime_event, %Event{kind: :status} = event}, 2_000
    assert event.native == %{"kind" => "status", "label" => "Explaining ocean tides"}

    # The frame the session's SSE stream (GET /v1/chat/sessions/:id/events) writes.
    "event: runtime\ndata: " <> data = ChatController.sse_runtime_frame(event)
    frame = Jason.decode!(data)
    assert frame["kind"] == "status"
    assert frame["native"]["label"] == "Explaining ocean tides"

    assert StudioChat.get_session(sid).status == status_before
    assert StudioChat.list_messages(sid, :global) == rows_before

    assert {:ok, :accepted} =
             post.(%{"kind" => "text_delta", "delta" => "Tides come from the moon."})

    assert {:ok, :accepted} =
             post.(%{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert [reply] = assistant_rows(sid)
    assert reply.source_markdown == "Tides come from the moon."

    refute Enum.any?(
             StudioChat.list_messages(sid, :global),
             &(&1.source_markdown =~ "ocean tides")
           )
  end

  test "a long label is cut to 60 characters and its whitespace folded" do
    {sid, post} = host_turn()
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    assert {:ok, :accepted} = post.(%{"kind" => "turn_started"})

    long = "  Explaining\n ocean   tides " <> String.duplicate("and more ", 20)
    assert {:ok, :accepted} = post.(%{"kind" => "status", "label" => long})

    assert_receive {:studio_chat_runtime_event, %Event{kind: :status, native: native}}, 2_000
    assert String.length(native["label"]) <= 60
    assert String.starts_with?(native["label"], "Explaining ocean tides and more")
    refute native["label"] =~ ~r/\s\s|\n|^\s|\s$/
  end

  test "a label of few graphemes but many combining marks is cut by codepoints, not let through by its grapheme count" do
    {sid, post} = host_turn()
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    assert {:ok, :accepted} = post.(%{"kind" => "turn_started"})

    # 12 graphemes, each a letter carrying 166 combining acute accents: 2004
    # codepoints, 4008 bytes. String.slice/3 by graphemes kept all of it.
    heavy = String.duplicate("a" <> String.duplicate("́", 166), 12)
    assert String.length(heavy) == 12
    assert {:ok, :accepted} = post.(%{"kind" => "status", "label" => "Mulling " <> heavy})

    assert_receive {:studio_chat_runtime_event, %Event{kind: :status, native: native}}, 2_000
    assert length(String.codepoints(native["label"])) <= 60
    assert byte_size(native["label"]) <= 240
    assert String.starts_with?(native["label"], "Mulling")
  end

  test "a label that is not text is refused and moves no cursor" do
    {_sid, post} = host_turn()
    assert {:ok, :accepted} = post.(%{"kind" => "turn_started"})

    for label <- [nil, 42, %{"text" => "hi"}, ["Explaining"], "", "   \n  "] do
      assert {:error, :invalid_status_label} = post.(%{"kind" => "status", "label" => label})
    end

    assert {:error, :invalid_status_label} = post.(%{"kind" => "status"})

    # The refused events took no cursor: the next event lands on cursor 2.
    assert {:ok, :accepted} = post.(%{"kind" => "status", "label" => "Mulling it over"})
  end

  test "a retried label is a duplicate, not a conflict" do
    {_sid, post} = host_turn()
    assert {:ok, :accepted} = post.(%{"kind" => "turn_started"})
    event = %{"kind" => "status", "label" => "  Mulling it over  "}
    assert {:ok, :accepted} = post.(event)
    assert {:ok, :duplicate} = post.({:retry, event})
  end

  # One registered-host Claude session with a live Recorder and a leased
  # send_turn; returns the session id and a function that posts one host event
  # at the next cursor the server took, the way the Go host's Runner does (a
  # refused event moves no cursor). `{:retry, event}` re-posts at the last
  # cursor with its key, as the Runner's retry does.
  defp host_turn do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-status-#{suffix}", name: "Status"})
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
      idempotency_key: "status-#{suffix}",
      payload: %{cwd: root, content: "how do ocean tides work?"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    taken = :counters.new(1, [])

    send_at = fn n, event ->
      ChatHosts.accept_event(host, %{
        lease_id: fence.lease_id,
        epoch: fence.epoch,
        cursor: n,
        idempotency_key: "status-#{suffix}-#{n}",
        event: event
      })
    end

    post = fn
      {:retry, event} ->
        send_at.(:counters.get(taken, 1), event)

      event ->
        n = :counters.get(taken, 1) + 1
        result = send_at.(n, event)
        if result == {:ok, :accepted}, do: :counters.put(taken, 1, n)
        result
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
