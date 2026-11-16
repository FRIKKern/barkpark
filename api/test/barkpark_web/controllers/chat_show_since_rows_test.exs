defmodule BarkparkWeb.ChatShowSinceRowsTest do
  @moduledoc """
  `GET /v1/chat/sessions/:id?since=<seq>` loads only the message rows it
  returns (task-cb021c3fefa4bef4).

  The show read used to load EVERY message of the session and drop the old ones
  in memory. BarkBot asks for the session alone with a past-the-end
  `?since=9223372036854775807` (up to 50 reads per page load), so each of those
  read the whole transcript to answer `messages: []`. The default read (no
  `since`) is unchanged and still returns every message; the body of a `since`
  read is unchanged too. The scope is unchanged: a foreign session is still the
  same 404.

  Rows are counted from the `[:barkpark, :repo, :query]` result in the test
  process — the controller runs there under `ConnCase`, and a pid filter keeps
  the application's own sweepers (another process) out of the count.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Message
  alias BarkparkWeb.ChatController

  @dataset "production"
  @past_the_end "9223372036854775807"

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    admin = "chat-since-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "chat-since-admin", @dataset, ["read", "write", "admin"])

    %{admin: admin}
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp session_with!(n, scope \\ :global) do
    {:ok, s} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"}, scope)
    now = DateTime.utc_now()

    for seq <- 1..n//1 do
      %{
        session_id: s.id,
        seq: seq,
        role: "user",
        source_markdown: "message #{seq}",
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    end
    |> Enum.chunk_every(200)
    |> Enum.each(&Repo.insert_all(Message, &1))

    s.id
  end

  # {result, chat_messages rows loaded by statements this process issued}
  defp message_rows(fun) do
    me = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _cfg ->
        with true <- self() == me,
             "chat_messages" <- meta[:source],
             {:ok, %{num_rows: rows}} <- meta[:result] do
          send(me, {handler, rows})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, drain(handler, 0)}
  end

  defp drain(handler, acc) do
    receive do
      {^handler, rows} -> drain(handler, acc + rows)
    after
      0 -> acc
    end
  end

  defp show(raw, sid, query) do
    message_rows(fn -> as(raw) |> get("/v1/chat/sessions/#{sid}#{query}") end)
  end

  test "a past-the-end since loads no message rows, for a 5- and a 500-message session alike",
       %{admin: admin} do
    for n <- [5, 500] do
      sid = session_with!(n)
      {conn, rows} = show(admin, sid, "?since=#{@past_the_end}")
      body = json_response(conn, 200)

      assert body["id"] == sid
      assert body["messages"] == []
      assert rows == 0, "?since=#{@past_the_end} loaded #{rows} message rows for #{n} messages"
    end
  end

  test "a tail read loads only the tail; the default read still loads and returns every message",
       %{admin: admin} do
    sid = session_with!(500)

    {conn, rows} = show(admin, sid, "?since=498")
    assert Enum.map(json_response(conn, 200)["messages"], & &1["seq"]) == [499, 500]
    assert rows == 2, "?since=498 loaded #{rows} message rows to return 2"

    {conn, rows} = show(admin, sid, "")
    assert length(json_response(conn, 200)["messages"]) == 500
    assert rows == 500
  end

  test "the event stream's replay loads only rows past Last-Event-ID, and a value past bigint is no replay" do
    sid = session_with!(500)

    {frames, rows} = message_rows(fn -> ChatController.replay_events(sid, 497, :global) end)
    assert length(frames) == 3
    assert hd(frames) =~ "id: 498\n"
    assert rows == 3

    # last_event_id/1 parses with no upper bound; such a value must not reach the query.
    assert ChatController.replay_events(sid, 99_999_999_999_999_999_999, :global) == []
  end

  # chat_messages.seq is a 32-bit `integer`; `?since=` takes up to the bigint
  # max and Last-Event-ID has no bound. A since past the int4 max must answer
  # [] as the old in-memory filter did, never reach the query (Postgrex cannot
  # encode it for an int4 column: a 500 on the read, a dead stream on replay).
  @past_int4 [2_147_483_647, 2_147_483_648, 1_099_511_627_776, 9_223_372_036_854_775_806]

  test "a since past the int4 seq column answers [] on the read and the replay",
       %{admin: admin} do
    sid = session_with!(5)

    for since <- @past_int4 do
      {conn, rows} = show(admin, sid, "?since=#{since}")
      body = json_response(conn, 200)
      assert body["messages"] == [], "?since=#{since}"
      assert rows == 0

      assert ChatController.replay_events(sid, since, :global) == [], "replay since=#{since}"
    end
  end

  test "seq is still a 32-bit integer column (MessagesSince's @seq_max is its max)" do
    %{rows: [[type]]} =
      Repo.query!(
        "SELECT data_type FROM information_schema.columns WHERE table_name = 'chat_messages' AND column_name = 'seq'"
      )

    assert type == "integer",
           "chat_messages.seq is now #{type}: raise @seq_max in Barkpark.StudioChat.MessagesSince to its max"
  end

  describe "tenancy is unchanged" do
    setup do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      conn_a = "chat-since-conn-a-#{System.unique_integer([:positive])}"
      conn_b = "chat-since-conn-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(conn_a, "conn-a", @dataset, ["read", "chat"], ws_a.id)
      {:ok, _} = Auth.create_token(conn_b, "conn-b", @dataset, ["read", "chat"], ws_b.id)
      %{ws_a: ws_a, conn_a: conn_a, conn_b: conn_b}
    end

    test "another workspace's session is the same 404 with since; its owner reads the tail",
         %{ws_a: ws_a, conn_a: conn_a, conn_b: conn_b} do
      sid = session_with!(5, {:workspace, ws_a.id})

      for q <- ["", "?since=0", "?since=3", "?since=#{@past_the_end}"] do
        body = as(conn_b) |> get("/v1/chat/sessions/#{sid}#{q}") |> json_response(404)
        assert body["error"]["code"] == "not_found", "#{q} leaked a foreign session"
      end

      {conn, rows} = show(conn_a, sid, "?since=3")
      assert Enum.map(json_response(conn, 200)["messages"], & &1["seq"]) == [4, 5]
      assert rows == 2

      # the store-level gate: a workspace that cannot see the session reads nothing
      assert ChatController.replay_events(sid, 0, ws_a.id) |> length() == 5
      other = create_workspace!()
      assert ChatController.replay_events(sid, 0, other.id) == []
    end
  end
end
