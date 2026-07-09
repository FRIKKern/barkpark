defmodule Barkpark.StudioChatTest do
  @moduledoc """
  Studio Claude chat session-store spine (epic studio-claude-chat, charter
  D6-D8/D13), proved NON-VACUOUSLY:

    * the minted UUID IS the PK (autogenerate off) and a non-UUID read is a
      clean `nil`, never a crash;
    * `seq` is monotonic PER session and independent across interleaved sessions
      (the concrete failure the UNIQUE index guards);
    * append bumps the denormalised sidebar fields in one shot;
    * the rename ⇄ AI-title clobber guard holds BOTH ways (human always wins,
      the SQL WHERE decides the race);
    * metrics accumulate model-agnostically across turns.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Message, Session}

  defp new_session(attrs \\ %{}) do
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    {:ok, session} = StudioChat.create_session(Map.put(attrs, :id, id))
    session
  end

  describe "create_session/1 + get_session/1" do
    test "the caller-minted UUID is the PK (autogenerate false) and round-trips" do
      id = Ecto.UUID.generate()
      {:ok, session} = StudioChat.create_session(%{id: id, cwd: "/tmp/x", mode: "default"})

      assert session.id == id
      assert session.title == "New chat"
      assert session.title_source == "default"
      assert session.status == "active"
      assert session.message_count == 0
      assert session.total_cost_usd == 0.0
      assert session.last_active_at != nil

      assert StudioChat.get_session(id).id == id
    end

    test "id is required — no server-side autogenerate" do
      assert {:error, changeset} = StudioChat.create_session(%{cwd: "/tmp"})
      assert %{id: _} = errors_on(changeset)
    end

    test "a non-UUID or missing id reads as nil, never a 500" do
      assert StudioChat.get_session("not-a-uuid") == nil
      assert StudioChat.get_session(nil) == nil
      assert StudioChat.get_session(Ecto.UUID.generate()) == nil
    end

    test "an invalid status is rejected" do
      assert {:error, changeset} =
               StudioChat.create_session(%{id: Ecto.UUID.generate(), status: "banana"})

      assert %{status: _} = errors_on(changeset)
    end
  end

  describe "append_message/2 — seq allocation" do
    test "seq is monotonic 1,2,3 within a session" do
      s = new_session()

      {:ok, m1} = StudioChat.append_message(s, %{role: "user", source_markdown: "hi"})
      {:ok, m2} = StudioChat.append_message(s, %{role: "assistant", source_markdown: "yo"})
      {:ok, m3} = StudioChat.append_message(s.id, %{role: "user", source_markdown: "more"})

      assert [m1.seq, m2.seq, m3.seq] == [1, 2, 3]
    end

    test "seq is independent across interleaved sessions" do
      a = new_session()
      b = new_session()

      {:ok, a1} = StudioChat.append_message(a, %{role: "user", source_markdown: "a1"})
      {:ok, b1} = StudioChat.append_message(b, %{role: "user", source_markdown: "b1"})
      {:ok, a2} = StudioChat.append_message(a, %{role: "user", source_markdown: "a2"})
      {:ok, b2} = StudioChat.append_message(b, %{role: "user", source_markdown: "b2"})
      {:ok, a3} = StudioChat.append_message(a, %{role: "user", source_markdown: "a3"})

      assert [a1.seq, a2.seq, a3.seq] == [1, 2, 3]
      assert [b1.seq, b2.seq] == [1, 2]

      assert Enum.map(StudioChat.list_messages(a.id), & &1.seq) == [1, 2, 3]
      assert Enum.map(StudioChat.list_messages(b.id), & &1.seq) == [1, 2]
    end

    test "a duplicate explicit seq cannot collide — seq is always reallocated" do
      s = new_session()
      {:ok, m1} = StudioChat.append_message(s, %{role: "user", seq: 99, source_markdown: "x"})
      {:ok, m2} = StudioChat.append_message(s, %{role: "user", seq: 99, source_markdown: "y"})
      # caller-supplied seq is ignored; allocator wins
      assert [m1.seq, m2.seq] == [1, 2]
    end

    test "string-keyed attrs are accepted (JSON-frame ergonomics)" do
      s = new_session()

      {:ok, m} =
        StudioChat.append_message(s, %{
          "role" => "assistant",
          "source_markdown" => "**hello**",
          "metadata" => %{"tool" => "bash"}
        })

      assert m.role == "assistant"
      assert m.source_markdown == "**hello**"
      assert m.metadata == %{"tool" => "bash"}
    end

    test "metadata defaults to an empty map and markdown may be nil" do
      s = new_session()
      {:ok, m} = StudioChat.append_message(s, %{role: "system"})
      assert m.metadata == %{}
      assert m.source_markdown == nil
    end
  end

  # Two tabs on one session (or a takeover racing the old owner) can both read
  # the same MAX(seq) and try to claim it. next_seq is SELECT-max+1, so the
  # UNIQUE [session_id, seq] index is the backstop and append_message RETRIES
  # the mapped conflict up to 3x — a same-session race must NEVER silently drop
  # a message (the old bug: callers discarded {:error, _}).
  describe "append_message/2 — concurrent-seq discipline (charter D20b)" do
    test "a burst of appends never drops — seqs are contiguous 1..N" do
      s = new_session()

      results =
        for i <- 1..25,
            do: StudioChat.append_message(s, %{role: "user", source_markdown: "m#{i}"})

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert StudioChat.list_messages(s.id) |> Enum.map(& &1.seq) == Enum.to_list(1..25)
      assert StudioChat.get_session(s.id).message_count == 25
    end

    test "the UNIQUE [session_id, seq] index maps to a retriable changeset, not a raise" do
      # The PRECONDITION for the retry loop: a duplicate seq must come back as
      # {:error, changeset} carrying the NAMED constraint — if the schema ever
      # dropped `unique_constraint`, Repo.insert would RAISE and this fails.
      s = new_session()
      attrs = %{session_id: s.id, seq: 1, role: "user", source_markdown: "x"}

      assert {:ok, _} = %Message{} |> Message.changeset(attrs) |> Barkpark.Repo.insert()

      assert {:error, changeset} =
               %Message{}
               |> Message.changeset(%{attrs | source_markdown: "y"})
               |> Barkpark.Repo.insert()

      assert Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
               opts[:constraint] == :unique and
                 opts[:constraint_name] == "chat_messages_session_id_seq_index"
             end)
    end

    test "a non-seq failure (unknown-session FK) surfaces immediately — not looped" do
      ghost = Ecto.UUID.generate()

      assert {:error, %Ecto.Changeset{}} =
               StudioChat.append_message(ghost, %{role: "user", source_markdown: "orphan"})
    end
  end

  describe "append_message/2 — denormalised bumps" do
    test "message_count, summary, and last_active_at track the latest message" do
      s = new_session()
      t0 = s.last_active_at

      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "first message"})
      s1 = StudioChat.get_session(s.id)
      assert s1.message_count == 1
      assert s1.summary == "first message"
      assert DateTime.compare(s1.last_active_at, t0) in [:gt, :eq]

      {:ok, _} =
        StudioChat.append_message(s, %{
          role: "assistant",
          source_markdown: "second   message\nwrapped"
        })

      s2 = StudioChat.get_session(s.id)
      assert s2.message_count == 2
      # whitespace collapsed for the sidebar preview
      assert s2.summary == "second message wrapped"
    end

    test "a long summary is truncated with an ellipsis" do
      s = new_session()
      long = String.duplicate("x", 500)
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: long})
      summary = StudioChat.get_session(s.id).summary
      assert String.length(summary) == 140
      assert String.ends_with?(summary, "…")
    end

    test "a nil/blank markdown message does not clobber an existing summary" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "keep me"})
      {:ok, _} = StudioChat.append_message(s, %{role: "system", source_markdown: nil})
      s2 = StudioChat.get_session(s.id)
      assert s2.summary == "keep me"
      assert s2.message_count == 2
    end

    test "tool ephemera bump activity but never own the summary" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "keep me"})

      {:ok, _} =
        StudioChat.append_message(s, %{role: "tool", source_markdown: "→ bash: ls -la"})

      s2 = StudioChat.get_session(s.id)
      assert s2.summary == "keep me"
      assert s2.message_count == 2
    end

    test "leading markdown furniture is stripped from the preview" do
      s = new_session()

      {:ok, _} =
        StudioChat.append_message(s, %{
          role: "assistant",
          source_markdown: "## Findings\n\nThe auth layer is sound."
        })

      assert StudioChat.get_session(s.id).summary == "Findings The auth layer is sound."
    end
  end

  describe "status lifecycle" do
    test "update_status transitions and mark_exited sets exited" do
      s = new_session()
      {:ok, working} = StudioChat.update_status(s.id, "working")
      assert working.status == "working"

      {:ok, exited} = StudioChat.mark_exited(s.id)
      assert exited.status == "exited"
      assert StudioChat.get_session(s.id).status == "exited"
    end

    test "an invalid status is rejected" do
      s = new_session()
      assert {:error, changeset} = StudioChat.update_status(s.id, "nope")
      assert %{status: _} = errors_on(changeset)
    end

    test "status ops on a missing session are honest" do
      assert {:error, :not_found} = StudioChat.update_status(Ecto.UUID.generate(), "working")
      assert :noop = StudioChat.mark_exited(Ecto.UUID.generate())
    end
  end

  describe "set_mode/2 — mid-session mode persistence (charter D17)" do
    test "persists a valid mode so a reopened session shows it" do
      s = new_session(%{mode: "plan"})
      assert s.mode == "plan"

      {:ok, switched} = StudioChat.set_mode(s.id, "acceptEdits")
      assert switched.mode == "acceptEdits"
      # a reopen reads the switched mode, not the creation mode
      assert StudioChat.get_session(s.id).mode == "acceptEdits"
    end

    test "an invalid mode is rejected (validate_inclusion)" do
      s = new_session(%{mode: "plan"})
      assert {:error, changeset} = StudioChat.set_mode(s.id, "bypassPermissions")
      assert %{mode: _} = errors_on(changeset)
      # the row is untouched
      assert StudioChat.get_session(s.id).mode == "plan"
    end

    test "set_mode on a missing session is honest" do
      assert {:error, :not_found} = StudioChat.set_mode(Ecto.UUID.generate(), "default")
    end
  end

  describe "titles — clobber guard (charter D13)" do
    test "AI title lands on a default title, then a human rename overrides it" do
      s = new_session()
      assert s.title_source == "default"

      {:ok, ai} = StudioChat.maybe_set_ai_title(s.id, "Refactor the auth layer")
      assert ai.title == "Refactor the auth layer"
      assert ai.title_source == "ai"

      # A late AI title cannot clobber a landed AI title either.
      assert :noop = StudioChat.maybe_set_ai_title(s.id, "Something else")

      {:ok, renamed} = StudioChat.rename(s.id, "My auth work")
      assert renamed.title == "My auth work"
      assert renamed.title_source == "human"
    end

    test "a human rename FIRST wins — a later AI title is a no-op" do
      s = new_session()
      {:ok, renamed} = StudioChat.rename(s.id, "Human chosen")
      assert renamed.title_source == "human"

      assert :noop = StudioChat.maybe_set_ai_title(s.id, "AI would have chosen this")

      after_ = StudioChat.get_session(s.id)
      assert after_.title == "Human chosen"
      assert after_.title_source == "human"
    end

    test "a blank AI title is refused and never touches the row" do
      s = new_session()
      assert {:error, :blank} = StudioChat.maybe_set_ai_title(s.id, "   ")
      assert {:error, :blank} = StudioChat.maybe_set_ai_title(s.id, "")
      assert StudioChat.get_session(s.id).title_source == "default"
    end

    test "AI title trims surrounding whitespace" do
      s = new_session()
      {:ok, ai} = StudioChat.maybe_set_ai_title(s.id, "  Tidy title  ")
      assert ai.title == "Tidy title"
    end

    test "an AI title against a missing session is a no-op" do
      assert :noop = StudioChat.maybe_set_ai_title(Ecto.UUID.generate(), "orphan")
    end
  end

  describe "record_result_metrics/2 — accumulation" do
    test "token + cost totals accumulate across turns, model-agnostic" do
      s = new_session()

      {:ok, _} =
        StudioChat.record_result_metrics(s.id, %{
          "usage" => %{"input_tokens" => 100, "output_tokens" => 20},
          "total_cost_usd" => 0.01
        })

      {:ok, s2} =
        StudioChat.record_result_metrics(s.id, %{
          input_tokens: 50,
          output_tokens: 10,
          total_cost_usd: 0.02
        })

      assert s2.input_tokens == 150
      assert s2.output_tokens == 30
      assert_in_delta s2.total_cost_usd, 0.03, 1.0e-9
    end

    test "absent keys count as zero without crashing" do
      s = new_session()
      {:ok, s2} = StudioChat.record_result_metrics(s.id, %{"total_cost_usd" => 0.005})
      assert s2.input_tokens == 0
      assert s2.output_tokens == 0
      assert_in_delta s2.total_cost_usd, 0.005, 1.0e-9
    end

    test "metrics against a missing session are honest" do
      assert {:error, :not_found} =
               StudioChat.record_result_metrics(Ecto.UUID.generate(), %{input_tokens: 1})
    end

    test "the answering model is tracked when the frame carries one" do
      s = new_session()

      {:ok, s2} =
        StudioChat.record_result_metrics(s.id, %{input_tokens: 1, model: "claude-opus-4"})

      assert s2.model == "claude-opus-4"

      # absent/blank model leaves the last one in place
      {:ok, s3} = StudioChat.record_result_metrics(s.id, %{input_tokens: 1})
      assert s3.model == "claude-opus-4"
    end
  end

  describe "record_result_metrics/2 — per-turn context snapshot (charter D19)" do
    test "last_context_tokens is SET (not summed) from the latest frame" do
      s = new_session()

      {:ok, s1} =
        StudioChat.record_result_metrics(s.id, %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 20,
            "cache_read_input_tokens" => 5000,
            "cache_creation_input_tokens" => 300
          }
        })

      # 100 + 5000 + 300 + 20 = 5420 (input + cache_read + cache_creation + output)
      assert s1.last_context_tokens == 5420

      # A SECOND turn REPLACES the snapshot — it never accumulates like the totals do.
      {:ok, s2} =
        StudioChat.record_result_metrics(s.id, %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
        })

      assert s2.last_context_tokens == 12
      # …while the lifetime input totals still sum across both turns.
      assert s2.input_tokens == 110
    end

    test "context_window is captured from the frame when present" do
      s = new_session()

      {:ok, s1} =
        StudioChat.record_result_metrics(s.id, %{input_tokens: 1, context_window: 200_000})

      assert s1.context_window == 200_000
    end

    test "a frame WITHOUT a window never clobbers a known one to unknown" do
      s = new_session()

      {:ok, _} =
        StudioChat.record_result_metrics(s.id, %{input_tokens: 1, context_window: 200_000})

      # Next turn's frame carries no window (e.g. a stripped/partial result) —
      # the last-known window must survive so the ring stays honest.
      {:ok, s2} = StudioChat.record_result_metrics(s.id, %{input_tokens: 2})
      assert s2.context_window == 200_000
    end

    test "a zero / garbage window is ignored (never invents an arc)" do
      s = new_session()
      {:ok, s1} = StudioChat.record_result_metrics(s.id, %{input_tokens: 1, context_window: 0})
      assert is_nil(s1.context_window)

      {:ok, s2} =
        StudioChat.record_result_metrics(s.id, %{input_tokens: 1, context_window: "nope"})

      assert is_nil(s2.context_window)
    end

    test "a fresh session with no result has nil snapshot columns" do
      s = new_session()
      assert is_nil(s.last_context_tokens)
      assert is_nil(s.context_window)
    end
  end

  describe "list_sessions/0 — sidebar" do
    test "returns sessions most-recently-active first" do
      old = new_session()
      # force old to be older
      {:ok, _} =
        StudioChat.update_status(old.id, "active")

      Process.sleep(2)
      recent = new_session()
      {:ok, _} = StudioChat.append_message(recent, %{role: "user", source_markdown: "ping"})

      # The sandbox isolates this test's data, so the full order is deterministic.
      ids = StudioChat.list_sessions() |> Enum.map(& &1.id)
      assert ids == [recent.id, old.id]
    end

    test "carries the denormalised fields the sidebar renders" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "hello world"})
      {:ok, _} = StudioChat.maybe_set_ai_title(s.id, "A titled chat")

      row = StudioChat.list_sessions() |> Enum.find(&(&1.id == s.id))
      assert row.title == "A titled chat"
      assert row.title_source == "ai"
      assert row.summary == "hello world"
      assert row.message_count == 1
    end
  end

  describe "lifecycle — delete + archive (wave 2)" do
    test "delete_session removes the row and cascades its messages" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "one"})
      {:ok, _} = StudioChat.append_message(s, %{role: "assistant", source_markdown: "two"})
      assert length(StudioChat.list_messages(s.id)) == 2

      assert {:ok, %Session{}} = StudioChat.delete_session(s.id)
      assert StudioChat.get_session(s.id) == nil
      # on_delete: :delete_all cascaded — no orphaned messages
      assert StudioChat.list_messages(s.id) == []
    end

    test "delete/archive/unarchive on a missing or non-UUID id are honest no-ops" do
      assert :noop = StudioChat.delete_session(Ecto.UUID.generate())
      assert :noop = StudioChat.delete_session("not-a-uuid")
      assert :noop = StudioChat.archive_session(Ecto.UUID.generate())
      assert :noop = StudioChat.unarchive_session("nope")
    end

    test "archive stamps archived_at; unarchive clears it — status is untouched" do
      s = new_session()
      {:ok, _} = StudioChat.update_status(s.id, "working")

      {:ok, archived} = StudioChat.archive_session(s.id)
      assert archived.archived_at != nil
      # archive is orthogonal to liveness: status survives
      assert archived.status == "working"

      {:ok, unarchived} = StudioChat.unarchive_session(s.id)
      assert unarchived.archived_at == nil
      assert unarchived.status == "working"
    end
  end

  describe "list_sessions/1 — archived filter + cap (wave 2)" do
    test "the default list excludes archived; archived: true lists only the shelf" do
      live = new_session()
      shelved = new_session()
      {:ok, _} = StudioChat.archive_session(shelved.id)

      default_ids = StudioChat.list_sessions() |> Enum.map(& &1.id)
      assert live.id in default_ids
      refute shelved.id in default_ids

      archived_ids = StudioChat.list_sessions(archived: true) |> Enum.map(& &1.id)
      assert shelved.id in archived_ids
      refute live.id in archived_ids
    end

    test "the active list is capped at 50, recency-desc keeping the freshest on top" do
      # 55 sessions, staggered last_active_at so the order is deterministic
      for i <- 1..55 do
        id = Ecto.UUID.generate()

        {:ok, _} =
          StudioChat.create_session(%{
            id: id,
            last_active_at: DateTime.add(~U[2026-07-01 00:00:00.000000Z], i, :minute)
          })
      end

      rows = StudioChat.list_sessions()
      assert length(rows) == 50
      # recency-desc: the freshest (minute 55) leads; the 6 oldest fall off
      assert hd(rows).last_active_at == DateTime.add(~U[2026-07-01 00:00:00.000000Z], 55, :minute)
    end

    test "the sidebar projection carries archived_at" do
      s = new_session()
      {:ok, _} = StudioChat.archive_session(s.id)
      row = StudioChat.list_sessions(archived: true) |> Enum.find(&(&1.id == s.id))
      assert row.archived_at != nil
    end
  end

  describe "approvals — persisted lifecycle + denormalised pending count" do
    defp ask(session, request_id) do
      {:ok, m} =
        StudioChat.append_message(session, %{
          role: "approval",
          source_markdown: "Allow Write /opt/x?",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => "Write",
            "input" => %{"file_path" => "/opt/x"},
            "approval_status" => "pending"
          }
        })

      m
    end

    defp reload(id), do: StudioChat.get_session(id)

    test "appending an approval bumps pending_approvals; the sidebar carries it" do
      s = new_session()
      assert reload(s.id).pending_approvals == 0

      ask(s, "req-1")
      ask(s, "req-2")

      assert reload(s.id).pending_approvals == 2
      row = StudioChat.list_sessions() |> Enum.find(&(&1.id == s.id))
      assert row.pending_approvals == 2
    end

    test "resolving flips the row's metadata and decrements the pending count" do
      s = new_session()
      ask(s, "req-1")
      ask(s, "req-2")

      assert {:ok, m} = StudioChat.update_approval_status(s.id, "req-1", "allowed")
      assert m.metadata["approval_status"] == "allowed"
      assert reload(s.id).pending_approvals == 1

      assert {:ok, _} = StudioChat.update_approval_status(s.id, "req-2", "denied")
      assert reload(s.id).pending_approvals == 0
    end

    test "resolving a resolved approval again does NOT underflow the counter" do
      s = new_session()
      ask(s, "req-1")
      {:ok, _} = StudioChat.update_approval_status(s.id, "req-1", "allowed")
      assert reload(s.id).pending_approvals == 0

      # a duplicate/racy resolve must never drive the count negative
      {:ok, _} = StudioChat.update_approval_status(s.id, "req-1", "denied")
      assert reload(s.id).pending_approvals == 0
    end

    test "an unknown request_id is a clean not_found (never a crash)" do
      s = new_session()
      assert {:error, :not_found} = StudioChat.update_approval_status(s.id, "nope", "allowed")
    end

    test "an unknown terminal status is rejected without touching the row" do
      s = new_session()
      ask(s, "req-1")
      assert {:error, :bad_status} = StudioChat.update_approval_status(s.id, "req-1", "maybe")
      # untouched — still pending, still counted
      assert reload(s.id).pending_approvals == 1
    end

    test "cancel_pending_approvals flips every pending row to canceled and zeroes the count" do
      s = new_session()
      ask(s, "req-1")
      ask(s, "req-2")
      {:ok, _} = StudioChat.update_approval_status(s.id, "req-1", "allowed")
      # one already resolved, one still pending
      assert reload(s.id).pending_approvals == 1

      assert 1 == StudioChat.cancel_pending_approvals(s.id)
      assert reload(s.id).pending_approvals == 0

      statuses =
        StudioChat.list_messages(s.id)
        |> Enum.filter(&(&1.role == "approval"))
        |> Enum.map(& &1.metadata["approval_status"])
        |> Enum.sort()

      # the resolved one is untouched; only the dangling one becomes canceled
      assert statuses == ["allowed", "canceled"]
    end

    test "cancel_pending_approvals on a session with none is a harmless zero" do
      s = new_session()
      assert 0 == StudioChat.cancel_pending_approvals(s.id)
      assert reload(s.id).pending_approvals == 0
    end
  end

  describe "schema wiring" do
    test "known statuses, title sources, and modes are enumerable" do
      assert "working" in Session.statuses()
      assert "human" in Session.title_sources()
      assert "acceptEdits" in Session.modes()
    end

    test "messages preload in seq order via the association" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "one"})
      {:ok, _} = StudioChat.append_message(s, %{role: "assistant", source_markdown: "two"})

      loaded = StudioChat.get_session_with_messages(s.id)
      assert Enum.map(loaded.messages, & &1.role) == ["user", "assistant"]
      assert %Message{} = hd(loaded.messages)
    end
  end
end
