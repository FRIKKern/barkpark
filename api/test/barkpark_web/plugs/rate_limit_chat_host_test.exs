defmodule BarkparkWeb.Plugs.RateLimitChatHostTest do
  @moduledoc """
  A registered chat host is metered on its OWN bucket, never on the anonymous
  per-IP one (task-fd330c87f48b0b87).

  Live on guerrilla 2026-11-13: `RateLimit` resolved only Bearer and session
  principals, so every `POST /v1/chat-host/events` carrying
  `Authorization: Host <cred>` was billed to `ip:<host ip>:write:global` at the
  anonymous 60/min. The host posts one event per text_delta, so a reply past
  ~60 deltas was refused mid-turn and its heartbeats starved with it.

  The other half is the bypass: only an ENROLLED credential buys the host
  bucket, and only on the mount that accepts the Host scheme. A made-up
  `Host x` header, or a real credential sent to any other pipeline, still
  bills the caller's IP.
  """
  use BarkparkWeb.ConnCase, async: false

  # The studio_chat capability owns /v1/chat-host and the chat supervisors.
  @moduletag :requires_plugins

  import Barkpark.RateLimiterSandbox

  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy
  alias BarkparkWeb.Plugs.RateLimit

  setup :reset_rate_limiter!

  setup do
    original = Application.get_env(:barkpark, :rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)

    # The production defaults, pinned, so the test does not lean on config.exs.
    Application.put_env(:barkpark, :rate_limits,
      read_per_minute: 300,
      write_per_minute: 60,
      datasets: %{}
    )

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rlh-#{suffix}", name: "RLH #{suffix}"})
    {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: "streamer"})
    {:ok, %{credential: credential}} = ChatHosts.enroll(token)
    {:ok, host} = ChatHosts.authenticate(credential)

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws.id})

    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: sid,
      idempotency_key: "rlh-cmd-#{suffix}",
      payload: %{}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])

    %{credential: credential, fence: fence}
  end

  # The rate-limit test scope is per test PROCESS, so every conn a test builds
  # here shares one scope and one peer (127.0.0.1): one host on one box.
  defp as_host(credential) do
    scoped_conn()
    |> put_req_header("authorization", "Host #{credential}")
    |> put_req_header("content-type", "application/json")
  end

  defp delta(credential, fence, cursor) do
    as_host(credential)
    |> post("/v1/chat-host/events", %{
      "lease_id" => fence.lease_id,
      "epoch" => fence.epoch,
      "cursor" => cursor,
      "idempotency_key" => "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
      "event" => %{"kind" => "text_delta", "delta" => "w#{cursor} "}
    })
  end

  test "an enrolled host streams 200 text_delta events in one burst and none is refused",
       %{credential: credential, fence: fence} do
    statuses = for cursor <- 1..200, do: delta(credential, fence, cursor).status

    # Before the fix the 61st was a 429 on ip:<peer>:write:global.
    assert Enum.frequencies(statuses) == %{202 => 200}

    # And the lease's liveness ping is not starved by the stream it is keeping alive.
    assert as_host(credential) |> post("/v1/chat-host/heartbeat", %{}) |> json_response(200)
  end

  test "a made-up Host credential is metered on the caller's IP, even rotated per request",
       _context do
    # A fresh random credential each request: if an unverified credential
    # could key its own bucket, every request would get a full one.
    statuses =
      for _ <- 1..60 do
        as_host("made-up-#{System.unique_integer([:positive])}")
        |> post("/v1/chat-host/events", %{})
        |> Map.fetch!(:status)
      end

    # Each passed the meter and was refused by RequireChatHost, not the limiter.
    assert Enum.frequencies(statuses) == %{401 => 60}

    refused = as_host("made-up-final") |> post("/v1/chat-host/events", %{})
    assert refused.status == 429
    assert json_response(refused, 429)["error"]["details"]["budget"]["principal"] == "ip"
  end

  test "an enrolled host's stream never spends the IP bucket a made-up credential is billed to",
       %{credential: credential, fence: fence} do
    # The host streams past the anonymous budget; a stranger on the same
    # address with a bogus credential still has its full 60 — the two never share.
    for cursor <- 1..100, do: assert(delta(credential, fence, cursor).status == 202)

    statuses =
      for _ <- 1..60 do
        as_host("bogus") |> post("/v1/chat-host/events", %{}) |> Map.fetch!(:status)
      end

    assert Enum.frequencies(statuses) == %{401 => 60}
  end

  describe "the Host scheme buys a host bucket only on the mount that accepts it" do
    defp plug_conn(credential) do
      %{scoped_conn() | method: "POST", request_path: "/v1/auth/request-magic-link"}
      |> put_req_header("authorization", "Host #{credential}")
    end

    test "a real host credential on any other pipeline still bills the IP bucket",
         %{credential: credential} do
      Application.put_env(:barkpark, :rate_limits, read_per_minute: 1, write_per_minute: 1)

      # An option-less mount (every non-host pipeline): the Host scheme is not
      # read, so the caller is anonymous and spends its IP's one write.
      refute RateLimit.call(plug_conn(credential), RateLimit.init([])).halted
      out = RateLimit.call(plug_conn(credential), RateLimit.init([]))
      assert out.halted
      assert json_response(out, 429)["error"]["details"]["budget"]["principal"] == "ip"

      # The host mount reads it, and the host's own bucket is untouched by that.
      opts = RateLimit.init(principal: :chat_host)
      refute RateLimit.call(plug_conn(credential), opts).halted
      refute RateLimit.call(plug_conn(credential), opts).halted
    end
  end
end
