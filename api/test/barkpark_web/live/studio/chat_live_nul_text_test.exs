defmodule BarkparkWeb.Studio.ChatLiveNulTextTest do
  @moduledoc """
  Studio chat text holding U+0000 (task-820afe5940d0e6e0).

  The named failure mode: Postgres refuses U+0000 in a text column (22021) and
  in jsonb (22P05). `StudioChat.rename/2`, `set_draft/2` and
  `append_message/2` passed it straight to the store and raised, and ChatLive
  called them with no check, so one crafted LiveView event (a rename, a draft
  left behind on a session switch, a send) crashed the view. The HTTP routes
  refuse it since #26657.

  The three context functions now answer `{:error, :nul_character}` and change
  nothing, so every caller gets the check. ChatLive refuses a send before it
  echoes or dispatches anything and a draft before it is kept, and shows a
  plain error line for all three.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat

  @admin_token "chat-nul-admin-token"
  @nul "before\u0000after"
  @error "contain a NUL character (U+0000)"

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "chat nul admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
          DynamicSupervisor.terminate_child(pid, child)
        end
      end

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  describe "StudioChat context" do
    test "rename, set_draft and append_message refuse NUL with a typed error and change nothing" do
      sid = seed_session("Keep me")
      {:ok, _} = StudioChat.set_draft(sid, "kept draft")

      assert StudioChat.rename(sid, @nul) == {:error, :nul_character}
      assert StudioChat.set_draft(sid, @nul) == {:error, :nul_character}

      assert StudioChat.append_message(sid, %{role: "user", source_markdown: @nul}) ==
               {:error, :nul_character}

      # Nested in the jsonb metadata, as a value, a list item or a key.
      for metadata <- [
            %{"attachments" => [%{"name" => @nul}]},
            %{"input" => %{"command" => @nul}},
            %{@nul => true}
          ] do
        assert StudioChat.append_message(sid, %{
                 role: "user",
                 source_markdown: "ok",
                 metadata: metadata
               }) ==
                 {:error, :nul_character}
      end

      session = StudioChat.get_session(sid)
      assert session.title == "Keep me"
      assert session.draft == "kept draft"
      assert StudioChat.list_messages(sid, :global) == []
    end

    test "text a client sends today is still stored" do
      sid = seed_session("Before")

      for text <- [
            "emoji 🐕‍🦺 and RTL שלום",
            "tab\there",
            <<1>>,
            <<0x7F>>,
            "�",
            "the literal \\u0000"
          ] do
        assert {:ok, %{title: ^text}} = StudioChat.rename(sid, text)
        assert {:ok, %{draft: ^text}} = StudioChat.set_draft(sid, text)

        assert {:ok, %{source_markdown: ^text}} =
                 StudioChat.append_message(sid, %{
                   role: "user",
                   source_markdown: text,
                   metadata: %{"t" => text}
                 })
      end

      assert {:ok, %{draft: nil}} = StudioChat.set_draft(sid, nil)
      assert StudioChat.rename(Ecto.UUID.generate(), "x") == {:error, :not_found}
      assert StudioChat.set_draft(Ecto.UUID.generate(), "x") == {:error, :not_found}
    end
  end

  describe "ChatLive" do
    test "a rename holding NUL leaves the view alive with a plain error and the title unchanged",
         %{conn: conn} do
      sid = seed_session("Original")
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-rename-#{sid}"])))
      html = render_submit(element(view, "form[phx-submit=session-rename]"), %{"title" => @nul})

      assert Process.alive?(view.pid)
      assert html =~ @error
      assert StudioChat.get_session(sid).title == "Original"

      # The view still works: a normal rename lands.
      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-rename-#{sid}"])))
      render_submit(element(view, "form[phx-submit=session-rename]"), %{"title" => "Renamed"})
      assert StudioChat.get_session(sid).title == "Renamed"
    end

    test "a draft holding NUL, left on a session switch, leaves the view alive with a plain error",
         %{conn: conn} do
      sid = seed_session("Drafting")
      other = seed_session("Other")
      {:ok, _} = StudioChat.set_draft(sid, "kept draft")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      html = render_change(element(view, "form[phx-submit=send]"), %{"message" => @nul})
      assert html =~ @error

      render_patch(view, "/studio/chat/#{other}")
      assert Process.alive?(view.pid)
      assert StudioChat.get_session(sid).draft == "kept draft"
    end

    test "a send holding NUL leaves the view alive with a plain error, dispatching and storing nothing",
         %{conn: conn} do
      sid = seed_session("Sending")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => @nul})
      # The deferred phase of a send, if one was queued, runs before this render.
      html = render(view) <> html

      assert Process.alive?(view.pid)
      assert html =~ @error
      refute html =~ ~r/data-chat-status="(working|thinking)"/
      assert StudioChat.list_messages(sid, :global) == []
      assert Barkpark.StudioChat.Recorder.whereis(sid) == nil

      # The view still sends: a normal message goes through.
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      assert html =~ "hello"
      assert html =~ ~r/data-chat-status="(working|thinking)"/
    end
  end

  defp seed_session(title) do
    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
    {:ok, _} = StudioChat.rename(id, title)
    id
  end
end
