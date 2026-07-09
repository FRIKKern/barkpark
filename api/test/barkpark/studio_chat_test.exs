defmodule Barkpark.StudioChatTest do
  @moduledoc """
  The Studio Claude chat session index + display-history context (epic
  studio-claude-chat, wave 1, charter D6/D7/D8). No HTTP route touches these
  tables — this is the whole persistence contract, exercised directly.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat

  defp new_session(attrs \\ %{}) do
    id = Ecto.UUID.generate()
    {:ok, s} = StudioChat.create_session(Map.merge(%{id: id, cwd: "/tmp", mode: "plan"}, attrs))
    s
  end

  describe "create_session/1 + get_session/1" do
    test "mints a row keyed by the caller-provided uuid with sane defaults" do
      s = new_session()
      assert s.title == "New chat"
      assert s.title_source == "default"
      assert s.status == "active"
      assert s.message_count == 0
      assert s.last_active_at

      got = StudioChat.get_session(s.id)
      assert got.id == s.id
    end

    test "get_session/1 is nil for an unknown id and for a non-uuid string" do
      refute StudioChat.get_session(Ecto.UUID.generate())
      refute StudioChat.get_session("not-a-uuid")
      refute StudioChat.get_session(nil)
    end
  end

  describe "append_message/2" do
    test "assigns monotonic seq and bumps message_count + summary + last_active_at" do
      s = new_session()
      before = s.last_active_at

      {:ok, m0} = StudioChat.append_message(s.id, %{role: "user", source_markdown: "first prompt"})
      {:ok, m1} = StudioChat.append_message(s.id, %{role: "assistant", source_markdown: "the reply"})

      assert m0.seq == 0
      assert m1.seq == 1

      reloaded = StudioChat.get_session(s.id)
      assert reloaded.message_count == 2
      assert reloaded.summary == "the reply"
      assert DateTime.compare(reloaded.last_active_at, before) in [:gt, :eq]
    end

    test "a tool message bumps the count but never owns the summary" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s.id, %{role: "user", source_markdown: "do the thing"})

      {:ok, _} =
        StudioChat.append_message(s.id, %{
          role: "tool",
          source_markdown: "Read — file_path: /etc/hosts",
          metadata: %{"tool" => "Read"}
        })

      reloaded = StudioChat.get_session(s.id)
      assert reloaded.message_count == 2
      # the last USER/assistant text stays the summary, not the tool line
      assert reloaded.summary == "do the thing"
    end

    test "summary is a single clipped line" do
      s = new_session()
      long = String.duplicate("x", 400)
      {:ok, _} = StudioChat.append_message(s.id, %{role: "user", source_markdown: long <> "\nsecond"})

      summary = StudioChat.get_session(s.id).summary
      assert String.length(summary) <= 140
      refute summary =~ "second"
    end
  end

  describe "list_sessions/0 recency" do
    test "orders most-recent activity first" do
      a = new_session()
      b = new_session()
      # b becomes the most recently active
      {:ok, _} = StudioChat.append_message(a.id, %{role: "user", source_markdown: "a"})
      {:ok, _} = StudioChat.append_message(b.id, %{role: "user", source_markdown: "b"})

      ids = StudioChat.list_sessions() |> Enum.map(& &1.id)
      assert Enum.take(ids, 2) == [b.id, a.id]
    end
  end

  describe "list_messages/1" do
    test "returns messages in seq order" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s.id, %{role: "user", source_markdown: "one"})
      {:ok, _} = StudioChat.append_message(s.id, %{role: "assistant", source_markdown: "two"})

      assert StudioChat.list_messages(s.id) |> Enum.map(& &1.source_markdown) == ["one", "two"]
    end
  end

  describe "status" do
    test "update_status/2 and mark_exited/1 move the lifecycle" do
      s = new_session()
      StudioChat.update_status(s.id, :working)
      assert StudioChat.get_session(s.id).status == "working"

      StudioChat.mark_exited(s.id)
      assert StudioChat.get_session(s.id).status == "exited"
    end
  end

  describe "titles (clobber guard, D13)" do
    test "maybe_set_ai_title/2 lands only while the title is still default" do
      s = new_session()
      StudioChat.maybe_set_ai_title(s.id, "Trace a request through Studio")

      titled = StudioChat.get_session(s.id)
      assert titled.title == "Trace a request through Studio"
      assert titled.title_source == "ai"

      # a second AI title cannot clobber the first (title_source is no longer default)
      StudioChat.maybe_set_ai_title(s.id, "Some other title")
      assert StudioChat.get_session(s.id).title == "Trace a request through Studio"
    end

    test "a human rename always wins and is never overwritten by AI" do
      s = new_session()
      StudioChat.rename(s.id, "My careful name")
      assert StudioChat.get_session(s.id).title_source == "human"

      StudioChat.maybe_set_ai_title(s.id, "AI wants this")
      assert StudioChat.get_session(s.id).title == "My careful name"
    end
  end

  describe "record_result_metrics/2" do
    test "folds usage + cost into the session totals" do
      s = new_session()

      StudioChat.record_result_metrics(s.id, %{
        input_tokens: 120,
        output_tokens: 45,
        total_cost_usd: 0.0123,
        model: "claude-opus"
      })

      StudioChat.record_result_metrics(s.id, %{input_tokens: 30, output_tokens: 10, total_cost_usd: 0.002})

      reloaded = StudioChat.get_session(s.id)
      assert reloaded.input_tokens == 150
      assert reloaded.output_tokens == 55
      assert_in_delta reloaded.total_cost_usd, 0.0143, 0.00001
      assert reloaded.model == "claude-opus"
    end

    test "tolerates missing usage fields" do
      s = new_session()
      StudioChat.record_result_metrics(s.id, %{total_cost_usd: nil})
      reloaded = StudioChat.get_session(s.id)
      assert reloaded.input_tokens == 0
      assert reloaded.total_cost_usd == 0.0
    end
  end
end
