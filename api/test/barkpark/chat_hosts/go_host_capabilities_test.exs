defmodule Barkpark.ChatHosts.GoHostCapabilitiesTest do
  @moduledoc """
  The shipped host binary's OWN capabilities shape must pass enrollment and
  heartbeat (task-c02eefeb0ed7381c).

  `cmd/barkpark-chat-host/main.go` `capabilities()` sends three top-level keys —
  `protocol_version`, `chat_runtime` (`{"protocol": "bidirectional-v2"}`) and
  `providers` — while `RegisteredHost.safe_capabilities?/1` admitted exactly
  two. Every real `barkpark-chat-host enroll` therefore failed the changeset,
  and the controller answered 401, which the Go client prints as "chat host
  credential revoked". The existing readiness tests passed because they built
  the capabilities map by hand, without `chat_runtime`.

  The literal lives in `test/support/fixtures/chat_host_go_capabilities.json`.
  The Go half, `TestCapabilitiesShapeMatchesServerFixture` in
  `cmd/barkpark-chat-host/capabilities_shape_test.go`, fails when `capabilities()` emits a
  key or type the fixture lacks. Change the two together.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Tenancy

  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)

  defp go_capabilities, do: @fixture |> File.read!() |> Jason.decode!()

  defp issue do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "ghc-#{suffix}", name: "GHC #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "go-host-#{suffix}",
        approved_roots: [System.tmp_dir!()]
      })

    issued
  end

  test "the fixture carries every key the Go binary can emit (guards the guard)" do
    caps = go_capabilities()
    assert Map.keys(caps) |> Enum.sort() == ~w(chat_runtime protocol_version providers)
    assert caps["chat_runtime"] == %{"protocol" => "bidirectional-v2"}

    for {_name, meta} <- caps["providers"] do
      assert Map.keys(meta) |> Enum.sort() ==
               ~w(auth_ready installed operations task_hands version)
    end
  end

  test "enroll/2 accepts the Go binary's capabilities and stores them" do
    issued = issue()

    assert {:ok, %{credential: credential}} =
             ChatHosts.enroll(issued.enrollment_token, %{
               "protocol_version" => 1,
               "capabilities" => go_capabilities()
             })

    assert is_binary(credential)
    stored = Repo.get!(RegisteredHost, issued.host.id)
    assert stored.capabilities == go_capabilities()
  end

  test "heartbeat/2 accepts the Go binary's capabilities" do
    issued = issue()
    {:ok, _} = ChatHosts.enroll(issued.enrollment_token, %{})
    host = Repo.get!(RegisteredHost, issued.host.id)

    assert {:ok, _} =
             ChatHosts.heartbeat(host, %{
               "protocol_version" => 1,
               "capabilities" => go_capabilities()
             })

    assert Repo.get!(RegisteredHost, host.id).capabilities["chat_runtime"] ==
             %{"protocol" => "bidirectional-v2"}
  end

  # The shape the Go host emits once it fetches pictures and files (Papers
  # chat-host-attachments-plan T6 and chat-host-file-attachments-plan T6):
  # today's map with `providers.claude.attachments` (four picture types, then
  # text/plain and application/pdf) added, and codex unchanged. The server must
  # admit it before any binary sends it, or that host's heartbeats are refused
  # and it goes offline. When T6 ships, this literal becomes the main fixture.
  describe "the Go binary's attachments shape (T6)" do
    @attachments_fixture Path.expand(
                           "../../support/fixtures/chat_host_go_capabilities_attachments.json",
                           __DIR__
                         )

    defp attachments_capabilities, do: @attachments_fixture |> File.read!() |> Jason.decode!()

    test "it is today's fixture plus providers.claude.attachments and nothing else" do
      caps = attachments_capabilities()
      {types, claude} = Map.pop(caps["providers"]["claude"], "attachments")

      assert types ==
               ~w(image/png image/jpeg image/gif image/webp text/plain application/pdf)

      assert put_in(caps, ["providers", "claude"], claude) == go_capabilities()
    end

    test "enroll/2 and heartbeat/2 accept it and store the list" do
      issued = issue()

      assert {:ok, %{credential: credential}} =
               ChatHosts.enroll(issued.enrollment_token, %{
                 "protocol_version" => 1,
                 "capabilities" => attachments_capabilities()
               })

      {:ok, host} = ChatHosts.authenticate(credential)

      assert {:ok, _} =
               ChatHosts.heartbeat(host, %{
                 "protocol_version" => 1,
                 "capabilities" => attachments_capabilities()
               })

      assert Repo.get!(RegisteredHost, host.id).capabilities == attachments_capabilities()
    end
  end

  # The shape the Go host emits once it makes and uses bot folders
  # (task-d63221c26f47cdba; server side task-ed93b8c0ab2b44b8): the attachments
  # shape plus `providers.claude.bot_folders: true`, codex unchanged. The server
  # must admit it before any binary sends it, or that host's heartbeats are
  # refused and it goes offline. The Go PR carries a byte-identical copy.
  describe "the Go binary's bot_folders shape" do
    @bot_folders_fixture Path.expand(
                           "../../support/fixtures/chat_host_go_capabilities_bot_folders.json",
                           __DIR__
                         )
    @attachments_fixture_path Path.expand(
                                "../../support/fixtures/chat_host_go_capabilities_attachments.json",
                                __DIR__
                              )

    defp bot_folders_capabilities, do: @bot_folders_fixture |> File.read!() |> Jason.decode!()

    defp claude_valid?(value) do
      caps = put_in(bot_folders_capabilities(), ["providers", "claude", "bot_folders"], value)
      RegisteredHost.heartbeat_changeset(%RegisteredHost{}, %{capabilities: caps}).valid?
    end

    test "it is the attachments fixture plus providers.claude.bot_folders and nothing else" do
      caps = bot_folders_capabilities()
      {flag, claude} = Map.pop(caps["providers"]["claude"], "bot_folders")
      assert flag == true

      attachments = @attachments_fixture_path |> File.read!() |> Jason.decode!()
      assert put_in(caps, ["providers", "claude"], claude) == attachments
    end

    test "enroll/2 and heartbeat/2 accept it and store the flag" do
      issued = issue()

      assert {:ok, %{credential: credential}} =
               ChatHosts.enroll(issued.enrollment_token, %{
                 "protocol_version" => 1,
                 "capabilities" => bot_folders_capabilities()
               })

      {:ok, host} = ChatHosts.authenticate(credential)

      assert {:ok, _} =
               ChatHosts.heartbeat(host, %{
                 "protocol_version" => 1,
                 "capabilities" => bot_folders_capabilities()
               })

      assert Repo.get!(RegisteredHost, host.id).capabilities == bot_folders_capabilities()
    end

    test "the flag is a boolean or absent" do
      assert claude_valid?(true)
      assert claude_valid?(false)
      refute claude_valid?("true")
      refute claude_valid?(1)
      refute claude_valid?(%{"root" => "/"})
    end

    test "a codex entry carrying it is refused" do
      for value <- [true, false] do
        caps = put_in(bot_folders_capabilities(), ["providers", "codex", "bot_folders"], value)
        refute RegisteredHost.heartbeat_changeset(%RegisteredHost{}, %{capabilities: caps}).valid?
      end
    end
  end

  describe "chat_runtime stays non-secret readiness metadata only" do
    defp heartbeat_valid?(chat_runtime) do
      caps = Map.put(go_capabilities(), "chat_runtime", chat_runtime)
      RegisteredHost.heartbeat_changeset(%RegisteredHost{}, %{capabilities: caps}).valid?
    end

    test "an extra key beside protocol is refused" do
      refute heartbeat_valid?(%{"protocol" => "bidirectional-v2", "token" => "sk-secret"})
    end

    test "an unknown protocol string is refused" do
      refute heartbeat_valid?(%{"protocol" => "sk-ant-not-a-protocol"})
    end

    test "a non-map chat_runtime is refused" do
      refute heartbeat_valid?("bidirectional-v2")
      refute heartbeat_valid?(%{})
    end

    test "an unknown fourth top-level key is still refused" do
      caps = Map.put(go_capabilities(), "env", %{"ANTHROPIC_API_KEY" => "sk-secret"})
      refute RegisteredHost.heartbeat_changeset(%RegisteredHost{}, %{capabilities: caps}).valid?
    end

    test "capabilities without chat_runtime still pass (older hosts)" do
      caps = Map.delete(go_capabilities(), "chat_runtime")
      assert RegisteredHost.heartbeat_changeset(%RegisteredHost{}, %{capabilities: caps}).valid?
    end
  end
end
