defmodule BarkparkWeb.Studio.ChatTranscriptWindowTest do
  @moduledoc """
  Efficiency guard for the Studio chat transcript (task-9e21c3f285b3d7d0).

  The named failure mode: a long multi-hundred-turn agent session accumulated
  its ENTIRE history in the per-socket `@messages` assign with no cap, and the
  HEEx re-ran `group_agent_rows/1` over that FULL list on every render — O(n) per
  turn = O(n²) per session — while the child-brood accumulator appended with
  `acc ++ [m]` (O(k) per child = O(k²) per brood).

  These tests pin the three fixes so a regression fails loudly:

    1. `group_agent_rows/1` builds a brood in O(k), not O(k²) — asserted by a
       reductions micro-benchmark (N=2000 stays near-linear vs N=200) AND by
       child-order correctness (prepend + reverse-once keeps ascending seq).
    2. The grouping is memoized into `@grouped_rows` (the template no longer
       calls `group_agent_rows(@messages)` inline) so it runs once per append,
       not once per render.
    3. `@messages` (and the reopen DB load) are bounded to `@transcript_window`,
       so a long session's socket heap does not grow O(n).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Message
  alias BarkparkWeb.Studio.ChatLive

  @window 500
  @large_session_size 2000
  @admin_token "chat-transcript-window-admin-token"
  @source Path.expand("../../../../lib/barkpark_web/live/studio/chat_live.ex", __DIR__)

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "chat transcript window admin", "production", [
        "read",
        "write",
        "admin"
      ])

    :ok
  end

  # ── fix 3: bounded per-socket transcript ──────────────────────────────────

  describe "trim_transcript/1 — the per-socket window (fix 3)" do
    test "a session longer than the window keeps only the last @transcript_window rows" do
      msgs = for i <- 1..(2 * @window + 137), do: %{id: i, role: :assistant}

      trimmed = ChatLive.trim_transcript(msgs)

      assert length(trimmed) == @window
      # It keeps the TAIL — the most recent rows, in order.
      assert List.first(trimmed).id == length(msgs) - @window + 1
      assert List.last(trimmed).id == length(msgs)
    end

    test "a short session is returned untouched (the cap never truncates below the window)" do
      msgs = for i <- 1..10, do: %{id: i, role: :assistant}
      assert ChatLive.trim_transcript(msgs) == msgs
    end
  end

  describe "list_messages/2 — the bounded reopen load (fix 3, DB side)" do
    test "loads only the last N rows, still ascending, without pulling the whole history" do
      {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate()})

      total = 40

      for i <- 1..total do
        {:ok, _} = StudioChat.append_message(session, %{role: "user", source_markdown: "m#{i}"})
      end

      # Sanity: the unbounded arity-1 still returns everything (other callers rely on it).
      assert length(StudioChat.list_messages(session.id)) == total

      windowed = StudioChat.list_messages(session.id, 10)

      assert length(windowed) == 10
      seqs = Enum.map(windowed, & &1.seq)
      assert seqs == Enum.to_list((total - 9)..total)
    end

    test "a non-positive limit falls back to the full list" do
      {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate()})

      for i <- 1..5,
          do: StudioChat.append_message(session, %{role: "user", source_markdown: "m#{i}"})

      assert length(StudioChat.list_messages(session.id, 0)) == 5
    end
  end

  describe "large-session reopen evidence (N=2000)" do
    test "the capped heap is smaller and the reopened LiveView remains interactive", %{conn: conn} do
      session = seed_large_session(@large_session_size)

      {full_us, full} = :timer.tc(fn -> StudioChat.list_messages(session.id) end)

      {capped_us, capped} =
        :timer.tc(fn -> StudioChat.list_messages(session.id, @window) end)

      full_bytes = :erlang.external_size(full)
      capped_bytes = :erlang.external_size(capped)

      assert length(full) == @large_session_size
      assert length(capped) == @window
      assert capped_bytes < full_bytes

      IO.puts(
        "chat reopen N=#{@large_session_size}: " <>
          "full=#{full_us}us/#{full_bytes}B capped=#{capped_us}us/#{capped_bytes}B"
      )

      previous_chat = Application.get_env(:barkpark, :claude_chat)
      previous_demo = Application.get_env(:barkpark, :public_demo_studio)
      Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
      Application.put_env(:barkpark, :public_demo_studio, false)

      on_exit(fn ->
        restore_env(:claude_chat, previous_chat)
        restore_env(:public_demo_studio, previous_demo)
      end)

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {reopen_us, {:ok, view, _html}} =
        :timer.tc(fn -> live(conn, "/studio/chat/#{session.id}") end)

      messages = live_assigns(view).messages
      assert length(messages) == @window
      assert hd(messages).id == @large_session_size - @window + 1
      assert List.last(messages).id == @large_session_size

      render_change(element(view, "form[phx-submit=send]"), %{"message" => "still responsive"})
      assert live_assigns(view).composer_draft == "still responsive"
      assert Process.alive?(view.pid)

      IO.puts(
        "chat reopen N=#{@large_session_size}: LiveView mount=#{reopen_us}us; interaction=ok"
      )
    end
  end

  # ── fix 1: O(k) brood grouping ────────────────────────────────────────────

  describe "group_agent_rows/1 — linear brood build (fix 1)" do
    test "children nest under their spawn in ascending seq order (prepend + reverse-once)" do
      # 1 top-level spawn tool row + K child tool rows carrying its tool_use_id.
      messages =
        [spawn_row(1, "p")] ++ for(i <- 2..8, do: child_row(i, "p"))

      grouped = ChatLive.group_agent_rows(messages)

      # One agent block, its brood in the original ascending order.
      assert [{:agent, %{id: 1}, children}] = grouped
      assert Enum.map(children, & &1.id) == Enum.to_list(2..8)
    end

    test "the brood build is not superlinear — reductions at N=2000 stay near-linear vs N=200" do
      # Old `acc ++ [m]` is O(k²): reductions would grow ~100x from 200→2000.
      # The prepend+reverse-once fix is O(k): reductions grow ~linearly (~10x).
      small = agent_transcript(200)
      big = agent_transcript(2000)

      # Warm once so the measured pass excludes first-call setup noise.
      _ = ChatLive.group_agent_rows(small)
      _ = ChatLive.group_agent_rows(big)

      r_small = reductions(fn -> ChatLive.group_agent_rows(small) end)
      r_big = reductions(fn -> ChatLive.group_agent_rows(big) end)

      ratio = r_big / max(r_small, 1)

      # 10x input. Linear ⇒ ~10x work; quadratic ⇒ ~100x. Guard well below
      # quadratic; a regression to `acc ++ [m]` blows straight past this.
      assert ratio < 30,
             "group_agent_rows looks superlinear: N=200 -> #{r_small} reductions, " <>
               "N=2000 -> #{r_big} reductions (ratio #{Float.round(ratio, 1)}x, expected < 30x)"
    end
  end

  # ── fix 2: memoized grouping (once per append, not per render) ─────────────

  describe "grouping is memoized in @grouped_rows (fix 2)" do
    test "the template renders @grouped_rows, not an inline group_agent_rows(@messages) call" do
      src = File.read!(@source)

      assert String.contains?(src, "for item <- @grouped_rows"),
             "the transcript template must iterate the memoized @grouped_rows assign"

      refute String.contains?(src, "group_agent_rows(@messages)"),
             "group_agent_rows(@messages) inline in HEEx recomputes over the full " <>
               "transcript on every render — it must be memoized into @grouped_rows"
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp spawn_row(id, tool_use_id) do
    %{
      id: id,
      role: :tool,
      spawn?: true,
      parent_tool_use_id: nil,
      tool_use_id: tool_use_id
    }
  end

  defp child_row(id, parent) do
    %{id: id, role: :tool, spawn?: false, parent_tool_use_id: parent, tool_use_id: "c#{id}"}
  end

  # One spawn parent with `k` children — the exact shape whose brood build was
  # O(k²) under the old accumulator.
  defp agent_transcript(k) do
    [spawn_row(1, "p")] ++ for(i <- 2..(k + 1), do: child_row(i, "p"))
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    after_ - before
  end

  defp seed_large_session(count) do
    {:ok, session} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp", mode: "plan"})

    now = DateTime.utc_now()

    rows =
      for seq <- 1..count do
        %{
          session_id: session.id,
          seq: seq,
          role: "user",
          source_markdown: "message #{seq}",
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end

    {^count, nil} = Repo.insert_all(Message, rows)
    session
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp restore_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_env(key, value), do: Application.put_env(:barkpark, key, value)
end
