defmodule Barkpark.StudioChat.TitlesHostGateTest do
  @moduledoc """
  task-dfe28132e8d842ad: the session-title job's CLI layer runs the `claude`
  binary ON THE INSTANCE HOST, as the service user, with the user's first
  message in its argv. `ChatLive` kicks the job after every successful turn,
  whichever profile the turn itself ran on, so a tenant's sandboxed (cloud) turn
  ended with the tenant's text handed to a host process whenever the API layer
  was absent or failed.

  The host rule is the one the turn itself obeys, asked of the SESSION's owner
  workspace (`HostExecution.workspace_may_host_exec?/1`): the Default workspace
  and instance-global (`nil`-owned) sessions keep the CLI title; any other
  owner, and a session with no row, skip straight to the derived title.

  Nothing real runs: the CLI seam is a recorder that reports its argv.
  """
  # async: false — the title seams are Application env, and the supervised
  # generation task needs the SHARED sandbox connection.
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Recorder, Titles}
  alias Barkpark.Tenancy

  defmodule FailingAdapter do
    def post(_url, _body, _headers), do: {:error, :offline}
  end

  defmodule WorkingAdapter do
    def post(_url, _body, _headers),
      do: {:ok, 200, %{"content" => [%{"type" => "text", "text" => ~s({"title":"API title"})}]}}
  end

  defmodule RecordingCli do
    # The fake host runner: tells the test it was started, and with what.
    def run(binary, args) do
      send(Application.fetch_env!(:barkpark, :test_title_cli_observer), {:host_cli, binary, args})
      {:ok, ~s({"title":"CLI title"})}
    end
  end

  @message "tenant secret words\nsecond line"

  setup do
    {default_ws, _project} = ensure_default_scope!()

    {:ok, tenant_ws} =
      Tenancy.create_workspace(%{
        slug: "title-tenant-#{System.unique_integer([:positive])}",
        name: "Tenant"
      })

    Application.put_env(:barkpark, :studio_chat_title_http_adapter, FailingAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, RecordingCli)
    Application.put_env(:barkpark, :test_title_cli_observer, self())
    # A key, so the API layer is attempted (and fails) rather than skipped.
    Application.put_env(:barkpark, :anthropic_api_key, "test-key")

    on_exit(fn ->
      for k <- [
            :studio_chat_title_http_adapter,
            :studio_chat_title_cli,
            :test_title_cli_observer,
            :anthropic_api_key
          ] do
        Application.delete_env(:barkpark, k)
      end
    end)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

    %{default_ws: default_ws, tenant_ws: tenant_ws}
  end

  defp session!(scope, attrs \\ %{}) do
    {:ok, session} =
      StudioChat.create_session(
        Map.merge(%{id: Ecto.UUID.generate(), cwd: "/tmp/x"}, attrs),
        scope
      )

    session.id
  end

  describe "a session whose owner may not run things on the instance host" do
    test "a tenant-owned session never starts the host CLI; it gets the derived title",
         %{tenant_ws: ws} do
      sid = session!({:workspace, ws.id})

      {:ok, _task} = Titles.kick_title(sid, @message)

      assert_receive {:chat_title, ^sid, "tenant secret words"}, 2_000
      refute_received {:host_cli, _, _}
      assert StudioChat.get_session(sid).title == "tenant secret words"
    end

    test "a tenant's registered_host session does not reach the INSTANCE host either",
         %{tenant_ws: ws} do
      sid =
        session!({:workspace, ws.id}, %{
          execution_target: "registered_host",
          execution_host_id: Ecto.UUID.generate()
        })

      {:ok, _task} = Titles.kick_title(sid, @message)

      assert_receive {:chat_title, ^sid, "tenant secret words"}, 2_000
      refute_received {:host_cli, _, _}
    end

    test "no key configured at all: still no host CLI for a tenant", %{tenant_ws: ws} do
      Application.delete_env(:barkpark, :anthropic_api_key)
      sid = session!({:workspace, ws.id})

      {:ok, _task} = Titles.kick_title(sid, @message)

      assert_receive {:chat_title, ^sid, _title}, 2_000
      refute_received {:host_cli, _, _}
    end

    test "a session with no row (deleted mid-flight) never starts the host CLI" do
      {:ok, pid} = Titles.kick_title(Ecto.UUID.generate(), @message)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      refute_received {:host_cli, _, _}
    end
  end

  describe "controls: nothing else changes" do
    test "a Default-workspace session still gets its CLI title", %{default_ws: ws} do
      sid = session!({:workspace, ws.id})

      {:ok, _task} = Titles.kick_title(sid, @message)

      assert_receive {:chat_title, ^sid, "CLI title"}, 2_000
      assert_received {:host_cli, "claude", args}
      assert args == Titles.cli_args(@message)
    end

    test "an instance-global (nil-owned) session still gets its CLI title" do
      sid = session!(:global)

      {:ok, _task} = Titles.kick_title(sid, @message)

      assert_receive {:chat_title, ^sid, "CLI title"}, 2_000
      assert_received {:host_cli, "claude", _args}
    end

    test "when the API layer works a tenant gets the API title, as before", %{tenant_ws: ws} do
      Application.put_env(:barkpark, :studio_chat_title_http_adapter, WorkingAdapter)
      sid = session!({:workspace, ws.id})

      {:ok, _task} = Titles.kick_title(sid, @message)

      assert_receive {:chat_title, ^sid, "API title"}, 2_000
      refute_received {:host_cli, _, _}
    end
  end
end
