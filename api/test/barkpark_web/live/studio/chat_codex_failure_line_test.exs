defmodule BarkparkWeb.Studio.ChatCodexFailureLineTest do
  @moduledoc """
  The transcript line for a codex runtime failure event (task-4644f29b5663bc5f).

  A codex `error` that says `willRetry: true` is not the end of the turn: since
  #26770 the Recorder keeps the turn open and its reply follows. ChatLive still
  wrote "The codex turn ended with an error" for it, which was false. Both
  shapes `Runtime.Event.retrying_error?/1` reads are driven: the managed
  adapter's (the flag under `native["params"]`) and a registered host's (the
  notification's params as `error`).
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat.Runtime.{Codex.Protocol, Event}

  @admin_token "chat-codex-failure-admin-token"

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "chat codex failure admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

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

    conn = init_test_session(conn, %{"api_token" => @admin_token})
    {:ok, view, _html} = live(conn, "/studio/chat")
    %{view: view}
  end

  test "a managed codex error that will retry says the turn is retrying", %{view: view} do
    html = line(view, managed_error(true))

    assert html =~ "The codex turn hit an error and is retrying"
    assert html =~ "Reconnecting... 1/5"
    refute html =~ "ended with an error"
  end

  test "a registered host's codex error that will retry says the turn is retrying",
       %{view: view} do
    host_error = %Event{
      kind: :error,
      error: %{"error" => %{"message" => "Reconnecting... 1/5"}, "willRetry" => true}
    }

    html = line(view, host_error)
    assert html =~ "The codex turn hit an error and is retrying — Reconnecting... 1/5."
    refute html =~ "ended with an error"
  end

  # task-1ea3bfbe6d47e2bb: a host's reason sits under error["error"].
  test "a registered host's codex error that will not retry names its reason", %{view: view} do
    host_error = %Event{
      kind: :error,
      error: %{"error" => %{"message" => "boom"}, "willRetry" => false}
    }

    assert line(view, host_error) =~ "The codex turn ended with an error — boom."
  end

  test "a codex error that will not retry still says the turn ended", %{view: view} do
    html = line(view, managed_error(false))

    assert html =~ "The codex turn ended with an error — Reconnecting... 1/5."
    refute html =~ "retrying"
  end

  # task-455b5309ba76bb14: a host's reason is not scrubbed upstream.
  test "a 10,000-character host reason is cut to 2,000 characters" do
    long = String.duplicate("x", 10_000)
    event = %Event{kind: :error, error: %{"error" => %{"message" => long}, "willRetry" => false}}

    line = BarkparkWeb.Studio.CodexFailureLine.line(event)
    assert line == "The codex turn ended with an error — " <> String.duplicate("x", 2_000) <> "."
    assert byte_size(line) <= 2_100
  end

  # task-ed920e5459df0ab5: one letter with 200,000 combining marks is one
  # grapheme, so the 2,000-grapheme cut alone kept all 400 KB of it.
  test "a host reason of one letter and 200,000 combining marks is cut to about 8 KB" do
    huge = "x" <> String.duplicate("́", 200_000)
    event = %Event{kind: :error, error: %{"error" => %{"message" => huge}, "willRetry" => false}}

    line = BarkparkWeb.Studio.CodexFailureLine.line(event)
    assert byte_size(line) <= 8_100
    assert String.valid?(line)
    assert String.starts_with?(line, "The codex turn ended with an error — x́")
    assert String.ends_with?(line, ".")
  end

  test "three long pieces of a host reason together stay under about 8 KB" do
    dogs = String.duplicate("🐕", 2_000)
    reason = %{"message" => "m" <> dogs, "detail" => "d" <> dogs, "code" => "c" <> dogs}
    event = %Event{kind: :error, error: %{"error" => reason, "willRetry" => false}}

    line = BarkparkWeb.Studio.CodexFailureLine.line(event)
    assert byte_size(line) <= 8_100
    assert String.valid?(line)
    assert String.starts_with?(line, "The codex turn ended with an error — m🐕")
  end

  test "each piece is cut on its own, so a long message does not push the detail out" do
    reason = %{"message" => String.duplicate("x", 10_000), "detail" => "why"}
    event = %Event{kind: :error, error: %{"error" => reason, "willRetry" => false}}

    assert BarkparkWeb.Studio.CodexFailureLine.line(event) ==
             "The codex turn ended with an error — " <> String.duplicate("x", 2_000) <> " — why."
  end

  test "the other failure kinds keep their lines", %{view: view} do
    assert line(view, %Event{kind: :process_failed, error: %{"code" => "process_exit"}}) =~
             "The codex process exited unexpectedly — process_exit."

    assert line(view, %Event{kind: :protocol_error, error: %{"detail" => "bad"}}) =~
             "The codex stream hit a protocol error — bad."
  end

  defp managed_error(will_retry) do
    Protocol.normalize(
      %{
        "method" => "error",
        "params" => %{
          "error" => %{"message" => "Reconnecting... 1/5"},
          "willRetry" => will_retry
        }
      },
      %{session_id: "s", thread_id: "th-1", turn_id: "t-1", sequence: 1}
    )
  end

  defp line(view, event) do
    send(view.pid, {:studio_chat_runtime_event, event})
    render(view)
  end
end
