defmodule Barkpark.StudioChat.TitlesNulTest do
  @moduledoc """
  A generated chat title holding U+0000 (task-44045d0606044e13).

  The named failure mode: Postgres refuses U+0000 in a text parameter
  (22021). `maybe_set_ai_title/2` wrote the title as given, the raise was
  swallowed by `kick_title/2`'s rescue, and the session silently kept its
  default title. `kick_title/2` now hands the store U+FFFD in its place, as
  the chat-host event path does (`ChatHosts.EventText.replace_nul/1`), so the
  title lands.

  These run the real store against a real session row; only the title CLI is
  faked, printing what `claude -p --output-format json` would.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Session, Titles}

  defmodule FakeCli do
    def run(_binary, _args),
      do: Application.get_env(:barkpark, :test_title_nul_cli, {:error, :unset})
  end

  defmodule NoApi do
    def post(_url, _body, _headers), do: {:error, :no_api_in_test}
  end

  defmodule HostAllowed do
    def session_may_host_exec?(_session_id), do: true
  end

  setup do
    Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NoApi)
    Application.put_env(:barkpark, :studio_chat_title_host_rule, HostAllowed)

    on_exit(fn ->
      for key <- [
            :studio_chat_title_cli,
            :studio_chat_title_http_adapter,
            :studio_chat_title_host_rule,
            :test_title_nul_cli
          ],
          do: Application.delete_env(:barkpark, key)
    end)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, Barkpark.StudioChat.Recorder.activity_topic())
    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
    %{sid: session.id, default_title: session.title}
  end

  test "a generated title holding U+0000 is stored with U+FFFD in its place", %{sid: sid} do
    # The CLI's JSON carries the escape; decoding it yields a real U+0000.
    Application.put_env(:barkpark, :test_title_nul_cli, {:ok, ~S({"title":"a\u0000b"})})

    {:ok, _pid} = Titles.kick_title(sid, "name this chat")

    assert_receive {:chat_title, ^sid, "a�b"}, 5_000
    assert %Session{title: "a�b", title_source: "ai"} = StudioChat.get_session(sid)
  end

  test "a clean generated title is stored exactly as before", %{sid: sid} do
    Application.put_env(
      :barkpark,
      :test_title_nul_cli,
      {:ok, ~S({"title":"Refactor the auth layer"})}
    )

    {:ok, _pid} = Titles.kick_title(sid, "name this chat")

    assert_receive {:chat_title, ^sid, "Refactor the auth layer"}, 5_000

    assert %Session{title: "Refactor the auth layer", title_source: "ai"} =
             StudioChat.get_session(sid)
  end
end
