defmodule BarkparkWeb.Studio.McpChipReplayCapTest do
  @moduledoc """
  scc-w12-chip-replay-cap — the recorder's 4 KB raw-output cap must not cost a
  large MCP result its chip on REPLAY.

  The live tab reads the tool_result block UNCAPPED (`chat_live.ex`
  `tool_result_text/1`), so `ChatToolRenderer.chip/2` decodes it and draws a
  first-class chip. The Recorder persists at most `@result_text_cap` characters
  (`recorder.ex` `result_text/1`), so a >4 KB JSON body lands in the row cut
  mid-object — invalid JSON, no chip, generic `⎿` row. Same session, two
  different answers: the parity break this file fences.

  The fix persists a COMPACT VERSIONED chip payload
  (`Barkpark.StudioChat.McpChip`) alongside the still-capped raw text, and the
  renderer prefers it. These tests drive the REAL Recorder (no LiveView) and
  compare the chip the live path computes against the chip the persisted row
  yields.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ChatToolRenderer

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})
    {:ok, recorder} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})
    %{sid: id, recorder: recorder}
  end

  # ── frame plumbing (the Session's own delivery shape) ────────────────────────

  defp frame(recorder, msg) do
    send(recorder, msg)
    :sys.get_state(recorder)
    :ok
  end

  defp tool_use_frame(id, name, input) do
    {:claude_chat_event,
     %{
       "type" => "assistant",
       "message" => %{
         "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
       }
     }}
  end

  defp tool_result_frame(id, content, error? \\ false) do
    block =
      %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
      |> then(fn b -> if error?, do: Map.put(b, "is_error", true), else: b end)

    {:claude_chat_event, %{"type" => "user", "message" => %{"content" => [block]}}}
  end

  defp row(sid, id) do
    StudioChat.list_messages(sid) |> Enum.find(&(&1.metadata["tool_use_id"] == id))
  end

  # Record one MCP tool call + its result, and answer the persisted row's
  # metadata — exactly the map `ChatLive.replay_message/2` reads back.
  defp record(recorder, sid, id, tool, output) do
    frame(recorder, tool_use_frame(id, tool, %{}))
    frame(recorder, tool_result_frame(id, output))
    row(sid, id).metadata
  end

  # The chip a REPLAYED row yields: the persisted (capped) text plus whatever
  # structured payload the row carries — the same two arguments chat_live hands
  # the renderer for a replayed message.
  defp replay_chip(meta) do
    ChatToolRenderer.chip(meta["tool"], meta["output"], meta["mcp_chip"])
  end

  # A search result whose JSON body is far past the recorder's raw-text cap.
  defp big_search_payload(n) do
    docs =
      for i <- 1..n do
        %{
          "doc_id" => "task-#{i}",
          "title" => "Result number #{i} #{String.duplicate("x", 100)}",
          "type" => "task",
          "lifecycle_status" => "open",
          # a bulky body the chip never needs — it must NOT reach the store
          "content" => %{"secret_token" => "bp_live_shhh", "body" => String.duplicate("y", 400)}
        }
      end

    Jason.encode!(%{"ok" => true, "docs" => docs})
  end

  describe "large MCP results keep their chip through replay" do
    test "a >4 KB search result chips IDENTICALLY live and after replay",
         %{sid: sid, recorder: recorder} do
      output = big_search_payload(700)
      assert byte_size(output) > 100_000

      tool = "mcp__barkpark__task_ready"
      # LIVE: chat_live reads the tool_result block uncapped.
      live = ChatToolRenderer.chip(tool, output)
      assert %{kind: :search, total: 700, overflow: 692} = live

      meta = record(recorder, sid, "toolu_big", tool, output)

      # the RAW text cap is untouched — the store never holds the 100 KB body
      assert String.length(meta["output"]) == 4_000
      assert meta["mcp"] == true

      assert replay_chip(meta) == live
    end

    test "a >4 KB task_prime result keeps its counts and ready head on replay",
         %{sid: sid, recorder: recorder} do
      ready =
        for i <- 1..40 do
          %{
            "doc_id" => "task-r#{i}",
            "title" => "Ready row #{i} #{String.duplicate("z", 120)}",
            "lifecycle_status" => "ready"
          }
        end

      output =
        Jason.encode!(%{
          "ok" => true,
          "worker" => "chat-w3",
          "counts" => %{"open" => 12, "in_progress" => 3, "done" => 40},
          "ready" => ready
        })

      assert byte_size(output) > 4_000

      tool = "mcp__barkpark__task_prime"
      live = ChatToolRenderer.chip(tool, output)
      assert %{kind: :prime, ready_total: 40, overflow: 35} = live

      meta = record(recorder, sid, "toolu_prime", tool, output)

      assert String.length(meta["output"]) == 4_000
      assert replay_chip(meta) == live
    end

    test "a SMALL result is unchanged — no envelope needed, same chip both paths",
         %{sid: sid, recorder: recorder} do
      output = Jason.encode!(%{"ok" => true, "doc" => %{"doc_id" => "task-abc", "title" => "Tiny"}})
      tool = "mcp__barkpark__task_show"

      live = ChatToolRenderer.chip(tool, output)
      assert %{kind: :task, label: "Tiny"} = live

      meta = record(recorder, sid, "toolu_small", tool, output)

      # the raw text is stored WHOLE (well under the cap) — the pre-existing
      # replay route still works on its own
      assert meta["output"] == output
      assert ChatToolRenderer.chip(tool, meta["output"]) == live
      assert replay_chip(meta) == live
    end

    test "the persisted envelope carries no bulky body and no secret",
         %{sid: sid, recorder: recorder} do
      meta =
        record(recorder, sid, "toolu_lean", "mcp__barkpark__task_ready", big_search_payload(700))

      envelope = Jason.encode!(meta["mcp_chip"])

      refute envelope =~ "bp_live_shhh"
      refute envelope =~ String.duplicate("y", 40)
      assert byte_size(envelope) < 4_000
    end

    test "a NON-mcp tool row gets no envelope — host rows are byte-unchanged",
         %{sid: sid, recorder: recorder} do
      meta = record(recorder, sid, "toolu_host", "Bash", big_search_payload(700))

      refute Map.has_key?(meta, "mcp_chip")
      refute Map.has_key?(meta, "mcp")
      assert String.length(meta["output"]) == 4_000
    end
  end

  describe "degrade honestly" do
    test "a malformed / unknown-version / redacted envelope falls back, never raises" do
      tool = "mcp__barkpark__task_ready"
      truncated = String.slice(big_search_payload(700), 0, 4_000)

      for bad <- [
            nil,
            "not a map",
            %{},
            %{"v" => 99, "payload" => %{"docs" => [%{"title" => "Nope"}]}},
            %{"v" => 1},
            %{"v" => 1, "payload" => nil},
            %{"v" => 1, "payload" => "redacted"},
            %{"v" => 1, "payload" => %{"docs" => "not a list"}},
            %{"payload" => %{"docs" => [%{"title" => "No version"}]}}
          ] do
        assert ChatToolRenderer.chip(tool, truncated, bad) == nil,
               "expected the generic row for #{inspect(bad)}"
      end
    end

    test "an is_error result still persists no envelope and yields no chip",
         %{sid: sid, recorder: recorder} do
      frame(recorder, tool_use_frame("toolu_err", "mcp__barkpark__task_show", %{}))
      frame(recorder, tool_result_frame("toolu_err", "error: task task-nope not found", true))

      meta = row(sid, "toolu_err").metadata

      assert meta["tool_error"] == true
      refute Map.has_key?(meta, "mcp_chip")
      assert replay_chip(meta) == nil
    end

    test "an {ok:false} outcome persists no envelope and yields no chip",
         %{sid: sid, recorder: recorder} do
      meta =
        record(
          recorder,
          sid,
          "toolu_nores",
          "mcp__barkpark__task_next",
          Jason.encode!(%{"ok" => false, "reason" => "no ready task"})
        )

      refute Map.has_key?(meta, "mcp_chip")
      assert replay_chip(meta) == nil
    end
  end
end
