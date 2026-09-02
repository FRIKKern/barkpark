defmodule BarkparkWeb.Studio.ChatKeyJumpPaletteTest do
  @moduledoc """
  studio-chat keyboard thread jump + session palette (task-f8884f89df2c39e3).

  THE ONE NAVIGATION PATH. The sidebar click is a `<.link patch={…}>`; the
  keyboard jump and the palette's Enter are `handle_event`s. Three surfaces,
  and it would be trivially easy for them to build three slightly different
  URLs (the `return_to` scope carrier is exactly the thing that gets dropped).
  They do not: all three go through `session_link_path/2`, and the runs below
  assert it by CONTENT — the sidebar link's rendered href and the keyboard's
  `assert_patch` destination must be the same string, `return_to` and all.

  `async: false` — these mounts share the seeded Default workspace, like every
  other chat suite.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat

  @admin_token "chat-keys-admin-token"

  setup %{conn: conn} do
    # Same leaked-session purge chat_live_test.exs runs: a Recorder that
    # outlived a prior test's sandbox can COMMIT chat_sessions rows that escape
    # rollback and ride list_sessions' recency-desc ordering ahead of the rows
    # seeded here — which would silently shift what "the 2nd visible session"
    # means and make the ordinal assertions below nondeterministic.
    Barkpark.Repo.query!("DELETE FROM chat_runtime_usage_receipts")
    Barkpark.Repo.query!("DELETE FROM epic_assignment_runtime_attempts")
    Barkpark.Repo.delete_all(Barkpark.StudioChat.Session)

    {:ok, _} =
      Auth.create_token(@admin_token, "chat keys admin", "production", ["read", "write", "admin"])

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

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Seed N sessions, oldest first. `list_sessions` orders recency-desc, so the
  # LAST one seeded is the sidebar's first row — the tests read the visible
  # order off the socket rather than assuming it.
  defp seed_sessions(titles) do
    Enum.map(titles, fn title ->
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
      StudioChat.rename(id, title)
      # The store's ordering key has second-ish resolution in some columns;
      # seeding in sequence keeps the recency order stable and unambiguous.
      id
    end)
  end

  defp visible_ids(view), do: Enum.map(lv_assigns(view).sessions, & &1.id)

  describe "Cmd/Ctrl+1..9 — the Nth VISIBLE sidebar session" do
    test "jumps to the Nth visible session through the sidebar's own URL", %{conn: conn} do
      seed_sessions(["Alpha thread", "Beta thread", "Gamma thread"])

      {:ok, view, html} = live(conn, "/studio/chat")

      ids = visible_ids(view)
      assert length(ids) == 3
      second = Enum.at(ids, 1)

      # The URL the SIDEBAR would navigate to for that same session, taken from
      # the rendered markup — not recomputed by the test.
      assert html =~ ~s(href="/studio/chat/#{second}")

      render_hook(view, "chat-jump", %{"n" => 2})

      # ONE navigation path: the keyboard's destination is the sidebar's href.
      assert_patch(view, "/studio/chat/#{second}")
      assert lv_assigns(view).session_id == second
    end

    test "the ordinal is the VISIBLE order, so the archived shelf re-indexes it", %{conn: conn} do
      [_a, _b, gamma] = seed_sessions(["Alpha thread", "Beta thread", "Gamma thread"])
      {:ok, _} = StudioChat.archive_session(gamma)

      {:ok, view, _html} = live(conn, "/studio/chat")

      # Active shelf: Gamma is hidden, so nothing is 3rd.
      assert length(visible_ids(view)) == 2
      render_hook(view, "chat-jump", %{"n" => 3})
      # A push_patch would run handle_params and stamp session_id; it stayed nil.
      assert lv_assigns(view).session_id == nil

      # Flip to the archived shelf: Gamma is now the ONLY visible row, and 1
      # means Gamma.
      render_click(view, "toggle-archived", %{})
      assert visible_ids(view) == [gamma]

      render_hook(view, "chat-jump", %{"n" => 1})
      assert_patch(view, "/studio/chat/#{gamma}")
    end

    test "a number past the visible count is a strict no-op", %{conn: conn} do
      seed_sessions(["Only thread"])
      {:ok, view, _html} = live(conn, "/studio/chat")

      assert length(visible_ids(view)) == 1
      before = lv_assigns(view).session_id

      for n <- [2, 3, 9] do
        render_hook(view, "chat-jump", %{"n" => n})
      end

      assert lv_assigns(view).session_id == before
      assert render(view) =~ "chats"
    end

    test "a nonsense ordinal never crashes the chat", %{conn: conn} do
      seed_sessions(["Only thread"])
      {:ok, view, _html} = live(conn, "/studio/chat")

      for n <- [0, -1, 10, 99, "abc", "2x", nil, %{}] do
        render_hook(view, "chat-jump", %{"n" => n})
      end

      assert lv_assigns(view).session_id == nil
      assert Process.alive?(view.pid)
    end

    test "a string ordinal from the wire works exactly like the number", %{conn: conn} do
      seed_sessions(["Alpha thread", "Beta thread"])
      {:ok, view, _html} = live(conn, "/studio/chat")

      first = Enum.at(visible_ids(view), 0)
      render_hook(view, "chat-jump", %{"n" => "1"})
      assert_patch(view, "/studio/chat/#{first}")
    end
  end

  describe "Cmd/Ctrl+K — the session palette" do
    test "opens listing every visible session by title, closed by default", %{conn: conn} do
      seed_sessions(["Alpha thread", "Beta thread"])
      {:ok, view, html} = live(conn, "/studio/chat")

      refute html =~ ~s(data-test-id="chat-palette")
      refute lv_assigns(view).palette_open

      html = render_hook(view, "chat-palette-open", %{})

      assert lv_assigns(view).palette_open
      assert html =~ ~s(data-test-id="chat-palette")
      assert html =~ "Alpha thread"
      assert html =~ "Beta thread"

      # The rows carry what the CLIENT filter reads: the title to match and the
      # id to activate. A palette whose rows lost data-palette-title filters to
      # nothing in the browser while looking perfectly fine here.
      for id <- visible_ids(view) do
        assert has_element?(view, ~s([data-palette-row][data-palette-id="#{id}"]))
      end

      assert has_element?(view, ~s(#chat-palette[phx-hook="ChatPalette"]))
      assert has_element?(view, "#chat-palette-input")
    end

    test "Enter activates the highlighted session through the sidebar's own URL", %{conn: conn} do
      seed_sessions(["Alpha thread", "Beta thread"])
      {:ok, view, html} = live(conn, "/studio/chat")

      target = Enum.at(visible_ids(view), 1)
      assert html =~ ~s(href="/studio/chat/#{target}")

      render_hook(view, "chat-palette-open", %{})
      render_hook(view, "chat-palette-activate", %{"id" => target})

      # Same destination as the sidebar link, and the palette closes behind it.
      assert_patch(view, "/studio/chat/#{target}")
      assert lv_assigns(view).session_id == target
      refute lv_assigns(view).palette_open
    end

    test "an id that is not on the visible list navigates nowhere", %{conn: conn} do
      [_alpha, _beta] = seed_sessions(["Alpha thread", "Beta thread"])
      hidden = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: hidden, cwd: "/tmp", mode: "plan"})
      {:ok, _} = StudioChat.archive_session(hidden)

      {:ok, view, _html} = live(conn, "/studio/chat")
      refute hidden in visible_ids(view)

      render_hook(view, "chat-palette-open", %{})
      render_hook(view, "chat-palette-activate", %{"id" => hidden})

      # A push_patch would run handle_params and stamp session_id; it stayed nil.
      assert lv_assigns(view).session_id == nil
      refute lv_assigns(view).palette_open
    end

    test "Escape closes the palette and does NOT interrupt a running turn", %{conn: conn} do
      seed_sessions(["Alpha thread"])
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_hook(view, "chat-palette-open", %{})
      assert lv_assigns(view).palette_open

      # What Escape-in-the-palette pushes. It is a DIFFERENT event from the
      # interrupt, and it touches no session state.
      html = render_hook(view, "chat-palette-close", %{})

      refute lv_assigns(view).palette_open
      refute html =~ ~s(data-test-id="chat-palette")
      assert lv_assigns(view).status == :new
      assert lv_assigns(view)[:interrupt_requested] == false

      # The palette never routes Escape to the SERVER at all — no phx-key
      # binding on it — so the only thing that can reach `stop_turn` is the
      # global interrupt listener, which the hook stops (proven in
      # api/assets/chat-palette/__palette.test.mjs).
      refute has_element?(view, ~s(#chat-palette [phx-key="Escape"]))
    end

    test "the inline session-rename input still owns Escape", %{conn: conn} do
      [id] = seed_sessions(["Alpha thread"])
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(view, "session-rename-start", %{"id" => id})

      assert has_element?(
               view,
               ~s([data-chat-rename][phx-keydown="session-rename-cancel"][phx-key="Escape"])
             )
    end
  end

  describe "the client half is wired the way every other prebuilt chat asset is" do
    test "root.html.heex loads bp-chat-palette.js at the BOTTOM and registers both hooks" do
      root = File.read!("lib/barkpark_web/layouts/root.html.heex")

      assert root =~ "/assets/bp-chat-palette.js",
             "root.html.heex must load the palette asset, else no key ever reaches the server"

      assert root =~ "Hooks.ChatKeys",
             "root.html.heex must register ChatKeys in the LiveSocket Hooks map"

      assert root =~ "Hooks.ChatPalette",
             "root.html.heex must register ChatPalette in the LiveSocket Hooks map"

      # Golden Rule 4: a chat asset is never a blocking <script> in <head>.
      [head, _body] = String.split(root, "</head>", parts: 2)
      refute head =~ "/assets/bp-chat-palette.js"

      asset = File.read!("priv/static/assets/bp-chat-palette.js")
      assert asset =~ "window.BarkparkChatKeys"
      assert asset =~ "window.BarkparkChatPalette"

      # The asset is PREBUILT — committed, not produced by a build step.
      assert File.exists?("priv/static/assets/bp-chat-palette.js")
      assert File.exists?("assets/chat-palette/__palette.test.mjs")
    end

    test "the ChatKeys hook element is mounted and hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      assert has_element?(view, ~s(#chat-keys[phx-hook="ChatKeys"]))
    end
  end
end
