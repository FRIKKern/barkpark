defmodule BarkparkWeb.Studio.ChatLiveFileAttachmentReplayTest do
  @moduledoc """
  A replayed Studio chat row that carries a file (`/papers/chat-host-file-attachments-plan`,
  T2). Before this, replay read every pointer's bytes into a data URI, so a
  3 MB text file became a 4 MB broken `<img>` in the socket. A non-image
  pointer now draws a chip with its name and byte size and the store is not
  read; an image pointer still replays as an `<img>` with a data URI.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns /studio/chat.
  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments

  @admin_token "chat-file-replay-admin-token"

  @csv "name,city\nÅse,Tromsø\nBjørn,Bodø\n"

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "chat file replay admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_store = Application.get_env(:barkpark, StudioChat)

    dir =
      Path.join(System.tmp_dir!(), "bp_chat_file_replay_#{System.unique_integer([:positive])}")

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

    on_exit(fn ->
      File.rm_rf(dir)
      restore(:claude_chat, prev_chat)
      restore(StudioChat, prev_store)
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token}), id: id, dir: dir}
  end

  test "a replayed user row with a text/plain pointer renders its name and size and no img tag",
       %{conn: conn, id: id, dir: dir} do
    {:ok, pointer} = Attachments.put(id, @csv)
    assert pointer.media_type == "text/plain"

    # The store file is removed: a replay that still read it would draw
    # "attachment missing" instead of the chip, so the chip proves no read.
    File.rm!(Path.join(dir, pointer.path))

    append_user_row(id, "read these notes", [
      Map.put(Attachments.pointer_json(pointer), "name", "notes.csv")
    ])

    {:ok, view, _html} = live(conn, "/studio/chat/#{id}")
    row = view |> element(~s([data-role="user"])) |> render()

    assert row =~ "notes.csv"
    assert row =~ "#{byte_size(@csv)} B"
    refute row =~ "<img", "a file pointer must not render as an image"
    refute row =~ "data:text/plain", "a file's bytes must not ride the page"
    refute row =~ "attachment missing", "replay must not read a file pointer's bytes"
  end

  test "a file pointer with no name shows File, and an image beside it still replays as an img",
       %{conn: conn, id: id} do
    {:ok, text} = Attachments.put(id, @csv)
    {:ok, image} = Attachments.put(id, @png)

    append_user_row(id, "both", [Attachments.pointer_json(image), Attachments.pointer_json(text)])

    {:ok, view, _html} = live(conn, "/studio/chat/#{id}")
    row = view |> element(~s([data-role="user"])) |> render()

    assert row =~ "data:image/png;base64,#{Base.encode64(@png)}"
    assert row =~ "File"
    assert row =~ "#{byte_size(@csv)} B"
    refute row =~ Base.encode64(@csv)
  end

  defp append_user_row(id, text, pointers) do
    {:ok, _} =
      StudioChat.append_message(id, %{
        role: "user",
        source_markdown: text,
        metadata: %{"attachments" => pointers}
      })
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)
end
