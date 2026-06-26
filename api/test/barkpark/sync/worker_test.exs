defmodule Barkpark.Sync.WorkerTest do
  @moduledoc """
  Deterministic GenServer tests for `Barkpark.Sync.Worker`, driving the REAL
  process via injected `stream_fun`/`backoff_fun`/`unresolved_backoff_fun`
  seams (Goal C). No network, no `Process.sleep` — every assertion is
  `assert_receive`/`refute_received`/`:sys.get_state` (invariant #5). Run with
  `name: nil` so the singleton name never collides under `async: false`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Sync.{Settings, Worker}

  describe "listen wire (regression: live run caught flat URL + 406 Accept)" do
    @wire_settings %Settings{
      url: "https://api.barkpark.cloud",
      token: "tok",
      workspace: "gyldendal",
      project: "default",
      dataset: "production"
    }

    test "listen_url is SCOPED to /w/<ws>/p/<proj> (not the flat Default endpoint)" do
      assert Worker.listen_url(@wire_settings) ==
               "https://api.barkpark.cloud/w/gyldendal/p/default/v1/data/listen/production"
    end

    test "a trailing slash on the url is trimmed" do
      assert Worker.listen_url(%{@wire_settings | url: "https://api.barkpark.cloud/"}) ==
               "https://api.barkpark.cloud/w/gyldendal/p/default/v1/data/listen/production"
    end

    test "Accept is */* (NOT text/event-stream, which the endpoint 406s)" do
      headers = Worker.request_headers(@wire_settings, nil)
      assert {"accept", "*/*"} in headers
      refute Enum.any?(headers, fn {k, v} -> k == "accept" and v == "text/event-stream" end)
    end

    test "resume rides the Last-Event-ID header" do
      assert {"last-event-id", "4179"} in Worker.request_headers(@wire_settings, 4179)
    end
  end

  test "reconnects with a fresh ref after the stream closes" do
    test_pid = self()

    fake = fn parent, ref, _settings, since ->
      send(test_pid, {:connected, ref, since})
      send(parent, {:sse_closed, ref, :closed})
    end

    settings = %Settings{
      source: "t-#{System.unique_integer([:positive])}",
      dataset: "test",
      workspace: nil,
      max_attempts: 5
    }

    {:ok, _pid} =
      Worker.start_link(
        name: nil,
        settings: settings,
        stream_fun: fake,
        backoff_fun: fn _ -> 0 end
      )

    assert_receive {:connected, ref1, 0}
    assert_receive {:connected, ref2, _}
    assert ref1 != ref2
  end

  test "a stream close goes through the normal connection backoff" do
    test_pid = self()

    fake = fn parent, ref, _s, _since ->
      send(parent, {:sse_closed, ref, :closed})
    end

    settings = %Settings{
      source: "t-#{System.unique_integer([:positive])}",
      dataset: "test",
      workspace: nil,
      max_attempts: 5
    }

    {:ok, _} =
      Worker.start_link(
        name: nil,
        settings: settings,
        stream_fun: fake,
        backoff_fun: fn a ->
          send(test_pid, {:backoff, a})
          0
        end
      )

    assert_receive {:backoff, _}
  end

  test "an unresolved workspace uses the hard-backoff, never the normal backoff, and is observable" do
    test_pid = self()

    poison =
      "id: 1\nevent: mutation\n" <>
        ~s(data: {"result":{"_id":"x","_type":"post","_draft":false,"title":"x","content":{}},"type":"post"}\n\n)

    fake = fn parent, ref, _s, _since ->
      send(test_pid, {:connected, ref})
      send(parent, {:sse_chunk, ref, poison})
    end

    settings = %Settings{
      source: "t-#{System.unique_integer([:positive])}",
      dataset: "test",
      workspace: "no-such-ws-#{System.unique_integer([:positive])}",
      max_attempts: 5
    }

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        settings: settings,
        stream_fun: fake,
        unresolved_backoff_fun: fn -> 0 end,
        backoff_fun: fn a ->
          send(test_pid, {:backoff, a})
          0
        end
      )

    assert_receive {:connected, _ref1}
    # In-band barrier: a synchronous call guarantees the poison chunk was fully
    # processed before we inspect state.
    state = :sys.get_state(pid)
    assert state.halted_reason == :unresolved_workspace
    refute_received {:backoff, _}
    assert_receive {:connected, _ref2}
  end
end
