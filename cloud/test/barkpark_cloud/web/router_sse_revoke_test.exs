defmodule BarkparkCloud.Web.RouterSseRevokeTest do
  @moduledoc """
  Does "sign out everywhere" actually end the LIVE EVENT STREAM? (cch-w53-s4)

  ## Why this test needs a real socket, and why the existing one cannot see it

  `accounts_test.exs`'s "revokes every live session" asserts
  `list_user_sessions(user) == []`. That is a claim about ROWS, it is green, and
  it was green while a signed-out device kept receiving its team's events at
  t+55s across two heartbeats. The row died; the CHANNEL did not. Any test that
  observes the rows is structurally incapable of seeing this defect — so this one
  observes the channel:

    * a REAL `Bandit` listener on an EPHEMERAL port (`port: 0`, then read the
      assigned port — hard-coding one makes two concurrent runs collide), because
    * `Plug.Test` CANNOT observe a parked chunked response at all: it runs
      `Router.call/2` in the test process, which would simply block in the SSE
      receive loop, and
    * a raw `:gen_tcp` client, because the assertion is about bytes that do or do
      not arrive after the revoke — a client library that buffers or reconnects
      would launder exactly the evidence.

  ## The two holes pinned here

    1. THE PARKED LOOP. `require_user_sse/1` authenticates once at connect; the
       loop then held no credential and re-read nothing, so revocation reached it
       never. Fixed by remembering `user_id` and rechecking live-session
       existence, which bounds revocation at one heartbeat — NOT immediacy, and
       the tests below assert the bound, not a promise of instantaneity.

    2. THE PRE-MINTED TICKET. `revoke_all_user_sessions/2` was scoped
       `context == "session"`, so a 60s `"sse"` ticket minted a second before
       sign-out-everywhere still opened a FRESH authenticated stream after it.

  Both are proven fail-before on unmodified main: (1) the `data:` frame arrives,
  (2) the post-revoke connect answers `200` + `: connected`.

  Timings come from `:sse_heartbeat_ms` / `:sse_recheck_ms`, which exist ONLY so
  these assertions do not each cost 25 real seconds. Production reads the
  defaults; `the router keeps its 25s production defaults` below pins that.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Events
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @password "correct-horse-battery"
  @loopback {127, 0, 0, 1}

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "sse-revoke-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # A user with a team AND one live session — the only principal that can hold an
  # open stream. Teamless users 422 at /v1/events and never park.
  defp streaming_user do
    {user, team} = user_with_team()
    {:ok, session} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
    {user, team, session}
  end

  defp ticket!(user) do
    {:ok, ticket} = Accounts.create_sse_ticket(user)
    ticket
  end

  ## Harness — a real listener + a raw client

  # Start Bandit on an ephemeral port and hand back the port the OS assigned.
  defp start_listener! do
    pid =
      start_supervised!(
        {Bandit, plug: Router, scheme: :http, port: 0, ip: @loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp set_timings(heartbeat_ms, recheck_ms) do
    Application.put_env(:barkpark_cloud, :sse_heartbeat_ms, heartbeat_ms)
    Application.put_env(:barkpark_cloud, :sse_recheck_ms, recheck_ms)

    on_exit(fn ->
      Application.delete_env(:barkpark_cloud, :sse_heartbeat_ms)
      Application.delete_env(:barkpark_cloud, :sse_recheck_ms)
    end)
  end

  defp connect_stream(port, ticket) do
    {:ok, sock} =
      :gen_tcp.connect(@loopback, port, [:binary, active: false, packet: :raw], 5_000)

    :ok =
      :gen_tcp.send(sock, [
        "GET /v1/events?ticket=",
        ticket,
        " HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n"
      ])

    on_exit(fn -> :gen_tcp.close(sock) end)
    sock
  end

  # Read whatever the server sends within `ms`, then stop. Returns the raw bytes
  # (chunked framing and all) plus whether the peer closed.
  #
  # `until` is a fragment to stop EARLY on, and it is only ever an optimisation:
  # a test asserting that something did NOT arrive passes `nil` and always waits
  # the full window, because absence cannot be short-circuited.
  defp drain(sock, ms, until \\ nil) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_drain(sock, deadline, until, "")
  end

  defp do_drain(sock, deadline, until, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      is_binary(until) and acc =~ until ->
        {acc, :open}

      left <= 0 ->
        {acc, :open}

      true ->
        case :gen_tcp.recv(sock, 0, left) do
          {:ok, bytes} -> do_drain(sock, deadline, until, acc <> bytes)
          {:error, :timeout} -> {acc, :open}
          {:error, :closed} -> {acc, :closed}
          {:error, _other} -> {acc, :closed}
        end
    end
  end

  # Read until the opening SSE comment lands, so a test that then broadcasts
  # knows the request process is really parked and subscribed.
  defp await_connected(sock) do
    {head, _} = drain(sock, 2_000, ": connected")
    assert head =~ "HTTP/1.1 200 OK"
    assert head =~ ": connected"
    head
  end

  # The chunked-encoding terminator. A stream that ENDED sends it; a stream still
  # parked never does. Keep-alive means the socket itself may stay open after it,
  # so this — not `:closed` — is the evidence that the loop returned.
  defp ended?({bytes, closed}), do: bytes =~ "0\r\n\r\n" or closed == :closed

  ## 1. The parked loop

  describe "an open stream ends when the user is signed out everywhere" do
    test "a broadcast after sign-out-everywhere is NOT delivered and the stream ends" do
      # recheck_ms: 0 makes the event path recheck on the spot, so the assertion
      # costs milliseconds instead of a heartbeat. The MECHANISM under test is
      # the recheck itself; the heartbeat test below pins the timing bound.
      set_timings(25_000, 0)
      port = start_listener!()
      {user, team, _session} = streaming_user()

      sock = connect_stream(port, ticket!(user))
      await_connected(sock)

      # FAIL-BEFORE ON MAIN: the loop holds no credential, so this revoke is
      # invisible to it and the frame below arrives verbatim.
      assert {:ok, 1} = Accounts.revoke_all_user_sessions(user)
      assert Accounts.list_user_sessions(user) == []

      :ok = Events.broadcast(team.id, "fleet", %{})

      {bytes, _} = result = drain(sock, 2_000, "0\r\n\r\n")

      refute bytes =~ "data:"
      refute bytes =~ "fleet"
      assert ended?(result)
    end

    test "the stream is UNTOUCHED while the session lives — the guard can lose" do
      # The vacuous-green inversion: a recheck that always answered "revoked"
      # would pass every assertion above while breaking the live dashboard for
      # everyone. This is the control.
      set_timings(25_000, 0)
      port = start_listener!()
      {user, team, _session} = streaming_user()

      sock = connect_stream(port, ticket!(user))
      await_connected(sock)

      :ok = Events.broadcast(team.id, "fleet", %{})

      {bytes, _} = result = drain(sock, 1_000)

      assert bytes =~ ~s(data: {"type":"fleet")
      refute ended?(result)
    end

    test "an IDLE stream dies on the heartbeat tick — the bound is one heartbeat" do
      # recheck_ms is set ABOVE the test's whole lifetime, so the event-path
      # throttle cannot be what ends this stream: only the heartbeat's forced
      # recheck can. That is the guarantee the ~25s bound rests on.
      set_timings(150, 60_000)
      port = start_listener!()
      {user, _team, _session} = streaming_user()

      sock = connect_stream(port, ticket!(user))
      await_connected(sock)

      # Prove the heartbeat is really ticking before we revoke, so a stream that
      # merely never started cannot be mistaken for one that ended.
      {pings, _} = drain(sock, 2_000, ": ping")
      assert pings =~ ": ping"

      assert {:ok, 1} = Accounts.revoke_all_user_sessions(user)

      result = drain(sock, 3_000, "0\r\n\r\n")
      assert ended?(result)
    end
  end

  ## 2. The pre-minted ticket

  describe "a ticket minted before sign-out-everywhere cannot open a stream after it" do
    test "the post-revoke connect is refused 401 over the wire" do
      set_timings(25_000, 0)
      port = start_listener!()
      {user, _team, _session} = streaming_user()

      # Minted BEFORE the revoke — the whole 60s TTL is the window.
      ticket = ticket!(user)
      assert {:ok, 1} = Accounts.revoke_all_user_sessions(user)

      sock = connect_stream(port, ticket)
      {bytes, _} = drain(sock, 2_000, "unauthorized")

      # FAIL-BEFORE ON MAIN: `200 OK` + `: connected`.
      assert bytes =~ "HTTP/1.1 401"
      refute bytes =~ ": connected"
    end

    test "the ticket row itself is burned, not merely unusable by luck" do
      {user, _team, _session} = streaming_user()
      ticket = ticket!(user)

      assert {:ok, 1} = Accounts.revoke_all_user_sessions(user)

      assert Accounts.consume_sse_ticket(ticket) == nil
      assert [%UserToken{context: "sse", revoked_at: %DateTime{}}] = sse_rows(user)
    end
  end

  defp sse_rows(user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "sse")
  end

  ## 3. What the escape hatch must not become

  test "the router keeps its 25s production defaults" do
    # The timing knobs exist for the tests above. If a default ever moves, the
    # heartbeat bound quoted in the loop's comment (and in the PR body) silently
    # stops being true, so pin the DECLARATION.
    src = File.read!(Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__))

    assert src =~ ~r/:sse_heartbeat_ms,\s*25_000/
    assert src =~ ~r/:sse_recheck_ms,\s*25_000/
  end
end
