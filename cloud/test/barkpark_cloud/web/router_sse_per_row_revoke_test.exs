defmodule BarkparkCloud.Web.RouterSsePerRowRevokeTest do
  @moduledoc """
  Does revoking ONE row from the sessions panel end THAT device's live event
  stream? (cch-w53-bl)

  ## The residue cch-w53-s4 named and did not cover

  s4 taught the parked loop to recheck `user_has_live_session?/1` per heartbeat.
  That is a question about the USER, and on the per-row path its answer is YES by
  construction: the device that pressed Revoke is itself a live session, so the
  count never reaches zero. `router_sse_revoke_test.exs` is green and was green
  while a revoked device kept receiving its team's events — every one of its
  streaming users holds exactly ONE session, so a user-wide check and a per-device
  check are indistinguishable there. Any test with one session in the fixture is
  structurally incapable of seeing this defect. So every test below stands up
  TWO sessions: the streaming device and the acting device.

  ## The mechanism under test

  `user_tokens.session_token_id` binds an `"sse"` ticket to the `"session"` row
  that minted it (`Accounts.create_sse_ticket/2`), the binding survives the burn
  by riding out of `Accounts.consume_sse_ticket_binding/1`, and
  `Router.sse_loop/3` rechecks THAT row via `Accounts.session_token_live?/1`
  instead of the user-wide count. The bound is still ONE HEARTBEAT, not
  immediacy — the assertions below pin the bound, never instantaneity.

  Harness shape (a real `Bandit` on an ephemeral port + a raw `:gen_tcp` client)
  is `router_sse_revoke_test.exs`'s, for its reasons: `Plug.Test` cannot observe a
  parked chunked response at all, and a buffering client would launder the exact
  bytes under assertion.
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
        email: "sse-perrow-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  # A user with a team and TWO live sessions: `streaming` opens the event stream,
  # `acting` is the browser that presses Revoke. Two is the minimum fixture that
  # can tell a per-device check from a user-wide one.
  defp two_device_user do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    {:ok, streaming} = Accounts.create_user_session_token(user, user_agent: "StreamingDevice")
    {:ok, acting} = Accounts.create_user_session_token(user, user_agent: "ActingBrowser")

    %{user: user, team: team, streaming: streaming, acting: acting}
  end

  defp bound_ticket!(user, session_token) do
    {:ok, ticket} = Accounts.create_sse_ticket(user, session_token)
    ticket
  end

  defp revoke_row!(user, session_token) do
    id = Accounts.live_session_token_id(session_token)
    assert is_binary(id)
    assert {:ok, _} = Accounts.revoke_user_session(user, id)
    id
  end

  ## Harness

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

  defp open_socket(port) do
    {:ok, sock} =
      :gen_tcp.connect(@loopback, port, [:binary, active: false, packet: :raw], 5_000)

    on_exit(fn -> :gen_tcp.close(sock) end)
    sock
  end

  defp connect_with_ticket(port, ticket) do
    sock = open_socket(port)

    :ok =
      :gen_tcp.send(sock, [
        "GET /v1/events?ticket=",
        ticket,
        " HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n"
      ])

    sock
  end

  # The OTHER credential path: `Authorization: Bearer <session token>`, which
  # curl and the CLI use and which never writes a credential into a URL. It binds
  # too — from the presented token directly, with no ticket in the picture.
  defp connect_with_bearer(port, session_token) do
    sock = open_socket(port)

    :ok =
      :gen_tcp.send(sock, [
        "GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n",
        "Authorization: Bearer ",
        session_token,
        "\r\n\r\n"
      ])

    sock
  end

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

  defp await_connected(sock) do
    {head, _} = drain(sock, 2_000, ": connected")
    assert head =~ "HTTP/1.1 200 OK"
    assert head =~ ": connected"
    head
  end

  # The chunked terminator: a stream that ENDED sends it, a parked one never
  # does. Keep-alive means the socket may outlive the response, so this — not
  # `:closed` — is the evidence the loop returned.
  defp ended?({bytes, closed}), do: bytes =~ "0\r\n\r\n" or closed == :closed

  ## 1. The stream the panel promised to end

  describe "revoking one session row ends that device's stream" do
    test "a broadcast after the revoke is NOT delivered, though the acting session lives" do
      set_timings(25_000, 0)
      port = start_listener!()
      %{user: user, team: team, streaming: streaming} = two_device_user()

      sock = connect_with_ticket(port, bound_ticket!(user, streaming))
      await_connected(sock)

      revoke_row!(user, streaming)

      # THE FIXTURE'S OWN TRAP: the user-wide check the loop used before this
      # change still answers "live" here, because the acting browser is a live
      # session. FAIL-BEFORE ON MAIN: the `data:` frame arrives and the stream
      # stays parked.
      assert Accounts.user_has_live_session?(user)
      assert [%UserToken{user_agent: "ActingBrowser"}] = Accounts.list_user_sessions(user)

      :ok = Events.broadcast(team.id, "fleet", %{})

      {bytes, _} = result = drain(sock, 2_000, "0\r\n\r\n")

      refute bytes =~ "data:"
      refute bytes =~ "fleet"
      assert ended?(result)
    end

    test "a header-authenticated stream binds too, with no ticket in the picture" do
      set_timings(25_000, 0)
      port = start_listener!()
      %{user: user, team: team, streaming: streaming} = two_device_user()

      sock = connect_with_bearer(port, streaming)
      await_connected(sock)

      revoke_row!(user, streaming)
      assert Accounts.user_has_live_session?(user)

      :ok = Events.broadcast(team.id, "fleet", %{})

      {bytes, _} = result = drain(sock, 2_000, "0\r\n\r\n")

      refute bytes =~ "data:"
      assert ended?(result)
    end

    test "an IDLE bound stream dies on the heartbeat tick — the bound is one heartbeat" do
      # recheck_ms above the test's whole lifetime, so the event-path throttle
      # cannot be what ends this: only the heartbeat's forced recheck can.
      set_timings(150, 60_000)
      port = start_listener!()
      %{user: user, streaming: streaming} = two_device_user()

      sock = connect_with_ticket(port, bound_ticket!(user, streaming))
      await_connected(sock)

      # Prove the heartbeat really ticks first, so a stream that never started
      # cannot be mistaken for one that ended.
      {pings, _} = drain(sock, 2_000, ": ping")
      assert pings =~ ": ping"

      revoke_row!(user, streaming)

      assert ended?(drain(sock, 3_000, "0\r\n\r\n"))
    end
  end

  ## 2. The controls — the guard has to be able to LOSE

  describe "the binding is per device, not a blanket kill" do
    test "revoking the OTHER row leaves this stream delivering" do
      # The vacuous-green inversion. A recheck that answered "revoked" for any
      # revoke anywhere would pass every assertion above while breaking the live
      # dashboard for every user with two devices.
      set_timings(25_000, 0)
      port = start_listener!()
      %{user: user, team: team, streaming: streaming, acting: acting} = two_device_user()

      sock = connect_with_ticket(port, bound_ticket!(user, streaming))
      await_connected(sock)

      revoke_row!(user, acting)

      :ok = Events.broadcast(team.id, "fleet", %{})

      {bytes, _} = result = drain(sock, 1_000)

      assert bytes =~ ~s(data: {"type":"fleet")
      refute ended?(result)
    end

    test "an UNBOUND ticket keeps the user-wide behaviour — the fallback is alive" do
      # `create_sse_ticket/1` mints with `session_token_id: nil`, which is exactly
      # what every ticket row that predates the migration looks like. Such a
      # stream must still end on sign-out-everywhere; if this reds, the fallback
      # clause of `sse_principal_live?/1` is dead and a mid-deploy stream is
      # unrevocable.
      set_timings(25_000, 0)
      port = start_listener!()
      %{user: user, team: team} = two_device_user()

      {:ok, unbound} = Accounts.create_sse_ticket(user)
      assert [nil] = ticket_bindings(user)

      sock = connect_with_ticket(port, unbound)
      await_connected(sock)

      assert {:ok, 2} = Accounts.revoke_all_user_sessions(user)

      :ok = Events.broadcast(team.id, "fleet", %{})

      {bytes, _} = result = drain(sock, 2_000, "0\r\n\r\n")

      refute bytes =~ "data:"
      assert ended?(result)
    end
  end

  ## 3. The pre-minted ticket, per row

  describe "a ticket minted by a since-revoked session cannot open a stream" do
    test "the post-revoke connect is refused 401 over the wire" do
      set_timings(25_000, 0)
      port = start_listener!()
      %{user: user, streaming: streaming} = two_device_user()

      # Minted BEFORE the revoke; its whole 60s TTL is the window. Without the
      # per-row ticket sweep this ticket opens a FRESH authenticated stream for a
      # device that was just signed out — the per-row twin of the hole
      # `revoke_all_user_sessions/2` closes for sign-out-everywhere.
      ticket = bound_ticket!(user, streaming)
      revoke_row!(user, streaming)

      sock = connect_with_ticket(port, ticket)
      {bytes, _} = drain(sock, 2_000, "unauthorized")

      assert bytes =~ "HTTP/1.1 401"
      refute bytes =~ ": connected"
    end

    test "the sweep is scoped to the revoked row, not the user's other tickets" do
      %{user: user, streaming: streaming, acting: acting} = two_device_user()

      streaming_ticket = bound_ticket!(user, streaming)
      acting_ticket = bound_ticket!(user, acting)

      revoke_row!(user, streaming)

      # A user-wide "sse" sweep here would be charter D28's two-tab
      # mutual-eviction storm: revoking the phone would evict the laptop's
      # unredeemed ticket, which 401s, remints, and evicts the phone's.
      assert Accounts.consume_sse_ticket(streaming_ticket) == nil
      assert %{} = Accounts.consume_sse_ticket(acting_ticket)
    end
  end

  ## 4. The column, round-tripped

  test "the mint stamps session_token_id, and it survives to the redemption" do
    # The `cast/3` allowlist hazard the schema comments name: a dropped
    # `:session_token_id` writes NULL on every row with no warning anywhere, and
    # every behavioural test above would still pass through the user-wide
    # fallback in a ONE-session fixture. Read the column, and read it raw.
    %{user: user, streaming: streaming} = two_device_user()

    session_id = Accounts.live_session_token_id(streaming)
    ticket = bound_ticket!(user, streaming)

    assert [^session_id] = ticket_bindings(user)

    {:ok, %{rows: [[raw]]}} =
      Repo.query("SELECT session_token_id FROM user_tokens WHERE context = 'sse'", [])

    assert Ecto.UUID.cast!(raw) == session_id

    # The binding has to ride out of the REDEMPTION: the row is burnt in that
    # transaction and the reaper deletes burnt rows on the minute, so a later
    # lookup would be racing a sweeper with a spent plaintext.
    assert {%{id: uid}, ^session_id} = Accounts.consume_sse_ticket_binding(ticket)
    assert uid == user.id
  end

  test "single-device logout also sweeps the tickets that session minted" do
    %{user: user, streaming: streaming} = two_device_user()

    ticket = bound_ticket!(user, streaming)
    assert {:ok, _} = Accounts.revoke_user_session_token(streaming)

    assert Accounts.consume_sse_ticket(ticket) == nil
  end

  defp ticket_bindings(user) do
    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user.id and t.context == "sse",
        select: t.session_token_id
    )
  end
end
