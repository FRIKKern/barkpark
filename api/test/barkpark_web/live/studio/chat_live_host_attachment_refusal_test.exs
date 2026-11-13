defmodule BarkparkWeb.Studio.ChatLiveHostAttachmentRefusalTest do
  @moduledoc """
  Studio's half of task-2b5de78f8f8d1c1a (Paper chat-host-attachments-plan,
  T2): an image sent in a session whose registered host does not advertise the
  attachments capability is refused before anything is leased, and the person
  is told why. Before T2 the turn was leased and the host dropped the image
  without a word.

  The host is enrolled through `ChatHosts` with ready claude capabilities and no
  `attachments` key, the image goes through the composer's real upload, and the
  host's queue is read the way `GET /v1/chat-host/commands` reads it.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy

  # A 1x1 PNG: the store sniffs the bytes, so a stand-in string would be refused.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()
    enable_chat_env()

    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "hatt-ws-#{n}", name: "HostAtt #{n}"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "hatt-proj-#{n}", name: "HostAtt Proj"})

    raw = "hatt-admin-#{n}"
    {:ok, _} = Auth.create_token(raw, "hatt admin", "production", ~w(read write admin), ws.id)

    {:ok, conn: init_test_session(conn, %{"api_token" => raw}), ws: ws, proj: proj}
  end

  test "an image to a host without the attachments capability is refused with an honest line",
       %{conn: conn, ws: ws, proj: proj} do
    host = enroll_text_only_host!(ws)
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          execution_target: "registered_host",
          execution_host_id: host.id
        },
        {:workspace, ws.id}
      )

    {:ok, view, _html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/chat/#{sid}")

    view
    |> file_input("#chat-composer-form", :attachments, [
      %{name: "pic.png", content: @png, type: "image/png"}
    ])
    |> render_upload("pic.png")

    render_submit(element(view, "form[phx-submit=send]"), %{"message" => "what is this?"})
    html = render(view)

    assert html =~ "receive images yet. Update barkpark-chat-host"
    refute html =~ "the session dropped"
    assert html =~ "Your attached images were not sent"

    sends =
      host
      |> ChatHosts.next_commands()
      |> Enum.filter(&(&1.command.operation == :send_turn))

    assert sends == []
  end

  defp enroll_text_only_host!(ws) do
    caps = %{
      "protocol_version" => 1,
      "providers" => %{
        "claude" => %{
          "installed" => true,
          "auth_ready" => true,
          "operations" => ~w(send_turn steer interrupt answer_approval close),
          "task_hands" => true
        }
      }
    }

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "old-mac-#{System.unique_integer([:positive])}",
        approved_roots: [System.tmp_dir!()],
        capabilities: caps
      })

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{capabilities: caps})

    {:ok, host} = ChatHosts.authenticate(credential)
    host
  end

  defp enable_chat_env do
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_store = Application.get_env(:barkpark, StudioChat)
    dir = Path.join(System.tmp_dir!(), "bp_host_att_#{System.unique_integer([:positive])}")

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

    on_exit(fn ->
      if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
          DynamicSupervisor.terminate_child(pid, child)
        end
      end

      File.rm_rf(dir)
      restore(:claude_chat, prev_chat)
      restore(StudioChat, prev_store)
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)
end
