defmodule Barkpark.StudioChat.TitlesTest do
  # async: false — the seams are wired through Application env, which is global.
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Titles

  # ── Fakes: no network, no real `claude`, no real store ───────────────────

  defmodule FakeAdapter do
    # Reads its canned response from Application env so each test can steer it.
    def post(_url, _body, _headers),
      do: Application.get_env(:barkpark, :test_title_api, {:error, :unset})
  end

  defmodule FakeCli do
    def run(_binary, _args), do: Application.get_env(:barkpark, :test_title_cli, {:error, :unset})
  end

  defmodule SlowCli do
    # Outlives the (test-shortened) timeout, exercising the brutal-kill path.
    def run(_binary, _args) do
      Process.sleep(1_000)
      {:ok, ~s({"title":"too slow"})}
    end
  end

  defmodule FakeStore do
    @moduledoc "Mirrors the real store's clobber-guard contract, backed by an Agent."
    use Agent

    def start_link(initial), do: Agent.start_link(fn -> initial end, name: __MODULE__)

    # {:ok, title} when the write lands; refused when a human already named it.
    def maybe_set_ai_title(_session_id, title) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.source do
          "human" -> {{:error, :human_renamed}, state}
          _ -> {{:ok, title}, %{state | title: title, source: "ai"}}
        end
      end)
    end

    def current, do: Agent.get(__MODULE__, & &1.title)
  end

  setup do
    on_exit(fn ->
      for k <- [
            :studio_chat_title_http_adapter,
            :studio_chat_title_cli,
            :studio_chat_store,
            :studio_chat_title_timeout_ms,
            :anthropic_api_key,
            :test_title_api,
            :test_title_cli
          ] do
        Application.delete_env(:barkpark, k)
      end
    end)

    :ok
  end

  # ── Pure builders ────────────────────────────────────────────────────────

  describe "api_request/1" do
    test "targets a haiku model with structured {title} output at low effort" do
      req = Titles.api_request("Fix the flaky login test")

      assert req["model"] =~ "haiku"
      assert req["max_tokens"] == 64
      assert req["output_config"]["effort"] == "low"
      assert req["output_config"]["format"]["type"] == "json_schema"

      assert req["output_config"]["format"]["schema"]["properties"] == %{
               "title" => %{"type" => "string"}
             }

      assert req["output_config"]["format"]["schema"]["required"] == ["title"]
      assert is_binary(req["system"])
      [%{"role" => "user", "content" => content}] = req["messages"]
      assert content =~ "Fix the flaky login test"
    end
  end

  describe "cli_args/1" do
    test "assembles the exact one-shot argv (persistence off, json, single turn)" do
      args = Titles.cli_args("Add dark mode toggle")

      assert args == [
               "-p",
               Enum.at(args, 1),
               "--model",
               "haiku",
               "--output-format",
               "json",
               "--max-turns",
               "1",
               "--no-session-persistence",
               "--strict-mcp-config",
               "--system-prompt",
               Enum.at(args, 11)
             ]

      # The prompt carries the message; the system prompt is a real string.
      assert Enum.at(args, 1) =~ "Add dark mode toggle"
      assert is_binary(Enum.at(args, 11)) and Enum.at(args, 11) != ""
    end

    test "mandatory --no-session-persistence is present and no bare --tools" do
      args = Titles.cli_args("anything")
      assert "--no-session-persistence" in args
      refute "--tools" in args
    end
  end

  describe "parse_title/1" do
    test "strips a ```json fence and decodes the title" do
      raw = "```json\n{\"title\":\"Refactor the auth layer\"}\n```"
      assert Titles.parse_title(raw) == {:ok, "Refactor the auth layer"}
    end

    test "tolerates a rambling preamble around the fence" do
      raw =
        "Sure! Here is your title:\n```json\n{\"title\":\"Ship the parser\"}\n```\nHope that helps."

      assert Titles.parse_title(raw) == {:ok, "Ship the parser"}
    end

    test "unwraps the CLI --output-format json envelope" do
      raw = ~s({"type":"result","result":"```json\\n{\\"title\\":\\"Nested title\\"}\\n```"})
      assert Titles.parse_title(raw) == {:ok, "Nested title"}
    end

    test "accepts bare JSON with no fence" do
      assert Titles.parse_title(~s({"title":"Bare title"})) == {:ok, "Bare title"}
    end

    test "caps the title at 50 characters" do
      long = String.duplicate("a", 80)
      {:ok, title} = Titles.parse_title(~s({"title":"#{long}"}))
      assert String.length(title) == 50
    end

    test "errors on empty, missing, or non-JSON input" do
      assert {:error, _} = Titles.parse_title(~s({"title":""}))
      assert {:error, _} = Titles.parse_title(~s({"nope":"x"}))
      assert {:error, _} = Titles.parse_title("not json at all")
      assert {:error, _} = Titles.parse_title("")
    end
  end

  describe "derived_title/1" do
    test "takes the first line, capped at 50 chars" do
      assert Titles.derived_title("Fix the bug\nmore detail here") == "Fix the bug"

      long = String.duplicate("z", 80)
      assert String.length(Titles.derived_title(long)) == 50
    end

    test "falls back to a default for empty or non-binary input" do
      assert Titles.derived_title("   ") == "New chat"
      assert Titles.derived_title(nil) == "New chat"
    end
  end

  # ── Layered fallback (generate/1) ────────────────────────────────────────

  describe "generate/1 layering" do
    test "key present + healthy API uses the API title" do
      Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
      Application.put_env(:barkpark, :studio_chat_title_http_adapter, FakeAdapter)

      Application.put_env(
        :barkpark,
        :test_title_api,
        {:ok, 200, %{"content" => [%{"type" => "text", "text" => ~s({"title":"API title"})}]}}
      )

      assert Titles.generate("summarize me") == "API title"
    end

    test "API failure falls through to the CLI title" do
      Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
      Application.put_env(:barkpark, :studio_chat_title_http_adapter, FakeAdapter)
      Application.put_env(:barkpark, :test_title_api, {:error, :boom})
      Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
      Application.put_env(:barkpark, :test_title_cli, {:ok, ~s({"title":"CLI title"})})

      assert Titles.generate("summarize me") == "CLI title"
    end

    test "no key skips the API and uses the CLI" do
      Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
      Application.put_env(:barkpark, :test_title_cli, {:ok, ~s({"title":"CLI only"})})

      assert Titles.generate("summarize me") == "CLI only"
    end

    test "CLI empty stdout falls to the derived title" do
      Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
      Application.put_env(:barkpark, :test_title_cli, {:ok, ""})

      assert Titles.generate("Derive from me\nrest") == "Derive from me"
    end

    test "CLI non-JSON stdout falls to the derived title" do
      Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
      Application.put_env(:barkpark, :test_title_cli, {:ok, "claude: command not found"})

      assert Titles.generate("Derive again") == "Derive again"
    end

    test "CLI timeout is brutal-killed and falls to the derived title" do
      Application.put_env(:barkpark, :studio_chat_title_cli, SlowCli)
      Application.put_env(:barkpark, :studio_chat_title_timeout_ms, 50)

      assert Titles.generate("Timed out\ndetail") == "Timed out"
    end

    test "everything failing still yields a non-empty derived title" do
      Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
      Application.put_env(:barkpark, :test_title_cli, {:error, :binary_not_found})

      assert Titles.generate("Last resort title") == "Last resort title"
    end
  end

  # ── Fire-and-forget kick + clobber guard ─────────────────────────────────

  describe "kick_title/2" do
    setup do
      # Deterministic: no key, CLI returns a known title. The accepted-write
      # notification is a PubSub broadcast on the activity topic (charter D69h)
      # — subscribe like the chat LiveView does at mount.
      Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
      Application.put_env(:barkpark, :test_title_cli, {:ok, ~s({"title":"Generated title"})})
      Application.put_env(:barkpark, :studio_chat_store, FakeStore)

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Barkpark.StudioChat.Recorder.activity_topic()
      )

      :ok
    end

    test "runs under the TaskSupervisor and broadcasts the title on the activity topic" do
      start_supervised!({FakeStore, %{title: "New chat", source: "default"}})

      {:ok, pid} = Titles.kick_title("sess-1", "make a title")
      assert is_pid(pid)

      assert_receive {:chat_title, "sess-1", "Generated title"}, 2_000
      assert FakeStore.current() == "Generated title"
    end

    test "the /3 compat head delivers via the broadcast ONLY — no parallel raw send (D69h)" do
      start_supervised!({FakeStore, %{title: "New chat", source: "default"}})

      # self() is both the (ignored) notify_pid AND an activity-topic
      # subscriber: exactly ONE {:chat_title} may arrive. A reintroduced raw
      # send would double-deliver and fail the refute below.
      {:ok, _pid} = Titles.kick_title("sess-compat", "make a title", self())

      assert_receive {:chat_title, "sess-compat", "Generated title"}, 2_000
      refute_receive {:chat_title, "sess-compat", _}, 300
    end

    test "clobber guard: a human rename before the async title is never overwritten" do
      # The human already named this session — store refuses the AI write.
      start_supervised!({FakeStore, %{title: "My hand-named chat", source: "human"}})

      {:ok, _pid} = Titles.kick_title("sess-2", "make a title")

      refute_receive {:chat_title, "sess-2", _}, 500
      assert FakeStore.current() == "My hand-named chat"
    end

    test "a store crash never leaks — no broadcast, no raise into the caller" do
      # No FakeStore process started → the Agent-name call raises inside the
      # supervised task; kick_title swallows it.
      {:ok, _pid} = Titles.kick_title("sess-3", "make a title")
      refute_receive {:chat_title, "sess-3", _}, 300
    end

    test "the canonical store shape {:ok, %Session{}} counts as an accepted write" do
      # Barkpark.StudioChat.maybe_set_ai_title/2 returns {:ok, %Session{}} —
      # a struct, not a bare title. The notify branch must recognise it.
      defmodule CanonicalStore do
        def maybe_set_ai_title(_session_id, title), do: {:ok, %{title: title <> "!"}}
      end

      Application.put_env(:barkpark, :studio_chat_store, CanonicalStore)

      {:ok, _pid} = Titles.kick_title("sess-4", "make a title")
      assert_receive {:chat_title, "sess-4", "Generated title!"}, 2_000
    end
  end
end
