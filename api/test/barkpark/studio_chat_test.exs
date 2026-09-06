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

  `async: false` — REQUIRED by the "image attachments" describe below, which
  does `Application.put_env(:barkpark, StudioChat, attachments_dir: …)` in its
  setup. Application env is PROCESS-GLOBAL VM state (the SQL sandbox isolates the
  DB, not the env). `StudioChat.attachments_dir/0` reads that same key at
  runtime, so a concurrent async test writing/reading attachments would observe
  this module's mutation and race its `on_exit` restore — an order-dependent
  flake (the solved sandbox-ownership scar shape). The only other reader is
  `chat_live_test.exs`, itself async:false — the leak is latent, not absent.
  Serial execution is the correct fix; the traded parallelism is worth the
  correctness.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Message, Session}

  defp new_session(attrs \\ %{}) do
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    {:ok, session} = StudioChat.create_session(Map.put(attrs, :id, id))
    session
  end

  # A fresh workspace id — no FK on owner_workspace_id (greenfield/additive
  # migration), so a bare generated UUID is a legitimate owner for the store
  # tenant-seam tests below.
  defp ws, do: Ecto.UUID.generate()

  # A session owned under `scope` (`:global | {:workspace, ws} | ws`).
  defp owned_session(scope) do
    id = Ecto.UUID.generate()
    {:ok, s} = StudioChat.create_session(%{id: id, cwd: "/tmp/x"}, scope)
    s
  end

  # ── Wave-26 leaked-session pollution guard (felix-w27-s6) ────────────────────
  #
  # The StudioChat Recorder is an app-tree GenServer (RuntimeSupervisor) that can
  # outlive a prior test's sandbox owner and COMMIT chat_sessions rows which then
  # escape that test's transaction rollback. Those committed rows ride
  # `list_sessions/*`'s recency-desc ordering AHEAD of this file's freshly-seeded
  # rows, reddening the cap / recency / archived-filter assertions on a SHIFTING,
  # order-dependent set (refuted as a prod defect in the wave-26 review, real as
  # suite pollution). At setup — before any test here has created a single session
  # — every visible `chat_sessions` row is such a leak, so purge them for a clean
  # baseline. Restrict-FK children (`chat_runtime_usage_receipts`,
  # `epic_assignment_runtime_attempts`) are cleared first; deleting the sessions
  # then cascades the on_delete:delete_all children (messages, telemetry, leases).
  # The purge runs inside this test's sandbox transaction and rolls back with it —
  # test-infra hygiene only, ZERO prod code touched.
  setup do
    purge_leaked_chat_sessions!()
    :ok
  end

  defp purge_leaked_chat_sessions! do
    Repo.query!("DELETE FROM chat_runtime_usage_receipts")
    Repo.query!("DELETE FROM epic_assignment_runtime_attempts")
    Repo.delete_all(Session)
    :ok
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

  describe "update_tool_input/3 — living-checklist collapse (charter D39)" do
    test "replaces metadata.input on the row matched by tool_use_id" do
      s = new_session()

      {:ok, _} =
        StudioChat.append_message(s, %{
          role: "todo",
          source_markdown: "Update todos",
          metadata: %{"tool_use_id" => "tu_1", "input" => %{"todos" => [%{"a" => 1}]}}
        })

      new_input = %{"todos" => [%{"content" => "x", "status" => "completed"}]}
      assert {:ok, _} = StudioChat.update_tool_input(s.id, "tu_1", new_input)

      row = StudioChat.list_messages(s.id) |> Enum.find(&(&1.role == "todo"))
      assert row.metadata["input"] == new_input
    end

    test "an unknown tool_use_id is a safe :noop" do
      s = new_session()
      assert :noop = StudioChat.update_tool_input(s.id, "ghost", %{"todos" => []})
    end
  end

  describe "todo_shaped?/1 — shape dispatch (charter D39)" do
    test "true for a non-empty todos list of content+status maps (modern + legacy)" do
      assert StudioChat.todo_shaped?(%{
               "todos" => [%{"content" => "a", "status" => "pending", "activeForm" => "doing a"}]
             })

      assert StudioChat.todo_shaped?(%{
               "todos" => [
                 %{"content" => "a", "status" => "completed", "priority" => "high", "id" => "1"}
               ]
             })
    end

    test "false for empty list, missing keys, or a non-todo tool input" do
      refute StudioChat.todo_shaped?(%{"todos" => []})
      refute StudioChat.todo_shaped?(%{"todos" => [%{"content" => "a"}]})
      refute StudioChat.todo_shaped?(%{"command" => "ls"})
      refute StudioChat.todo_shaped?(nil)
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
      # A genuinely-invalid string — bypassPermissions is now a LEGAL persisted
      # mode (the armed ceremony writes it), so it can no longer stand in for the
      # invalid example (charter D48).
      assert {:error, changeset} = StudioChat.set_mode(s.id, "wideOpen")
      assert %{mode: _} = errors_on(changeset)
      # the row is untouched
      assert StudioChat.get_session(s.id).mode == "plan"
    end

    test "bypassPermissions IS a legal persisted mode (armed-ceremony write)" do
      s = new_session(%{mode: "plan"})
      # The store validates inclusion so the armed ceremony can persist bypass;
      # the FAIL-CLOSED guard is upstream (ClaudeChat.normalize_mode never yields
      # it), not here.
      assert {:ok, switched} = StudioChat.set_mode(s.id, "bypassPermissions")
      assert switched.mode == "bypassPermissions"
      assert StudioChat.bypass_armed?(s.id)
    end

    test "set_mode on a missing session is honest" do
      assert {:error, :not_found} = StudioChat.set_mode(Ecto.UUID.generate(), "default")
    end
  end

  describe "set_cloud_sandbox_id/2 — session-scoped Cloud sandbox binding (charter D137/D139)" do
    test "SETS, OVERWRITES, and CLEARS — deliberately NOT write-once" do
      s = new_session()
      assert s.cloud_sandbox_id == nil

      # SET
      {:ok, bound} = StudioChat.set_cloud_sandbox_id(s.id, "sbx-alpha")
      assert bound.cloud_sandbox_id == "sbx-alpha"
      assert StudioChat.get_session(s.id).cloud_sandbox_id == "sbx-alpha"

      # OVERWRITE — a fresh sandbox after an expiry re-binds (this is the exact
      # departure from write-once provider_session_id below).
      {:ok, rebound} = StudioChat.set_cloud_sandbox_id(s.id, "sbx-beta")
      assert rebound.cloud_sandbox_id == "sbx-beta"
      assert StudioChat.get_session(s.id).cloud_sandbox_id == "sbx-beta"

      # CLEAR — nil is a legal transition (expiry with no replacement yet, D139).
      {:ok, cleared} = StudioChat.set_cloud_sandbox_id(s.id, nil)
      assert cleared.cloud_sandbox_id == nil
      assert StudioChat.get_session(s.id).cloud_sandbox_id == nil
    end

    test "CONTRASTS with write-once set_provider_session_id/2 (which refuses overwrite)" do
      s = new_session()

      # A managed session's provider identity is stamped to its own UUID at create
      # and is WRITE-ONCE: a different value is rejected, the row is untouched.
      assert s.provider_session_id == s.id
      assert {:error, :immutable} = StudioChat.set_provider_session_id(s.id, "native-2")
      assert StudioChat.get_session(s.id).provider_session_id == s.id

      # The sandbox binding is NOT — the same double-set succeeds and moves the id.
      {:ok, _} = StudioChat.set_cloud_sandbox_id(s.id, "sbx-1")
      assert {:ok, moved} = StudioChat.set_cloud_sandbox_id(s.id, "sbx-2")
      assert moved.cloud_sandbox_id == "sbx-2"
    end

    test "a blank id trips the non-empty DB check (never a fake binding)" do
      s = new_session()
      assert {:error, changeset} = StudioChat.set_cloud_sandbox_id(s.id, "   ")
      assert %{cloud_sandbox_id: _} = errors_on(changeset)
      assert StudioChat.get_session(s.id).cloud_sandbox_id == nil
    end

    test "set on a missing session is honest" do
      assert {:error, :not_found} =
               StudioChat.set_cloud_sandbox_id(Ecto.UUID.generate(), "sbx-x")
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

    test "delete_session with a RESTRICT runtime ledger returns {:error, changeset}, never a crash" do
      s = new_session()

      # A managed-codex session that recorded a runtime usage receipt: its
      # session_id FK is on_delete: :restrict (migration 20260715000900), so the
      # session cannot be hard-deleted while the ledger row lives. Seed one
      # directly — the receipt table is append-only (the immutability trigger
      # blocks UPDATE/DELETE, not INSERT), and task_id needs a real document.
      task_doc =
        Barkpark.Repo.insert!(%Barkpark.Content.Document{
          doc_id: "sc-restrict-#{System.unique_integer([:positive])}",
          type: "task",
          title: "restrict guard task",
          status: "published",
          content: %{},
          rev: Ecto.UUID.generate()
        })

      {1, _} =
        Barkpark.Repo.insert_all(Barkpark.StudioChat.RuntimeUsage.Receipt, [
          %{
            id: Ecto.UUID.generate(),
            cycle_id: Ecto.UUID.generate(),
            assignment_id: Ecto.UUID.generate(),
            session_id: s.id,
            task_id: task_doc.id,
            task_doc_id: "sc-restrict-task",
            task_worker_id: "worker-1",
            task_epoch: 1,
            task_work_digest: "0123456789abcdef",
            provider: "codex",
            provider_session_id: "thread-1",
            turn_id: "turn-1",
            boundary: "baseline",
            observation_state: "observed",
            counter_domain: "tokens",
            counters: %{},
            payload_hash: String.duplicate("a", 64),
            inserted_at: DateTime.utc_now()
          }
        ])

      # Mapped to a changeset error — never an unhandled Ecto.ConstraintError
      # crashing the admin LiveView. Mutation: strip the foreign_key_constraint
      # mapping in delete_session/2 → Repo.delete raises → this assert fails.
      assert {:error, %Ecto.Changeset{} = cs} = StudioChat.delete_session(s.id)

      assert {"has recorded runtime usage receipts and cannot be deleted", _} =
               cs.errors[:id]

      # A failed delete leaves the session intact — a bounded, recoverable outcome.
      assert StudioChat.get_session(s.id) != nil
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

  describe "image attachments — chat-owned file store (wave 3, charter D25)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bp_sc_attach_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:barkpark, StudioChat)
      Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

      on_exit(fn ->
        File.rm_rf(dir)
        if prev, do: Application.put_env(:barkpark, StudioChat, prev)
      end)

      {:ok, dir: dir}
    end

    test "store_attachment writes bytes under <dir>/<session>/<sha256> and returns a pointer",
         %{dir: dir} do
      s = new_session()
      bytes = "the-png-bytes"
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      assert {:ok, pointer} = StudioChat.store_attachment(s.id, bytes, "image/png")
      assert pointer.path == Path.join(s.id, sha)
      assert pointer.media_type == "image/png"
      assert pointer.sha256 == sha
      assert pointer.byte_size == byte_size(bytes)

      # bytes really live on disk under the content-addressed path
      assert File.read!(Path.join(dir, pointer.path)) == bytes
    end

    test "read_attachment round-trips by relative pointer; a missing/traversal path is honest" do
      s = new_session()
      {:ok, pointer} = StudioChat.store_attachment(s.id, "abc", "image/jpeg")

      assert {:ok, "abc"} = StudioChat.read_attachment(pointer.path)
      assert {:error, :missing} = StudioChat.read_attachment("#{s.id}/deadbeef")
      assert {:error, :missing} = StudioChat.read_attachment("../../etc/passwd")
      assert {:error, :missing} = StudioChat.read_attachment(nil)
    end

    test "jpg normalizes to image/jpeg; an unknown type falls back to image/png" do
      s = new_session()
      {:ok, a} = StudioChat.store_attachment(s.id, "x", "image/jpg")
      {:ok, b} = StudioChat.store_attachment(s.id, "y", "application/pdf")
      assert a.media_type == "image/jpeg"
      assert b.media_type == "image/png"
    end

    test "delete_session removes the session's attachment dir (files never outlive the row)",
         %{dir: dir} do
      s = new_session()
      {:ok, pointer} = StudioChat.store_attachment(s.id, "img", "image/png")
      session_dir = Path.join(dir, s.id)
      assert File.exists?(Path.join(dir, pointer.path))
      assert File.dir?(session_dir)

      assert {:ok, %Session{}} = StudioChat.delete_session(s.id)
      refute File.exists?(session_dir)
    end

    test "delete_session on a session with no attachments is a clean success" do
      s = new_session()
      assert {:ok, %Session{}} = StudioChat.delete_session(s.id)
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

    test "a terminal approval is immutable and a duplicate resolve does not decrement again" do
      s = new_session()
      ask(s, "req-1")
      assert {:ok, allowed} = StudioChat.update_approval_status(s.id, "req-1", "allowed")
      assert allowed.metadata["approval_status"] == "allowed"
      assert reload(s.id).pending_approvals == 0

      # A duplicate/opposite answer is a no-op: terminal truth never flips and
      # the denormalised counter is decremented exactly once.
      assert {:error, :not_found} =
               StudioChat.update_approval_status(s.id, "req-1", "denied")

      [persisted] = StudioChat.list_messages(s.id)
      assert persisted.metadata["approval_status"] == "allowed"
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

    # Charter D31 — the needs-you role set (approval | question | plan) is ONE
    # counter. Every seam that gates on a pending ask must treat all three
    # identically, or the sidebar pill / cancel / resolve lie for questions.
    defp ask_role(session, request_id, role) do
      {:ok, m} =
        StudioChat.append_message(session, %{
          role: role,
          source_markdown: "ask #{request_id}",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => role,
            "input" => %{},
            "approval_status" => "pending"
          }
        })

      m
    end

    test "question and plan asks BOTH raise the one pending counter (D31)" do
      s = new_session()
      ask_role(s, "q-1", "question")
      ask_role(s, "p-1", "plan")
      ask_role(s, "a-1", "approval")

      assert reload(s.id).pending_approvals == 3
    end

    test "a question ask resolves + decrements exactly like an approval (D31)" do
      s = new_session()
      ask_role(s, "q-1", "question")
      assert reload(s.id).pending_approvals == 1

      assert {:ok, m} = StudioChat.update_approval_status(s.id, "q-1", "allowed")
      assert m.metadata["approval_status"] == "allowed"
      assert reload(s.id).pending_approvals == 0
    end

    test "cancel_pending_approvals cancels question AND plan rows too (D31)" do
      s = new_session()
      ask_role(s, "q-1", "question")
      ask_role(s, "p-1", "plan")
      ask_role(s, "a-1", "approval")
      assert reload(s.id).pending_approvals == 3

      assert 3 == StudioChat.cancel_pending_approvals(s.id)
      assert reload(s.id).pending_approvals == 0

      statuses =
        StudioChat.list_messages(s.id)
        |> Enum.filter(&(&1.role in ~w(approval question plan)))
        |> Enum.map(& &1.metadata["approval_status"])
        |> Enum.uniq()

      assert statuses == ["canceled"]
    end
  end

  # Charter D49 — the plan-paper stamp seam. A request_id-keyed metadata merge
  # onto a needs-you (plan) row, distinct from update_approval_status (which
  # writes ONLY approval_status) and merge_tool_metadata (keyed on tool_use_id,
  # which plan rows lack). The publishing Task stamps {paper_id, paper_url} here
  # so a reopened plan card links to its Paper forever.
  describe "merge_approval_metadata/3 (D49)" do
    defp plan_ask(session, request_id) do
      {:ok, m} =
        StudioChat.append_message(session, %{
          role: "plan",
          source_markdown: "# The plan\n\nDo it.",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => "ExitPlanMode",
            "input" => %{"plan" => "# The plan\n\nDo it."},
            "approval_status" => "allowed"
          }
        })

      m
    end

    test "merges the patch WITHOUT clobbering the row's existing metadata keys" do
      s = new_session()
      plan_ask(s, "p-1")

      assert {:ok, m} =
               StudioChat.merge_approval_metadata(s.id, "p-1", %{
                 "paper_id" => "chat-plan-abc",
                 "paper_url" => "/papers/chat-plan-abc"
               })

      # the new keys landed…
      assert m.metadata["paper_id"] == "chat-plan-abc"
      assert m.metadata["paper_url"] == "/papers/chat-plan-abc"
      # …and every pre-existing key is preserved (request_id, tool_name, input,
      # approval_status all survive the merge)
      assert m.metadata["request_id"] == "p-1"
      assert m.metadata["tool_name"] == "ExitPlanMode"
      assert m.metadata["approval_status"] == "allowed"
      assert m.metadata["input"] == %{"plan" => "# The plan\n\nDo it."}
    end

    test "a later merge overwrites only its own keys, keeping earlier stamps" do
      s = new_session()
      plan_ask(s, "p-2")

      {:ok, _} = StudioChat.merge_approval_metadata(s.id, "p-2", %{"paper_id" => "chat-plan-1"})

      {:ok, m} =
        StudioChat.merge_approval_metadata(s.id, "p-2", %{"paper_url" => "/papers/chat-plan-1"})

      assert m.metadata["paper_id"] == "chat-plan-1"
      assert m.metadata["paper_url"] == "/papers/chat-plan-1"
    end

    test "an unmatched request_id is a clean :noop, never a raise" do
      s = new_session()
      assert :noop == StudioChat.merge_approval_metadata(s.id, "nope", %{"paper_id" => "x"})
    end
  end

  # The durable half of the settle-gated tool-row gutter
  # (task-d5083ae525902f28). `settle_tool_rows/1` is what makes the ✓/✗ survive
  # a reopen — and what the Go TUI reads, since `message_json` ships the row's
  # metadata verbatim. It is deliberately STATELESS (settle every unsettled tool
  # row of the session), so a Recorder restart mid-turn cannot strand a row.
  describe "settle_tool_rows/1 + attach_tool_result/4 (settle-gated gutter)" do
    defp tool_row(session, tool_use_id) do
      {:ok, m} =
        StudioChat.append_message(session, %{
          role: "tool",
          source_markdown: "Bash — #{tool_use_id}",
          metadata: %{"tool" => "Bash", "tool_use_id" => tool_use_id, "input" => %{}}
        })

      m
    end

    defp meta_for(session_id, tool_use_id) do
      StudioChat.list_messages(session_id)
      |> Enum.find(&(&1.metadata["tool_use_id"] == tool_use_id))
      |> Map.fetch!(:metadata)
    end

    test "a fresh tool row is UNSETTLED — the key is absent, not false" do
      s = new_session()
      tool_row(s, "t-fresh")

      # Absence is the honest unsettled reading: no migration, and an older row
      # written before this seam existed replays neutral rather than lying.
      refute Map.has_key?(meta_for(s.id, "t-fresh"), "turn_settled")
    end

    test "settle_tool_rows stamps every unsettled tool row and is idempotent" do
      s = new_session()
      tool_row(s, "t-a")
      tool_row(s, "t-b")

      assert 2 == StudioChat.settle_tool_rows(s.id)
      assert meta_for(s.id, "t-a")["turn_settled"] == true
      assert meta_for(s.id, "t-b")["turn_settled"] == true

      # A second result frame writes ZERO rows — the WHERE excludes settled rows,
      # so a long settled history costs nothing per turn.
      assert 0 == StudioChat.settle_tool_rows(s.id)
    end

    test "the settle MERGES — it never clobbers output/tool_error/input" do
      s = new_session()
      tool_row(s, "t-merge")
      {:ok, _} = StudioChat.attach_tool_result(s.id, "t-merge", "the output", true)

      assert 1 == StudioChat.settle_tool_rows(s.id)

      meta = meta_for(s.id, "t-merge")
      assert meta["turn_settled"] == true
      assert meta["output"] == "the output"
      assert meta["tool_error"] == true
      assert meta["tool"] == "Bash"
      assert meta["input"] == %{}
    end

    test "attach_tool_result writes tool_error ONLY for an is_error result" do
      s = new_session()
      tool_row(s, "t-ok")
      {:ok, _} = StudioChat.attach_tool_result(s.id, "t-ok", "fine")

      meta = meta_for(s.id, "t-ok")
      assert meta["output"] == "fine"
      # a clean result leaves the row's metadata byte-identical to before the
      # seam existed — no "tool_error" => false noise on every row in the store.
      refute Map.has_key?(meta, "tool_error")
    end

    test "settle_tool_rows touches ONLY this session's tool rows" do
      s = new_session()
      other = new_session()
      tool_row(s, "t-mine")
      tool_row(other, "t-theirs")

      {:ok, _} =
        StudioChat.append_message(s, %{role: "assistant", source_markdown: "not a tool row"})

      assert 1 == StudioChat.settle_tool_rows(s.id)
      refute Map.has_key?(meta_for(other.id, "t-theirs"), "turn_settled")
    end
  end

  describe "set_draft/2 — sticky composer draft (charter D36c)" do
    test "persists and restores a draft on the FULL struct" do
      s = new_session()
      {:ok, _} = StudioChat.set_draft(s.id, "half a thought")

      # get_session carries `draft` (the reopen restore path reads it here).
      assert StudioChat.get_session(s.id).draft == "half a thought"
    end

    test "list_sessions never selects the draft column (kept off the sidebar)" do
      s = new_session()
      {:ok, _} = StudioChat.set_draft(s.id, "sidebar must not carry this")

      # The select omits :draft, so a listed row reads the struct default (nil).
      listed = Enum.find(StudioChat.list_sessions(), &(&1.id == s.id))
      assert listed.draft == nil
    end

    test "a blank / whitespace draft clears the column (nil, not \"\")" do
      s = new_session()
      {:ok, _} = StudioChat.set_draft(s.id, "something")
      {:ok, _} = StudioChat.set_draft(s.id, "   ")
      assert StudioChat.get_session(s.id).draft == nil

      {:ok, _} = StudioChat.set_draft(s.id, "again")
      {:ok, _} = StudioChat.set_draft(s.id, nil)
      assert StudioChat.get_session(s.id).draft == nil
    end

    test "does NOT bump last_active_at (a draft must not reorder the sidebar)" do
      s = new_session()
      before = StudioChat.get_session(s.id).last_active_at
      {:ok, _} = StudioChat.set_draft(s.id, "typing…")
      assert StudioChat.get_session(s.id).last_active_at == before
    end

    test "a missing session is a clean :not_found" do
      assert {:error, :not_found} = StudioChat.set_draft(Ecto.UUID.generate(), "x")
    end
  end

  describe "recent_model_choice/0 — sticky model default seed (charter D36d)" do
    test "returns the most-recently-active NON-default model_choice" do
      older = new_session()
      {:ok, _} = StudioChat.set_model_choice(older.id, "haiku")
      # older's set_model_choice bumped last_active_at; make newer strictly later
      newer = new_session()
      {:ok, _} = StudioChat.set_model_choice(newer.id, "opus")

      assert StudioChat.recent_model_choice() == "opus"
    end

    test "ignores nil and literal \"default\" choices (never seeds \"default\")" do
      a = new_session()
      {:ok, _} = StudioChat.set_model_choice(a.id, "sonnet")
      b = new_session()
      {:ok, _} = StudioChat.set_model_choice(b.id, "default")

      # b is newer but its choice is "default" — the seed skips it.
      assert StudioChat.recent_model_choice() == "sonnet"
    end

    test "nil when no session ever picked a non-default model" do
      _ = new_session()
      assert StudioChat.recent_model_choice() == nil
    end
  end

  describe "effort_choice — the exact mirror of model_choice (charter D48)" do
    test "set_effort_choice persists the tier and is read back on reopen" do
      s = new_session()
      {:ok, updated} = StudioChat.set_effort_choice(s.id, "high")
      assert updated.effort_choice == "high"
      assert StudioChat.get_session(s.id).effort_choice == "high"
    end

    test "set_effort_choice on a missing session is honest" do
      assert {:error, :not_found} = StudioChat.set_effort_choice(Ecto.UUID.generate(), "high")
    end

    test "recent_effort_choice returns the most-recently-active NON-default tier" do
      older = new_session()
      {:ok, _} = StudioChat.set_effort_choice(older.id, "low")
      newer = new_session()
      {:ok, _} = StudioChat.set_effort_choice(newer.id, "xhigh")

      assert StudioChat.recent_effort_choice() == "xhigh"
    end

    test "recent_effort_choice ignores nil and literal \"default\"" do
      a = new_session()
      {:ok, _} = StudioChat.set_effort_choice(a.id, "medium")
      b = new_session()
      {:ok, _} = StudioChat.set_effort_choice(b.id, "default")

      assert StudioChat.recent_effort_choice() == "medium"
    end

    test "nil when no session ever picked an effort tier" do
      _ = new_session()
      assert StudioChat.recent_effort_choice() == nil
    end

    test "list_sessions never selects effort_choice (dedicated-query law)" do
      s = new_session()
      {:ok, _} = StudioChat.set_effort_choice(s.id, "high")
      # The sidebar select omits :effort_choice — a listed row reads the struct
      # default (nil), which is exactly why recent_effort_choice/0 is dedicated.
      listed = Enum.find(StudioChat.list_sessions(), &(&1.id == s.id))
      assert listed.effort_choice == nil
    end
  end

  describe "bypass_armed?/1 — persisted-mode gate (charter D48)" do
    test "true only when the PERSISTED mode is bypassPermissions" do
      s = new_session(%{mode: "plan"})
      refute StudioChat.bypass_armed?(s.id)

      {:ok, _} = StudioChat.set_mode(s.id, "bypassPermissions")
      assert StudioChat.bypass_armed?(s.id)
    end

    test "false (fail-closed) for a missing session" do
      refute StudioChat.bypass_armed?(Ecto.UUID.generate())
      refute StudioChat.bypass_armed?(nil)
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

  describe "agents rail: signature + pure folds (charter D47)" do
    test "rail_apply_codex_item exposes native Codex subagent lifecycle" do
      item = %{
        "type" => "collabAgentToolCall",
        "tool" => "spawn_agent",
        "prompt" => "Review the provider boundary",
        "model" => "gpt-5.6-sol",
        "receiverThreadIds" => ["thread-child-1"],
        "status" => "inProgress"
      }

      rail = StudioChat.rail_apply_codex_item(%{}, item, :started)
      assert rail["thread-child-1"]["status"] == "running"
      assert rail["thread-child-1"]["row"]["description"] == "Review the provider boundary"

      completed =
        StudioChat.rail_apply_codex_item(rail, %{item | "status" => "completed"}, :completed)

      assert completed["thread-child-1"]["status"] == "completed"
    end

    test "set_rail_snapshot round-trips the jsonb column and get_session carries it" do
      s = new_session()
      rail = %{"t" => %{"row" => %{"description" => "run"}, "status" => "running"}}
      {:ok, _} = StudioChat.set_rail_snapshot(s.id, rail)
      assert StudioChat.get_session(s.id).rail_snapshot == rail
    end

    test "rail_signature ignores token/usage churn but reflects structure + state" do
      base = %{
        "t" => %{
          "row" => %{"task_type" => "local_workflow", "description" => "run"},
          "status" => "running",
          "workflow" => [
            %{
              "type" => "workflow_agent",
              "label" => "explorer",
              "state" => "running",
              "tokens" => 10
            }
          ]
        }
      }

      # only tokens + usage advanced ⇒ SAME signature (change-only guard)
      token_tick =
        put_in(base, ["t", "workflow"], [
          %{
            "type" => "workflow_agent",
            "label" => "explorer",
            "state" => "running",
            "tokens" => 9_000
          }
        ])
        |> put_in(["t", "usage"], %{"total_tokens" => 9_000})

      assert StudioChat.rail_signature(base) == StudioChat.rail_signature(token_tick)

      # a STATE flip ⇒ different signature
      state_flip = put_in(base, ["t", "status"], "completed")
      refute StudioChat.rail_signature(base) == StudioChat.rail_signature(state_flip)

      # a NEW row ⇒ different signature
      row_added =
        Map.put(base, "u", %{"row" => %{"description" => "another"}, "status" => "running"})

      refute StudioChat.rail_signature(base) == StudioChat.rail_signature(row_added)
    end

    # wsc-ad D26 (LOAD-BEARING): the per-agent detail fields the drill-down renders
    # MUST ride the signature — else a detail-only frame (a new tool line, a settled
    # result) yields an EQUAL term, the change-only guard swallows it, and the live
    # pane FREEZES + the frame is never persisted. Before this slice the strip kept
    # only [type,title,label,phaseIndex,model,state]; a lastToolName/resultPreview/
    # attempt/promptPreview change was INVISIBLE to the signature. This proves each
    # of those now MOVES it — while lastProgressAt/tokens (heartbeat churn) still do
    # NOT (the accepted D13 ceiling: the NOW age refreshes only on a real change).
    test "rail_signature reflects per-agent DETAIL deltas (wsc-ad D26) but still ignores heartbeat churn" do
      base = %{
        "t" => %{
          "row" => %{"task_type" => "local_workflow", "description" => "run"},
          "status" => "running",
          "workflow" => [
            %{
              "type" => "workflow_agent",
              "agentId" => "a1",
              "label" => "explorer",
              "state" => "start",
              "lastToolName" => "Read",
              "lastToolSummary" => "reading auth.ex",
              "attempt" => 1,
              "promptPreview" => "You are the explorer…",
              "tokens" => 10,
              "lastProgressAt" => 1000
            }
          ]
        }
      }

      detail_delta = fn key, value ->
        put_in(base, ["t", "workflow", Access.at(0), key], value)
      end

      # each detail field the drill-down renders MOVES the signature
      for {key, value} <- [
            {"lastToolName", "StructuredOutput"},
            {"lastToolSummary", "wrote the finding"},
            {"resultPreview", "the leak was in query_controller"},
            {"attempt", 2},
            {"promptPreview", "You are the explorer, now revised…"}
          ] do
        refute StudioChat.rail_signature(base) ==
                 StudioChat.rail_signature(detail_delta.(key, value)),
               "a #{key} delta did NOT move rail_signature — the live pane would freeze (D26)"
      end

      # …but a pure heartbeat tick (progress time / token churn) still does NOT —
      # the change-only guard is intact, so the hot loop stays render-on-change.
      heartbeat =
        base
        |> put_in(["t", "workflow", Access.at(0), "lastProgressAt"], 9_999_999)
        |> put_in(["t", "workflow", Access.at(0), "tokens"], 500_000)

      assert StudioChat.rail_signature(base) == StudioChat.rail_signature(heartbeat)
    end

    test "rail_apply_background upserts live rows and completes the vanished" do
      rail =
        StudioChat.rail_apply_background(%{}, %{
          "tasks" => [
            %{"task_id" => "a", "task_type" => "local_workflow", "description" => "one"},
            %{"task_id" => "b", "task_type" => "local_workflow", "description" => "two"}
          ]
        })

      assert rail["a"]["status"] == "running"
      assert rail["b"]["status"] == "running"
      assert rail["a"]["workflow"] == []
      assert Map.has_key?(rail["a"], "usage")
      assert rail["a"]["usage"] == nil

      # "a" drops from the snapshot ⇒ completed; entries are never deleted
      rail2 =
        StudioChat.rail_apply_background(rail, %{
          "tasks" => [
            %{"task_id" => "b", "task_type" => "local_workflow", "description" => "two"}
          ]
        })

      assert rail2["a"]["status"] == "completed"
      assert rail2["b"]["status"] == "running"
    end

    test "local workflow background rows seed an explicit stable envelope without inventing telemetry" do
      rail =
        StudioChat.rail_apply_background(%{}, %{
          "tasks" => [
            %{"task_id" => "wf", "task_type" => "local_workflow", "description" => "cycle"},
            %{"task_id" => "plain", "task_type" => "shell", "description" => "command"}
          ]
        })

      assert Map.take(rail["wf"], ["status", "workflow", "usage"]) == %{
               "status" => "running",
               "workflow" => [],
               "usage" => nil
             }

      refute Map.has_key?(rail["plain"], "workflow")
      refute Map.has_key?(rail["plain"], "usage")
    end

    test "rail_apply_background never resurrects an interrupted entry" do
      rail = %{"a" => %{"status" => "interrupted", "seq" => 1, "row" => %{"description" => "x"}}}
      # "a" is absent from the new snapshot — it stays interrupted, not completed
      out = StudioChat.rail_apply_background(rail, %{"tasks" => []})
      assert out["a"]["status"] == "interrupted"
    end

    test "rail_all_terminal? — non-empty all-terminal rails only" do
      # empty rail never sweeps (nothing to age out)
      refute StudioChat.rail_all_terminal?(%{})
      refute StudioChat.rail_all_terminal?(nil)

      # a single live entry blocks the sweep
      refute StudioChat.rail_all_terminal?(%{
               "a" => %{"status" => "completed"},
               "b" => %{"status" => "running"}
             })

      # completed ∪ interrupted both count as settled
      assert StudioChat.rail_all_terminal?(%{
               "a" => %{"status" => "completed"},
               "b" => %{"status" => "interrupted"}
             })
    end

    test "rail_capture_progress only touches the rail with a tree or existing entry" do
      # bare heartbeat for an unknown task ⇒ no noise
      assert StudioChat.rail_capture_progress(%{}, %{"task_id" => "ghost"}) == %{}

      rail =
        StudioChat.rail_capture_progress(%{}, %{
          "task_id" => "t",
          "workflow_progress" => [%{"type" => "workflow_phase", "title" => "Plan"}],
          "usage" => %{"total_tokens" => 5}
        })

      assert rail["t"]["workflow"] == [%{"type" => "workflow_phase", "title" => "Plan"}]
      assert rail["t"]["usage"]["total_tokens"] == 5

      # A progress frame may beat background_tasks_changed and may omit usage.
      # The owned envelope is still explicit; nil means genuinely unreported.
      progress_first =
        StudioChat.rail_capture_progress(%{}, %{
          "task_id" => "early",
          "workflow_progress" => [%{"type" => "workflow_phase", "title" => "Plan"}]
        })

      assert progress_first["early"]["status"] == "running"
      assert progress_first["early"]["workflow"] != []
      assert Map.has_key?(progress_first["early"], "usage")
      assert progress_first["early"]["usage"] == nil
    end

    test "rail_stamp_status only stamps a task that already has an entry" do
      assert StudioChat.rail_stamp_status(%{}, "ghost", "completed") == %{}

      rail = %{"t" => %{"status" => "running", "row" => %{"description" => "x"}}}
      out = StudioChat.rail_stamp_status(rail, "t", "completed")
      assert out["t"]["status"] == "completed"
      assert out["t"]["row"]["description"] == "x"
    end

    test "rail_stamp_status folds a terminal end_time onto the entry (charter D5)" do
      rail = %{"t" => %{"status" => "running", "row" => %{"description" => "x"}}}

      # a non-terminal stamp (no end_time) never adds the key
      out = StudioChat.rail_stamp_status(rail, "t", "running")
      refute Map.has_key?(out["t"], "end_time")

      # a terminal stamp with end_time lands it verbatim
      out = StudioChat.rail_stamp_status(rail, "t", "completed", 1_782_767_600_000)
      assert out["t"]["status"] == "completed"
      assert out["t"]["end_time"] == 1_782_767_600_000

      # a ghost task with an end_time still stamps nothing
      assert StudioChat.rail_stamp_status(%{}, "ghost", "completed", 123) == %{}
    end

    test "workflow_summary/1 is nil for a plain rail, real for a workflow-bearing one" do
      # no entry carries a workflow list ⇒ plain chats pay zero
      assert StudioChat.workflow_summary(%{}) == nil

      assert StudioChat.workflow_summary(%{
               "t" => %{"status" => "running", "row" => %{"description" => "run"}}
             }) == nil

      rail = %{
        "t" => %{
          "status" => "running",
          "seq" => 1,
          "end_time" => 1_782_767_600_000,
          "row" => %{"description" => "epic-cycle · wsc"},
          "workflow" => [
            %{"type" => "workflow_phase", "index" => 1, "title" => "Design"},
            %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
            %{
              "type" => "workflow_agent",
              "phaseIndex" => 1,
              "label" => "design:a",
              "state" => "completed",
              "startedAt" => 1_782_767_557_221,
              "tokens" => 10
            },
            %{
              "type" => "workflow_agent",
              "phaseIndex" => 1,
              "label" => "design:b",
              "state" => "error",
              "startedAt" => 1_782_767_557_999,
              "tokens" => 5
            }
          ]
        }
      }

      summary = StudioChat.workflow_summary(rail)
      assert summary.label == "epic-cycle · wsc"
      assert summary.phases_total == 2
      # settled + failed = the honest done counter (1 completed + 1 error)
      assert summary.agents_done == 2
      assert summary.agents_total == 2
      assert summary.running == 0
      assert summary.tokens == 15
      # min startedAt across the workflow nodes
      assert summary.started_at == 1_782_767_557_221
      # the stamped terminal end_time surfaces as ended_at
      assert summary.ended_at == 1_782_767_600_000
      # phase 1 (has the agents, the live frontier) breathes; phase 2 is future
      assert summary.ticks == [:active, :future]
      assert summary.phase == "Design"
      assert summary.phase_index == 1
      assert summary.terminal? == false
      assert summary.outcome == :live
    end

    test "the rail caps at 20, pruning oldest-terminal first and never a runner" do
      # 21 terminal entries + 1 running; the running one must survive the cap
      tasks =
        for i <- 1..21 do
          %{"task_id" => "done-#{i}", "task_type" => "local_workflow", "description" => "d#{i}"}
        end

      # seed all as running, then drain all but keep one running
      rail = StudioChat.rail_apply_background(%{}, %{"tasks" => tasks})
      rail = StudioChat.rail_stamp_status(rail, "done-1", "running")

      # everything vanishes except done-1 ⇒ 20 complete, done-1 stays running
      rail =
        StudioChat.rail_apply_background(rail, %{
          "tasks" => [
            %{"task_id" => "done-1", "task_type" => "local_workflow", "description" => "d1"}
          ]
        })

      assert map_size(rail) <= 20
      assert rail["done-1"]["status"] == "running"
    end

    test "interrupt_running_tasks/1 flips running rail entries to interrupted, sparing the rest" do
      s = new_session()

      {:ok, _} =
        StudioChat.set_rail_snapshot(s.id, %{
          "live" => %{"status" => "running", "row" => %{"description" => "a"}},
          "done" => %{"status" => "completed", "row" => %{"description" => "b"}}
        })

      StudioChat.interrupt_running_tasks(s.id)

      rail = StudioChat.get_session(s.id).rail_snapshot
      assert rail["live"]["status"] == "interrupted"
      assert rail["done"]["status"] == "completed"
    end
  end

  # Real v2.1.205 captures committed under test/fixtures/claude_chat/. These
  # ALWAYS-ON (untagged) tests decode the real bytes and drive the pure folds —
  # the wire assumptions the agents rail was built on are now PERMANENT
  # regression tests, not one-off probe notes (wave-10 fixture law).
  @fixtures_dir Path.expand("../fixtures/claude_chat", __DIR__)
  @go_rail_fixtures_dir Path.expand("../../../internal/chat/testdata", __DIR__)

  defp load_ndjson(name) do
    @fixtures_dir
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp wire_frames(name),
    do: Enum.reject(load_ndjson(name), &(&1["type"] == "fixture_provenance"))

  describe "Claude queue-race wire fixtures (charter D11/D12/D62)" do
    test "no-active-turn interrupt is a benign empty queue acknowledgement" do
      assert [ack] = wire_frames("interrupt_no_active_turn.ndjson")
      assert ack["type"] == "control_response"
      assert get_in(ack, ["response", "subtype"]) == "success"
      assert get_in(ack, ["response", "response", "still_queued"]) == []
    end

    test "mid-turn user input is ordered after turn one and before a fresh turn init" do
      frames = wire_frames("mid_turn_queued_user.ndjson")

      assert Enum.map(frames, &{&1["type"], &1["subtype"]}) == [
               {"system", "init"},
               {"stream_event", nil},
               {"user", nil},
               {"result", "success"},
               {"system", "init"},
               {"stream_event", nil},
               {"result", "success"}
             ]

      assert get_in(Enum.at(frames, 2), ["message", "content", Access.at(0), "text"]) ==
               "queued question"

      assert Enum.at(frames, 3)["result"] == "turn one"
      assert Enum.at(frames, 4)["uuid"] == "turn-2-init"
      assert Enum.at(frames, 6)["result"] == "turn two"
    end
  end

  defp workflow_progress_frames(frames) do
    Enum.filter(frames, fn f ->
      f["subtype"] == "task_progress" and is_list(f["workflow_progress"])
    end)
  end

  defp background_snapshot_frames(frames),
    do: Enum.filter(frames, &(&1["subtype"] == "background_tasks_changed"))

  describe "agents rail: real-binary fixture folds (charter D47 — wave 10 wire truth)" do
    test "the FLAT-LIST workflow_progress frames fold into rail agent nodes carrying title/label/model/state" do
      frames = "workflow_progress.ndjson" |> load_ndjson() |> workflow_progress_frames()
      assert frames != []

      rail = Enum.reduce(frames, %{}, &StudioChat.rail_capture_progress(&2, &1))

      # one workflow task, keyed by its real task_id
      assert map_size(rail) == 1
      [{tid, entry}] = Map.to_list(rail)
      assert is_binary(tid)

      nodes = entry["workflow"]
      assert is_list(nodes)

      phases = Enum.filter(nodes, &(&1["type"] == "workflow_phase"))
      agents = Enum.filter(nodes, &(&1["type"] == "workflow_agent"))
      assert phases != []
      assert agents != []
      # the real nodes carry exactly the render fields the rail reads
      assert Enum.all?(phases, &is_binary(&1["title"]))

      assert Enum.all?(
               agents,
               &(is_binary(&1["label"]) and is_binary(&1["model"]) and is_binary(&1["state"]))
             )
    end

    test "real agent states are ONLY start/done and rail_signature moves across the lifecycle" do
      frames = "workflow_progress.ndjson" |> load_ndjson() |> workflow_progress_frames()

      states =
        frames
        |> Enum.flat_map(& &1["workflow_progress"])
        |> Enum.filter(&(&1["type"] == "workflow_agent"))
        |> Enum.map(& &1["state"])
        |> Enum.uniq()
        |> Enum.sort()

      # the wire truth the terminal-set fold is built on: no "running" ever
      assert states == ["done", "start"]

      [first | _] = frames
      sig_first = StudioChat.rail_signature(StudioChat.rail_capture_progress(%{}, first))

      sig_last =
        StudioChat.rail_signature(
          Enum.reduce(frames, %{}, &StudioChat.rail_capture_progress(&2, &1))
        )

      # start → done is a structural state change, so the signature (which
      # strips token churn but keeps state) must differ
      refute sig_first == sig_last
    end

    test "a workflow entry SURVIVES an unrelated background snapshot; a vanished background entry flips to completed" do
      wf_frames = "workflow_progress.ndjson" |> load_ndjson() |> workflow_progress_frames()
      bg_frames = "background_tasks.ndjson" |> load_ndjson() |> background_snapshot_frames()

      assert length(bg_frames) == 2
      [bg_live, bg_empty] = bg_frames
      assert bg_live["tasks"] != []
      assert bg_empty["tasks"] == []

      # a live workflow rail — NO background provenance
      rail = Enum.reduce(wf_frames, %{}, &StudioChat.rail_capture_progress(&2, &1))
      [{wf_tid, _}] = Map.to_list(rail)
      assert rail[wf_tid]["status"] == "running"
      refute rail[wf_tid]["origin"] == "background"

      # an unrelated background agent's snapshot arrives
      rail = StudioChat.rail_apply_background(rail, bg_live)
      [bg_tid] = Enum.map(bg_live["tasks"], & &1["task_id"])
      assert bg_tid != wf_tid
      assert rail[bg_tid]["origin"] == "background"
      assert rail[bg_tid]["status"] == "running"
      # the provenance gate: the workflow entry is untouched by the background fold
      assert rail[wf_tid]["status"] == "running"

      # the background task completes (empty snapshot): its own entry flips, the
      # workflow entry — never a background-snapshot member — stays running
      rail = StudioChat.rail_apply_background(rail, bg_empty)
      assert rail[bg_tid]["status"] == "completed"
      assert rail[wf_tid]["status"] == "running"
    end

    test "the foreground-task capture carries NO rail frames — folding it leaves the rail empty" do
      frames = load_ndjson("foreground_task.ndjson")
      refute Enum.any?(frames, &(&1["subtype"] == "background_tasks_changed"))
      refute Enum.any?(frames, &is_list(&1["workflow_progress"]))

      rail =
        Enum.reduce(frames, %{}, fn f, rail ->
          rail
          |> StudioChat.rail_apply_background(f)
          |> StudioChat.rail_capture_progress(f)
        end)

      assert rail == %{}
    end
  end

  # ── Wave-11 phase journey (charter D57–D59, D62) ────────────────────────────
  #
  # FIXTURE PROVENANCE (charter D62). Two committed fixtures whose workflow-agent
  # NODE PAYLOADS are VERBATIM from real epic-cycle runs (never invented — only
  # the frame envelope and the progressive start→done state replay are derived,
  # following the committed workflow_progress.ndjson grammar: bg-add → task_started
  # → progressive task_progress in real startedAt/durationMs order → completed
  # only: empty-bg → task_updated → task_notification):
  #
  #   * epic_cycle_progress.ndjson — the COMPLETED 7-phase 29-agent run
  #     wf_49614704-d80 (all-opus claude-opus-4-8[1m]; design:/impl:/
  #     verify:encryption:leak labels), every agent walked to `done`.
  #   * epic_cycle_interrupted.ndjson — the KILLED 7-phase bp-epic-cycle run
  #     wf_1e38c940-f75 (fable strategist done, 4 opus explorers in `progress`,
  #     phases 3–7 declared agentless), ending mid-flight with NO terminal frames.
  #
  # The fixture-fed tests fold the FULL INTERLEAVED stream (bg frames INCLUDED)
  # exactly as the Recorder's dispatch does — the wave-10 filtered-fold blind spot
  # (workflow entry never seeing its bg-add) dies here.

  # Fold a full frame stream into a rail map EXACTLY as recorder.ex dispatches
  # (background_tasks_changed → rail_apply_background; task_progress →
  # rail_capture_progress; task_updated/notification → rail_stamp_status).
  defp fold_rail(frames) do
    Enum.reduce(frames, %{}, fn ev, rail ->
      case ev["subtype"] do
        "background_tasks_changed" ->
          StudioChat.rail_apply_background(rail, ev)

        "task_progress" ->
          StudioChat.rail_capture_progress(rail, ev)

        "task_updated" ->
          StudioChat.rail_stamp_status(rail, ev["task_id"], get_in(ev, ["patch", "status"]))

        "task_notification" ->
          StudioChat.rail_stamp_status(rail, ev["task_id"], ev["status"])

        _ ->
          rail
      end
    end)
  end

  # Produce the Go rail mirrors from EMPTY state through the same public folds
  # the Recorder calls. Barkpark owns and locks the entry envelope
  # (workflow/status/usage); the workflow node payloads are Claude Code
  # telemetry forwarded verbatim from the real ndjson captures and are not a
  # Barkpark field contract.
  defp fold_rail_wire_event(rail, ev) do
    case ev["subtype"] do
      "background_tasks_changed" ->
        StudioChat.rail_apply_background(rail, ev)

      "task_progress" ->
        StudioChat.rail_capture_progress(rail, ev)

      "task_updated" ->
        StudioChat.rail_stamp_status(
          rail,
          ev["task_id"],
          get_in(ev, ["patch", "status"]),
          get_in(ev, ["patch", "end_time"])
        )

      "task_notification" ->
        StudioChat.rail_stamp_status(rail, ev["task_id"], ev["status"])

      _ ->
        rail
    end
  end

  defp live_rail_fixture do
    load_ndjson("epic_cycle_progress.ndjson")
    |> Enum.reduce_while(%{}, fn ev, rail ->
      rail = fold_rail_wire_event(rail, ev)

      agents =
        case ev["workflow_progress"] do
          nodes when is_list(nodes) -> Enum.count(nodes, &(&1["type"] == "workflow_agent"))
          _ -> 0
        end

      if ev["subtype"] == "task_progress" and get_in(ev, ["usage", "total_tokens"]) == 1_552_004 and
           agents == 28,
         do: {:halt, rail},
         else: {:cont, rail}
    end)
  end

  defp completed_rail_fixture,
    do:
      "epic_cycle_progress.ndjson"
      |> load_ndjson()
      |> Enum.reduce(%{}, &fold_rail_wire_event(&2, &1))

  defp interrupted_rail_fixture do
    rail =
      "epic_cycle_interrupted.ndjson"
      |> load_ndjson()
      |> Enum.reduce(%{}, &fold_rail_wire_event(&2, &1))

    [{task_id, _entry}] = Map.to_list(rail)
    StudioChat.rail_stamp_status(rail, task_id, "interrupted")
  end

  describe "Go rail fixture producer freshness" do
    test "the three Go rail fixtures equal fresh StudioChat producer folds" do
      fresh = %{
        "rail_workflow_live.json" => live_rail_fixture(),
        "rail_workflow_interrupted.json" => interrupted_rail_fixture(),
        "rail_workflow_completed.json" => completed_rail_fixture()
      }

      Enum.each(fresh, fn {name, produced} ->
        committed = @go_rail_fixtures_dir |> Path.join(name) |> File.read!() |> Jason.decode!()

        assert committed == produced,
               "#{name} is stale against StudioChat's rail producer folds"
      end)

      nodes =
        fresh |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.flat_map(& &1["workflow"])

      assert Enum.any?(nodes, &(&1["type"] == "workflow_phase")),
             "rail fixture lock must exercise at least one workflow phase"

      assert Enum.any?(nodes, &(&1["type"] == "workflow_agent")),
             "rail fixture lock must exercise at least one workflow agent"
    end
  end

  # The teardown interrupt flip (interrupt_rail_entries): every still-"running"
  # entry → "interrupted". Mirrors studio_chat.ex exactly, purely, so the journey
  # of a dead session is what production replays.
  defp interrupt_flip(rail) do
    Map.new(rail, fn
      {tid, %{"status" => "running"} = e} -> {tid, Map.put(e, "status", "interrupted")}
      other -> other
    end)
  end

  defp only_entry(rail) do
    assert map_size(rail) == 1
    [{_tid, entry}] = Map.to_list(rail)
    entry
  end

  describe "workflow_journey/1 — completed fixture (charter D57/D58/D62)" do
    test "the completed 7-phase 29-agent run reads 7/7 :done, honest aggregates" do
      entry = "epic_cycle_progress.ndjson" |> load_ndjson() |> fold_rail() |> only_entry()

      # the full-stream fold: the workflow rode the bg-add, so it is
      # background-origin and its terminal status arrives redundantly (D62)
      assert entry["origin"] == "background"
      assert entry["status"] == "completed"

      %{phases: phases, summary: s} = StudioChat.workflow_journey(entry)

      assert length(phases) == 7
      assert Enum.all?(phases, &(&1.status == :done))
      assert Enum.map(phases, & &1.title) |> hd() == "Design"

      assert s.entry_status == :completed
      assert s.phase_total == 7
      assert s.phases_run == 7
      assert s.skipped == 0
      assert s.active == nil
      assert s.agents_total == 29
      assert s.running == 0
      assert s.done == 29
      assert s.failed == 0
      # verbatim token truth summed from the real done nodes
      assert s.tokens == 2_137_873
    end

    test "phase 1 groups its four design agents by phaseIndex, model family Opus" do
      entry = "epic_cycle_progress.ndjson" |> load_ndjson() |> fold_rail() |> only_entry()
      %{phases: [design | _]} = StudioChat.workflow_journey(entry)

      assert design.title == "Design"
      assert design.total == 4
      assert design.model == "Opus"

      assert Enum.map(design.agents, & &1["label"]) ==
               ~w(design:encryption design:visibility design:ownership design:hardening)
    end
  end

  describe "workflow_journey/1 — interrupted fixture (charter D58/D62)" do
    test "a killed run shows the frontier :interrupted, an :unreached tail, phase 1 :done" do
      rail = "epic_cycle_interrupted.ndjson" |> load_ndjson() |> fold_rail()

      # ends mid-flight — no terminal frames, so the fold leaves it running
      assert only_entry(rail)["status"] == "running"

      # the session-teardown interrupt flip supplies "interrupted" (as prod does)
      entry = rail |> interrupt_flip() |> only_entry()
      assert entry["status"] == "interrupted"

      %{phases: phases, summary: s} = StudioChat.workflow_journey(entry)
      by_index = Map.new(phases, &{&1.index, &1.status})

      assert by_index[1] == :done
      assert by_index[2] == :interrupted
      # phases 3–7 are agentless on a dead entry → :unreached tail
      assert Enum.all?(3..7, &(by_index[&1] == :unreached))

      assert s.entry_status == :interrupted
      assert s.active == %{index: 2, title: "Explore"}
      assert s.phases_run == 1
      assert s.agents_total == 5
      # the 4 explorers are still `progress` (non-terminal) — running, not done
      assert s.running == 4
      assert s.done == 1
      assert s.failed == 0
    end

    # wsc-bl-real-fixtures (D62/D21): a NEW provenance-headed fixture replaying the
    # SAME real killed run (wf_1e38c940-f75) VERBATIM, but carrying a
    # fixture_provenance header line — the convention the pre-header
    # epic_cycle_interrupted fixture predates. Two invariants that fixture never
    # asserted: fold_rail NO-OPS on the header line (it dispatches on subtype; a
    # provenance frame has none), and the interrupt SIGNATURE is the ABSENCE of a
    # terminal type:result frame (a SIGKILL never flushes one).
    test "a REAL provenance-headed killed run folds the interrupted frontier — header no-ops, no result frame" do
      frames = load_ndjson("epic_cycle_interrupted_real.ndjson")

      # the D62 provenance header rides the file …
      assert Enum.any?(frames, &(&1["type"] == "fixture_provenance"))
      # … and the SIGKILL signature: the CLI flushed NO terminal result frame
      refute Enum.any?(frames, &(&1["type"] == "result"))

      rail = fold_rail(frames)
      # fold_rail no-ops on the header (no subtype) → exactly one workflow entry,
      # still "running" because no terminal frame ever arrived
      assert only_entry(rail)["status"] == "running"

      # teardown supplies "interrupted" (as prod's interrupt_rail_entries does)
      entry = rail |> interrupt_flip() |> only_entry()
      assert entry["status"] == "interrupted"

      %{phases: phases, summary: s} = StudioChat.workflow_journey(entry)
      by_index = Map.new(phases, &{&1.index, &1.status})

      assert by_index[1] == :done
      assert by_index[2] == :interrupted
      # phases 3–7 never breathed → :unreached tail
      assert Enum.all?(3..7, &(by_index[&1] == :unreached))

      assert s.entry_status == :interrupted
      assert s.active == %{index: 2, title: "Explore"}
      assert s.phases_run == 1
      assert s.agents_total == 5
      assert s.running == 4
      assert s.done == 1
      assert s.failed == 0
    end
  end

  describe "workflow_summary/1 — sidebar-fold edges (wsc charter D2/D3/D7)" do
    # The pinned D3 shape, the two committed-fixture folds, nil/no-workflow
    # rails, and the highest-seq pick are proven in the canonical
    # "workflow_summary/1 — … (D3 shape)" describes below (wsc-s1). These are
    # the s3-side edges the sidebar leans on.

    test "a stamped end_time rides through as ended_at (D5 read side)" do
      rail = "epic_cycle_progress.ndjson" |> load_ndjson() |> fold_rail()
      [{tid, entry}] = Map.to_list(rail)
      rail = Map.put(rail, tid, Map.put(entry, "end_time", 1_782_771_832_104))

      assert StudioChat.workflow_summary(rail).ended_at == 1_782_771_832_104
    end

    test "a live run wears the active phase word and the settled counter" do
      summary =
        StudioChat.workflow_summary(%{
          "wf" => %{
            "status" => "running",
            "seq" => 1,
            "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
            "workflow" => [
              %{"type" => "workflow_phase", "index" => 1, "title" => "Explore"},
              %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
              %{
                "type" => "workflow_agent",
                "phaseIndex" => 1,
                "label" => "explore",
                "state" => "done",
                "startedAt" => 100,
                "tokens" => 10
              },
              %{
                "type" => "workflow_agent",
                "phaseIndex" => 2,
                "label" => "build:a",
                "state" => "error",
                "startedAt" => 200
              },
              %{
                "type" => "workflow_agent",
                "phaseIndex" => 2,
                "label" => "build:b",
                "state" => "progress",
                "startedAt" => 150
              }
            ]
          }
        })

      assert summary.outcome == :live
      assert summary.terminal? == false
      assert summary.phase == "Build"
      assert summary.phase_index == 2
      # the tick spine mirrors the journey statuses in order
      assert summary.ticks == [:done, :active]
      # done + failed = settled (the error terminal counts as finished, D2)
      assert summary.agents_done == 2
      assert summary.agents_total == 3
      assert summary.running == 1
      assert summary.started_at == 100
      assert summary.label == "wave 1"
    end
  end

  # Direct Repo inserts — epic_goal reads the published documents table; no
  # claim machinery is exercised (the fold under test is the READ, not the
  # write path).
  defp insert_task!(doc_id, title, content) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      title: title,
      status: "published",
      content: content,
      rev: Ecto.UUID.generate()
    })
  end

  describe "epic_goal/2 — one-hop ledger read (wsc charter D8/D9)" do
    test "resolves epic title · slices done/total · wave_status through the held claim" do
      sid = Ecto.UUID.generate()
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)

      insert_task!("task-wsc-epic", "Wave Session Card", %{
        "kind" => "task",
        "lifecycle_status" => "in_progress",
        "wave_status" => "wave: building 5 slices"
      })

      insert_task!("task-wsc-held", "Slice s3", %{
        "lifecycle_status" => "in_progress",
        "parent_id" => "task-wsc-epic",
        "claim" => %{"worker" => worker}
      })

      insert_task!("task-wsc-s1", "Slice s1", %{
        "lifecycle_status" => "done",
        "parent_id" => "task-wsc-epic"
      })

      insert_task!("task-wsc-s2", "Slice s2", %{
        "lifecycle_status" => "cancelled",
        "parent_id" => "task-wsc-epic"
      })

      insert_task!("task-wsc-s4", "Slice s4", %{
        "lifecycle_status" => "open",
        "parent_id" => "task-wsc-epic"
      })

      goal = StudioChat.epic_goal("claude", sid)

      assert goal.id == "task-wsc-epic"
      assert goal.title == "Wave Session Card"
      # done + cancelled are settled; held (in_progress) + open are not
      assert goal.slices_done == 2
      assert goal.slices_total == 4
      assert goal.wave_status == "wave: building 5 slices"
      # "PRs open" has no data source (D8) — the shape carries no such key
      refute Map.has_key?(goal, :prs_open)
    end

    test "nil at every missing hop — no claim, no parent, vanished epic" do
      sid = Ecto.UUID.generate()
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)

      # no claim at all
      assert StudioChat.epic_goal("claude", sid) == nil

      # a held claim WITHOUT a parent hop
      insert_task!("task-wsc-orphan", "Orphan", %{
        "lifecycle_status" => "in_progress",
        "claim" => %{"worker" => worker}
      })

      assert StudioChat.epic_goal("claude", sid) == nil

      # a parent hop to a task that does not exist
      insert_task!("task-wsc-dangling", "Dangling", %{
        "lifecycle_status" => "in_progress",
        "parent_id" => "task-never-published",
        "claim" => %{"worker" => worker}
      })

      assert StudioChat.epic_goal("claude", sid) == nil
    end

    test "a draft-twin claim never resolves (published ledger only)" do
      sid = Ecto.UUID.generate()
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)

      insert_task!("drafts.task-wsc-draft", "Draft twin", %{
        "lifecycle_status" => "in_progress",
        "parent_id" => "task-wsc-epic",
        "claim" => %{"worker" => worker}
      })

      assert StudioChat.epic_goal("claude", sid) == nil
    end
  end

  describe "workflow_journey/1 — derived-truth edges (charter D58)" do
    test ":skipped falls out of a COMPLETED entry with an agentless trailing phase" do
      entry = %{
        "status" => "completed",
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Build"},
          %{"type" => "workflow_phase", "index" => 2, "title" => "Review"},
          %{"type" => "workflow_phase", "index" => 3, "title" => "Perfect"},
          %{"type" => "workflow_agent", "phaseIndex" => 1, "label" => "build", "state" => "done"},
          %{"type" => "workflow_agent", "phaseIndex" => 2, "label" => "review", "state" => "done"}
        ]
      }

      %{phases: phases, summary: s} = StudioChat.workflow_journey(entry)
      assert Enum.map(phases, & &1.status) == [:done, :done, :skipped]
      # honest "2 of 3 phases · 1 skipped", never a fake 3/3
      assert s.phases_run == 2
      assert s.skipped == 1
    end

    test "an `error` agent renders failed — never counted as done, phase still settles" do
      entry = %{
        "status" => "completed",
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Judge"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "judge:ok",
            "state" => "done",
            "tokens" => 100
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "judge:boom",
            "state" => "error",
            "error" => "kaboom",
            "tokens" => 50
          }
        ]
      }

      %{phases: [judge], summary: s} = StudioChat.workflow_journey(entry)
      # both agents are terminal, so the phase settles :done…
      assert judge.status == :done
      # …but the errored agent is a FAILURE terminal, not a success
      assert s.done == 1
      assert s.failed == 1
      assert s.running == 0
      assert StudioChat.workflow_node_terminal?(%{"state" => "error"})
    end

    test "a live run's highest-with-agents phase is :active, earlier :done, later :future" do
      entry = %{
        "status" => "running",
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Explore"},
          %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
          %{"type" => "workflow_phase", "index" => 3, "title" => "Review"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "explore",
            "state" => "done"
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:a",
            "state" => "done"
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:b",
            "state" => "start"
          }
        ]
      }

      %{phases: phases, summary: s} = StudioChat.workflow_journey(entry)
      assert Enum.map(phases, & &1.status) == [:done, :active, :future]
      assert s.active == %{index: 2, title: "Build"}
      assert s.running == 1
      assert s.done == 2
    end
  end

  describe "workflow_journey/1 signature law (charter D57)" do
    test "a phaseIndex regrouping re-signs; a token tick does not" do
      base = %{
        "wf" => %{
          "status" => "running",
          "workflow" => [
            %{
              "type" => "workflow_agent",
              "phaseIndex" => 1,
              "label" => "a",
              "state" => "start",
              "tokens" => 10
            }
          ]
        }
      }

      token_tick =
        put_in(base, ["wf", "workflow"], [
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "a",
            "state" => "start",
            "tokens" => 9_999
          }
        ])

      regrouped =
        put_in(base, ["wf", "workflow"], [
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "a",
            "state" => "start",
            "tokens" => 10
          }
        ])

      # phaseIndex is now inside strip_workflow_node's take list (charter D57)
      assert StudioChat.rail_signature(base) == StudioChat.rail_signature(token_tick)
      refute StudioChat.rail_signature(base) == StudioChat.rail_signature(regrouped)
    end

    test "the interrupted fixture's start→interrupted flip re-signs" do
      rail = "epic_cycle_interrupted.ndjson" |> load_ndjson() |> fold_rail()
      refute StudioChat.rail_signature(rail) == StudioChat.rail_signature(interrupt_flip(rail))
    end
  end

  describe "workflow_label_parts/1 (charter D59)" do
    test "first-colon split for a slug head; multi-colon rest kept; bare otherwise" do
      assert StudioChat.workflow_label_parts("design:encryption") ==
               {:pair, "design", "encryption"}

      assert StudioChat.workflow_label_parts("verify:encryption:leak") ==
               {:pair, "verify", "encryption:leak"}

      assert StudioChat.workflow_label_parts("sec:1") == {:pair, "sec", "1"}
      assert StudioChat.workflow_label_parts("strategist") == {:bare, "strategist"}
      # a non-slug head (spaces/caps — a raw-prompt fallback) never splits
      assert StudioChat.workflow_label_parts("Fix the leak: now") == {:bare, "Fix the leak: now"}
      assert StudioChat.workflow_label_parts(nil) == {:bare, ""}
    end
  end

  describe "model_family/1 (charter D59)" do
    test "wire ids map by prefix; picker slugs resolve; unknown stays raw" do
      assert StudioChat.model_family("claude-opus-4-8[1m]") == "Opus"
      assert StudioChat.model_family("claude-fable-5") == "Fable"
      assert StudioChat.model_family("claude-sonnet-4-5") == "Sonnet"
      assert StudioChat.model_family("claude-haiku-4-5") == "Haiku"
      assert StudioChat.model_family("opus") == "Opus"
      assert StudioChat.model_family("fable") == "Fable"
      assert StudioChat.model_family("gpt-9") == "gpt-9"
      assert StudioChat.model_family(nil) == nil
    end
  end

  # ── Card-level workflow_summary/1 (D1–D4) ───────────────────────────────────
  #
  # Fold the two committed epic-cycle fixtures into a rail exactly as the Recorder
  # does, then project the pinned D3 card shape. The interrupted fixture ends
  # mid-flight (no terminal frames), so — as production replays — the teardown
  # `interrupt_flip` supplies "interrupted" before the summary is read.

  defp summary_of(fixture, transform) do
    fixture
    |> load_ndjson()
    |> fold_rail()
    |> transform.()
    |> StudioChat.workflow_summary()
  end

  describe "workflow_summary/1 — completed fixture (D3 shape)" do
    test "the completed 7-phase 29-agent run projects a settled complete card" do
      entry = "epic_cycle_progress.ndjson" |> load_ndjson() |> fold_rail() |> only_entry()
      journey = StudioChat.workflow_journey(entry)
      card = StudioChat.workflow_summary(%{"t" => entry})

      # every field of the pinned shape
      assert Map.keys(card) |> Enum.sort() ==
               ~w(agents_done agents_total ended_at label outcome phase phase_index
                  phases_total running started_at terminal? ticks tokens)a

      assert card.ticks == List.duplicate(:done, 7)
      assert card.phases_total == 7
      # a completed cycle collapses the active phase — no m/n phase, just the settle line
      assert card.phase == nil
      assert card.phase_index == nil
      assert card.outcome == :completed
      assert card.terminal? == true
      assert card.running == 0
      assert card.agents_done == 29
      assert card.agents_total == 29
      assert card.tokens == 2_137_873
      # timestamps are READ: startedAt present, end_time absent today (S2 stamps later)
      assert is_integer(card.started_at)
      assert card.ended_at == nil

      # agents_done/agents_total are journey's OWN counts — not a parallel tally
      assert card.agents_done == journey.summary.done + journey.summary.failed
      assert card.agents_total == journey.summary.agents_total
      assert card.running == journey.summary.running
    end
  end

  describe "workflow_summary/1 — interrupted fixture (D3 shape)" do
    test "a killed run shows the interrupted frontier, honest settled count, live agents kept" do
      journey =
        "epic_cycle_interrupted.ndjson"
        |> load_ndjson()
        |> fold_rail()
        |> interrupt_flip()
        |> only_entry()
        |> StudioChat.workflow_journey()

      card = summary_of("epic_cycle_interrupted.ndjson", &interrupt_flip/1)

      assert card.outcome == :interrupted
      assert card.terminal? == true
      # frontier phase = the one that breathed when the run died
      assert card.phase == "Explore"
      assert card.phase_index == 2
      assert card.ticks == [:done, :interrupted] ++ List.duplicate(:unreached, 5)
      # the 4 explorers are still `progress` (non-terminal) — running, never done
      assert card.agents_done == 1
      assert card.agents_total == 5
      assert card.running == 4

      # progress-state agents keep startedAt and never got durationMs/ended_at
      assert is_integer(card.started_at)
      assert card.ended_at == nil

      # cross-assert against journey's own summary — one truth table
      assert card.agents_done == journey.summary.done + journey.summary.failed
      assert card.agents_total == journey.summary.agents_total
      assert card.running == journey.summary.running
    end

    test "before teardown the same rail is honestly live (outcome :live, not terminal)" do
      card = summary_of("epic_cycle_interrupted.ndjson", & &1)
      assert card.outcome == :live
      assert card.terminal? == false
      # the frontier still breathes while live
      assert card.phase == "Explore"
      assert card.running == 4
    end

    # wsc-bl-real-fixtures (D62/D21): the D3 CARD side of the provenance-headed real
    # killed run. summary_of folds load_ndjson |> fold_rail (header no-ops) |>
    # interrupt_flip |> workflow_summary — the compact sidebar card the five merged
    # surfaces read must project the interrupted frontier from prod-shaped data.
    test "the REAL provenance-headed killed run projects the interrupted D3 card" do
      card = summary_of("epic_cycle_interrupted_real.ndjson", &interrupt_flip/1)

      assert card.outcome == :interrupted
      assert card.terminal? == true
      assert card.phase == "Explore"
      assert card.phase_index == 2
      assert card.ticks == [:done, :interrupted] ++ List.duplicate(:unreached, 5)
      # the 4 explorers stayed `progress` (non-terminal) — never counted done
      assert card.agents_done == 1
      assert card.agents_total == 5
      assert card.running == 4
      # progress-state agents keep startedAt and never earn durationMs/ended_at
      assert is_integer(card.started_at)
      assert card.ended_at == nil
    end
  end

  describe "workflow_summary/1 — derived-truth edges (D3)" do
    test "an `error` agent is a settled FAILURE — counted in agents_done, never running" do
      entry = %{
        "seq" => 1,
        "row" => %{"description" => "epic — fix the leak"},
        "status" => "completed",
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Judge"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "judge:ok",
            "state" => "done",
            "startedAt" => 100,
            "tokens" => 100
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "judge:boom",
            "state" => "error",
            "startedAt" => 90,
            "tokens" => 50
          }
        ]
      }

      card = StudioChat.workflow_summary(%{"t" => entry})
      # label is the opaque composite — a bare em-dash inside is NEVER split
      assert card.label == "epic — fix the leak"
      assert card.agents_done == 2
      assert card.agents_total == 2
      assert card.running == 0
      assert card.tokens == 150
      # earliest start across the tree
      assert card.started_at == 90
    end

    test "the highest-seq workflow-bearing entry wins across a mixed rail" do
      wf_a = %{
        "seq" => 3,
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "A"},
          %{"type" => "workflow_agent", "phaseIndex" => 1, "label" => "a", "state" => "done"}
        ]
      }

      wf_b = %{
        "seq" => 9,
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "B"},
          %{"type" => "workflow_agent", "phaseIndex" => 1, "label" => "b", "state" => "start"}
        ]
      }

      # a plain-chat entry with no workflow list is ignored
      plain = %{"seq" => 12, "status" => "running"}

      card = StudioChat.workflow_summary(%{"a" => wf_a, "b" => wf_b, "p" => plain})
      # wf_b has the higher seq → its phase title is the card's
      assert card.phase == "B"
    end

    test "nil for empty rail, a no-workflow rail, and non-map input" do
      assert StudioChat.workflow_summary(%{}) == nil
      assert StudioChat.workflow_summary(%{"t" => %{"status" => "running"}}) == nil
      # an entry with an empty workflow list is not workflow-bearing
      assert StudioChat.workflow_summary(%{"t" => %{"workflow" => []}}) == nil
      assert StudioChat.workflow_summary(nil) == nil
      assert StudioChat.workflow_summary([]) == nil
      assert StudioChat.workflow_summary("nope") == nil
    end
  end

  # ── Shared parity fixtures (Mechanism A) ────────────────────────────────────
  #
  # workflow_summary/1 output for both committed fixtures, written byte-identical
  # to an api mirror and a Go mirror so the Go card surface reads the SAME truth.
  # Regenerate by running this file with REGEN_WORKFLOW_SUMMARY=1 (writes both
  # mirrors from one encoded string), then re-run without it to prove freshness.
  @summary_api_path Path.expand(
                      "../support/fixtures/workflow_summary/workflow_summary.json",
                      __DIR__
                    )
  @summary_go_path Path.expand(
                     "../../../internal/chat/testdata/workflow_summary.json",
                     __DIR__
                   )

  # The LIVE mid-flight sibling. The two committed captures are SETTLED, so the
  # live card shape (outcome "live", terminal? false, an open ended_at) cannot be
  # folded from either of them end-to-end — `live_rail_fixture/0` halts the same
  # real epic-cycle capture MID-STREAM and that in-flight rail is what the
  # producer folds. Same generator, same REGEN_WORKFLOW_SUMMARY=1 pass, same two
  # mirrors: nothing here is hand-authored.
  @building_api_path Path.expand(
                       "../support/fixtures/workflow_summary/workflow_building.json",
                       __DIR__
                     )
  @building_go_path Path.expand(
                      "../../../internal/chat/testdata/workflow_building.json",
                      __DIR__
                    )

  defp fresh_summaries do
    %{
      "epic_cycle_progress" => summary_of("epic_cycle_progress.ndjson", & &1),
      "epic_cycle_interrupted" => summary_of("epic_cycle_interrupted.ndjson", &interrupt_flip/1)
    }
  end

  # JSON round-trip normalizes atom values/keys (statuses, outcomes) to the strings
  # the committed bytes carry — so a fresh fold compares cleanly to the mirror.
  defp normalized_fresh, do: fresh_summaries() |> Jason.encode!() |> Jason.decode!()

  defp fresh_building, do: StudioChat.workflow_summary(live_rail_fixture())

  defp normalized_fresh_building, do: fresh_building() |> Jason.encode!() |> Jason.decode!()

  describe "workflow_summary parity fixtures (Mechanism A)" do
    test "the committed api mirror equals a fresh fold" do
      if System.get_env("REGEN_WORKFLOW_SUMMARY") do
        json = Jason.encode!(fresh_summaries(), pretty: true) <> "\n"
        File.write!(@summary_api_path, json)
        File.write!(@summary_go_path, json)

        live_json = Jason.encode!(fresh_building(), pretty: true) <> "\n"
        File.write!(@building_api_path, live_json)
        File.write!(@building_go_path, live_json)
      end

      assert File.read!(@summary_api_path) |> Jason.decode!() == normalized_fresh(),
             "workflow_summary.json is stale — re-run with REGEN_WORKFLOW_SUMMARY=1."
    end

    test "the api and Go mirrors are byte-identical" do
      assert File.read!(@summary_api_path) == File.read!(@summary_go_path),
             "the Go mirror drifted — re-run with REGEN_WORKFLOW_SUMMARY=1."
    end

    test "the fixture carries both the completed and interrupted card shapes" do
      committed = File.read!(@summary_api_path) |> Jason.decode!()
      assert committed["epic_cycle_progress"]["outcome"] == "completed"
      assert committed["epic_cycle_interrupted"]["outcome"] == "interrupted"
      # the 13/17-style settled counter survives the round-trip
      assert committed["epic_cycle_progress"]["agents_done"] == 29
      assert committed["epic_cycle_interrupted"]["agents_done"] == 1
    end

    test "the committed LIVE api mirror equals a fresh in-flight fold" do
      assert File.read!(@building_api_path) |> Jason.decode!() == normalized_fresh_building(),
             "workflow_building.json is stale — re-run with REGEN_WORKFLOW_SUMMARY=1."
    end

    test "the LIVE api and Go mirrors are byte-identical" do
      assert File.read!(@building_api_path) == File.read!(@building_go_path),
             "the Go live mirror drifted — re-run with REGEN_WORKFLOW_SUMMARY=1."
    end

    test "the live fixture carries the LIVE-ONLY shape a settled fold cannot" do
      # Non-vacuity: without this, a regenerate that silently produced a SETTLED
      # summary would still satisfy freshness + byte-parity, and the five Go
      # render tests that read this file for the mid-flight card would go quiet.
      committed = File.read!(@building_api_path) |> Jason.decode!()

      assert committed["outcome"] == "live",
             "the live fixture must fold an IN-FLIGHT rail, got outcome " <>
               inspect(committed["outcome"])

      assert committed["terminal?"] == false,
             "a live turn is not terminal — got terminal? " <> inspect(committed["terminal?"])

      assert is_integer(committed["started_at"]),
             "started_at must be an epoch-ms integer, got " <> inspect(committed["started_at"])

      assert committed["ended_at"] == nil,
             "a live turn has no end — got ended_at " <> inspect(committed["ended_at"])

      # and the mid-flight fleet is genuinely mid-flight: some agents settled,
      # some still running, and the tick row still holds an unreached phase.
      assert committed["running"] > 0
      assert committed["agents_done"] < committed["agents_total"]
      assert "future" in committed["ticks"] or "unreached" in committed["ticks"]
    end
  end

  # ── workflow_agent_detail/1 — the per-agent drill-down projection (wsc-ad) ───
  #
  # The pure fold the Studio rail's expandable agent rows AND the TUI sibling both
  # read. Unit-proven against the real fixtures, then mirrored byte-identical to an
  # api + a Go mirror (Mechanism A), regenerated with REGEN_WORKFLOW_AGENT_DETAIL=1.

  defp detail_of(fixture),
    do: fixture |> load_ndjson() |> fold_rail() |> StudioChat.workflow_agent_detail()

  describe "workflow_agent_node_detail/1 (wsc-ad D27/D28)" do
    test "a node with NO detail-signal field yields %{} (the no-affordance gate)" do
      # a thin node (no brief/tool/result/attempt) — the rail shows no drill-down
      assert StudioChat.workflow_agent_node_detail(%{
               "type" => "workflow_agent",
               "agentId" => "x",
               "label" => "agent",
               "state" => "start",
               "startedAt" => 1000
             }) == %{}

      assert StudioChat.workflow_agent_node_detail(%{}) == %{}
      assert StudioChat.workflow_agent_node_detail(nil) == %{}
      assert StudioChat.workflow_agent_node_detail("nope") == %{}
    end

    test "a node with detail passes wire fields VERBATIM, omits absent, derives terminal/failed" do
      detail =
        StudioChat.workflow_agent_node_detail(%{
          "type" => "workflow_agent",
          "agentId" => "a1",
          "label" => "explore:auth",
          "state" => "error",
          "promptPreview" => "You are the explorer…",
          "lastToolName" => "StructuredOutput",
          "lastToolSummary" => "found the leak",
          "resultPreview" => ~s({"finding":"leak in query_controller"}),
          "attempt" => 1,
          "startedAt" => 100,
          "lastProgressAt" => 200,
          "durationMs" => 100,
          # tokens is NOT a detail key — it must be dropped
          "tokens" => 4200
        })

      # wire fields verbatim + raw epoch-ms timestamps
      assert detail["promptPreview"] == "You are the explorer…"
      assert detail["lastToolName"] == "StructuredOutput"
      assert detail["resultPreview"] == ~s({"finding":"leak in query_controller"})
      assert detail["startedAt"] == 100
      assert detail["lastProgressAt"] == 200
      assert detail["durationMs"] == 100
      # tokens is not part of the detail shape
      refute Map.has_key?(detail, "tokens")
      # terminal/failed DERIVED from the shared helper sets — error is a failure
      assert detail["terminal"] == true
      assert detail["failed"] == true
    end

    test "resultPreview passes through UNCAPPED (each surface caps at render)" do
      long = String.duplicate("x", 900)

      detail =
        StudioChat.workflow_agent_node_detail(%{
          "type" => "workflow_agent",
          "agentId" => "a1",
          "state" => "done",
          "resultPreview" => long
        })

      assert detail["resultPreview"] == long
      assert detail["terminal"] == true
      assert detail["failed"] == false
    end
  end

  describe "workflow_agent_detail/1 (wsc-ad D28 — rail → list)" do
    test "[] for empty / no-workflow / non-map rails" do
      assert StudioChat.workflow_agent_detail(%{}) == []
      assert StudioChat.workflow_agent_detail(%{"t" => %{"status" => "running"}}) == []
      assert StudioChat.workflow_agent_detail(%{"t" => %{"workflow" => []}}) == []
      assert StudioChat.workflow_agent_detail(nil) == []
      assert StudioChat.workflow_agent_detail("nope") == []
    end

    test "the completed run projects one detail map per agent (29), all terminal" do
      detail = detail_of("epic_cycle_progress.ndjson")
      assert length(detail) == 29
      assert Enum.all?(detail, & &1["terminal"])
      assert Enum.all?(detail, &is_binary(&1["agentId"]))
      # a real completed agent carries the brief, a settled result, and timing
      first = hd(detail)
      assert is_binary(first["promptPreview"])
      assert is_binary(first["resultPreview"])
      assert is_integer(first["startedAt"])
    end

    test "the interrupted run keeps its 5 agents; the live explorers are non-terminal" do
      detail = detail_of("epic_cycle_interrupted.ndjson")
      assert length(detail) == 5
      # 1 settled strategist + 4 live explorers (the interrupted frontier)
      assert Enum.count(detail, & &1["terminal"]) == 1
      assert Enum.count(detail, &(not &1["terminal"])) == 4
      # the live ones carry a NOW tool line but never a durationMs/resultPreview
      live = Enum.filter(detail, &(not &1["terminal"]))
      assert Enum.all?(live, &is_binary(&1["lastToolName"]))
      refute Enum.any?(live, &Map.has_key?(&1, "durationMs"))
    end

    test "the highest-seq workflow-bearing entry wins, detail-less nodes drop out" do
      rail = %{
        "a" => %{
          "seq" => 2,
          "workflow" => [
            %{
              "type" => "workflow_agent",
              "agentId" => "old",
              "state" => "done",
              "resultPreview" => "old"
            }
          ]
        },
        "b" => %{
          "seq" => 9,
          "workflow" => [
            # a detail-less agent — dropped from the list
            %{"type" => "workflow_agent", "agentId" => "thin", "state" => "start"},
            %{
              "type" => "workflow_agent",
              "agentId" => "rich",
              "state" => "start",
              "lastToolName" => "Read"
            },
            # a non-agent node is ignored
            %{"type" => "workflow_phase", "index" => 1, "title" => "Explore"}
          ]
        }
      }

      detail = StudioChat.workflow_agent_detail(rail)
      assert Enum.map(detail, & &1["agentId"]) == ["rich"]
    end
  end

  # ── Shared parity fixture (Mechanism A) — workflow_agent_detail ──────────────
  #
  # workflow_agent_detail/1 output for both committed fixtures, byte-identical to an
  # api mirror and a Go mirror so the TUI sibling reads the SAME per-agent shapes.
  # Regenerate with REGEN_WORKFLOW_AGENT_DETAIL=1, then re-run to prove freshness.
  @detail_api_path Path.expand(
                     "../support/fixtures/workflow_summary/workflow_agent_detail.json",
                     __DIR__
                   )
  @detail_go_path Path.expand(
                    "../../../internal/chat/testdata/workflow_agent_detail.json",
                    __DIR__
                  )

  defp fresh_details do
    %{
      "epic_cycle_progress" => detail_of("epic_cycle_progress.ndjson"),
      "epic_cycle_interrupted" => detail_of("epic_cycle_interrupted.ndjson")
    }
  end

  defp normalized_fresh_details, do: fresh_details() |> Jason.encode!() |> Jason.decode!()

  describe "workflow_agent_detail parity fixtures (Mechanism A)" do
    test "the committed api mirror equals a fresh fold" do
      if System.get_env("REGEN_WORKFLOW_AGENT_DETAIL") do
        json = Jason.encode!(fresh_details(), pretty: true) <> "\n"
        File.write!(@detail_api_path, json)
        File.write!(@detail_go_path, json)
      end

      assert File.read!(@detail_api_path) |> Jason.decode!() == normalized_fresh_details(),
             "workflow_agent_detail.json is stale — re-run with REGEN_WORKFLOW_AGENT_DETAIL=1."
    end

    test "the api and Go mirrors are byte-identical" do
      assert File.read!(@detail_api_path) == File.read!(@detail_go_path),
             "the Go mirror drifted — re-run with REGEN_WORKFLOW_AGENT_DETAIL=1."
    end

    test "the fixture carries the completed and interrupted agent rosters" do
      committed = File.read!(@detail_api_path) |> Jason.decode!()
      assert length(committed["epic_cycle_progress"]) == 29
      assert length(committed["epic_cycle_interrupted"]) == 5
      # every committed detail map carries a derived terminal flag and an agentId
      all = committed["epic_cycle_progress"] ++ committed["epic_cycle_interrupted"]
      assert Enum.all?(all, &Map.has_key?(&1, "terminal"))
      assert Enum.all?(all, &is_binary(&1["agentId"]))
      # honest attempt==1 across the real capture (no fabricated retry — D29 keeps
      # attempt>1 to the synthetic render node, never this verbatim-from-real fold)
      assert Enum.all?(all, &(&1["attempt"] == 1))
    end
  end

  # ── attempt>1 closes by DOCUMENTED PROOF (wsc-bl-real-fixtures, charter D21/D25) ─
  #
  # `attempt` is external Claude-Code Task-tool telemetry, forwarded through the
  # rail VERBATIM: rail_put_workflow (studio_chat.ex) is a bare `Map.put` with no
  # field logic and no derive path, and barkpark has NO repo mechanism (workflow
  # runner or Studio UI) to force a retry. So every workflow_agent node on every
  # wire we hold carries attempt==1 — the honest proof, never a fabricated
  # attempt=2. This test asserts it across BOTH the Elixir ndjson fixtures AND the
  # Go testdata mirrors the merged bp-chat card decodes, SCOPED to workflow_agent
  # nodes so fixtures with none no-op rather than false-pass.
  @testdata_dir Path.expand("../../../internal/chat/testdata", __DIR__)

  # Recursively collect every `attempt` value under a "workflow_agent"-typed node,
  # at any nesting depth (task_progress frames nest them under "workflow_progress";
  # rail snapshots nest them under an entry's "workflow" list).
  defp collect_agent_attempts(%{"type" => "workflow_agent"} = node),
    do: [Map.get(node, "attempt")]

  defp collect_agent_attempts(map) when is_map(map),
    do: Enum.flat_map(Map.values(map), &collect_agent_attempts/1)

  defp collect_agent_attempts(list) when is_list(list),
    do: Enum.flat_map(list, &collect_agent_attempts/1)

  defp collect_agent_attempts(_), do: []

  describe "workflow_agent attempt==1 across every committed fixture (D21/D25 documented proof)" do
    test "every workflow_agent node — ndjson fixtures AND Go mirrors — carries attempt==1" do
      ndjson_attempts =
        @fixtures_dir
        |> Path.join("*.ndjson")
        |> Path.wildcard()
        |> Enum.map(&Path.basename/1)
        |> Enum.flat_map(fn name ->
          name |> load_ndjson() |> Enum.flat_map(&collect_agent_attempts/1)
        end)

      testdata_attempts =
        @testdata_dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path |> File.read!() |> Jason.decode!() |> collect_agent_attempts()
        end)

      all = ndjson_attempts ++ testdata_attempts

      # non-vacuous: the fixtures/mirrors that DO carry workflow_agent nodes were
      # actually visited (guards against a silent false-pass on an empty walk)
      assert length(all) > 0
      # and every collected value is a real retry counter of exactly 1 — no node
      # carries attempt>1 anywhere, and no missing/phantom attempt slipped in
      assert Enum.uniq(all) == [1],
             "a workflow_agent node carried attempt != 1: #{inspect(Enum.uniq(all))} — " <>
               "attempt>1 must never be fabricated (D21); rail_put_workflow is a bare Map.put"
    end

    test "the scoping is real — the non-workflow ndjson fixtures no-op, not false-pass" do
      no_workflow =
        ~w(background_tasks.ndjson foreground_task.ndjson interrupt_no_active_turn.ndjson
           mcp_permission_denied.ndjson mcp_tool_success.ndjson mid_turn_queued_user.ndjson
           transcript_workday.ndjson unauthed_stream.ndjson)

      for name <- no_workflow do
        attempts = name |> load_ndjson() |> Enum.flat_map(&collect_agent_attempts/1)
        assert attempts == [], "#{name} unexpectedly carried workflow_agent nodes"
      end
    end
  end

  describe "format_tokens/1 (charter D59)" do
    test "raw < 1k; one-decimal k < 10k; integer k < 1M; one-decimal M above" do
      assert StudioChat.format_tokens(845) == "845"
      assert StudioChat.format_tokens(9_645) == "9.6k"
      assert StudioChat.format_tokens(68_272) == "68k"
      assert StudioChat.format_tokens(145_000) == "145k"
      assert StudioChat.format_tokens(2_137_873) == "2.1M"
      # honest unknown, never a fake 0
      assert StudioChat.format_tokens(nil) == "—"
    end
  end

  # ── the needs-you strip (wave 12 — sidebar inbox) ──────────────────────────

  # Pin the activity stamp directly (bypassing the mutation helpers, whose
  # `utc_now()` stamps would make ordering-sensitive tests racy by microseconds).
  defp set_active(session_id, active) do
    {1, _} =
      Repo.update_all(
        from(s in Session, where: s.id == ^session_id),
        set: [last_active_at: active]
      )

    StudioChat.get_session(session_id)
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 60, :second)

  # A pending ask row of the given role, via the real append path (which also
  # bumps the session's denormalised pending_approvals — the store truth the
  # strip reads).
  defp seed_pending_ask(session, role, request_id) do
    {:ok, _} =
      StudioChat.append_message(session, %{
        role: role,
        metadata: %{"request_id" => request_id, "approval_status" => "pending"}
      })
  end

  describe "pending_ask_roles/1 (wave 12)" do
    test "groups PENDING needs-you roles per session; resolved asks don't count" do
      a = new_session()
      b = new_session()
      c = new_session()

      seed_pending_ask(a, "approval", "ra1")
      seed_pending_ask(a, "question", "ra2")
      seed_pending_ask(b, "plan", "rb1")
      # a RESOLVED ask is not pending — must not appear
      seed_pending_ask(c, "approval", "rc1")
      {:ok, _} = StudioChat.update_approval_status(c.id, "rc1", "allowed")

      roles = StudioChat.pending_ask_roles([a.id, b.id, c.id])

      assert Enum.sort(roles[a.id]) == ["approval", "question"]
      assert roles[b.id] == ["plan"]
      refute Map.has_key?(roles, c.id)
      assert StudioChat.pending_ask_roles([]) == %{}
    end
  end

  describe "strip_kind/3 — per-session derivation (wave 12, re-based on agent_state herd wave 1)" do
    test "pending ask roles map to kinds with approval > question > plan precedence" do
      s = new_session()
      seed_pending_ask(s, "approval", "r1")
      # the Recorder persists "blocked" when the ask flips needs_you (D38) —
      # the strip reads the COLUMN, not the pending counter
      {1, _} = StudioChat.set_agent_state(s.id, "blocked", :ask)
      s = StudioChat.get_session(s.id)

      assert StudioChat.strip_kind(s, ["plan", "question", "approval"], nil) ==
               :pending_approval

      assert StudioChat.strip_kind(s, ["plan", "question"], nil) == :awaiting_input
      assert StudioChat.strip_kind(s, ["plan"], nil) == :plan_ready
      # a blocked row with no known pending roles degrades to the generic
      # kind — never dropped
      assert StudioChat.strip_kind(s, [], nil) == :pending_approval
    end

    test "a live :needs_you overlay raises the kind even before the counter is re-read" do
      s = new_session()
      assert s.pending_approvals == 0

      assert StudioChat.strip_kind(s, [], %{state: :needs_you, line: "asking you"}) ==
               :pending_approval

      assert StudioChat.strip_kind(s, ["question"], %{state: :needs_you, line: "asking you"}) ==
               :awaiting_input
    end

    test "working: live overlay OR persisted agent_state alone (cold mount)" do
      s = new_session()
      assert StudioChat.strip_kind(s, [], %{state: :working, line: "writing…"}) == :working

      # the persisted column alone (cold mount) is enough
      {1, _} = StudioChat.set_agent_state(s.id, "working", :derived)
      s = set_active(s.id, minutes_ago(1))
      assert StudioChat.strip_kind(s, [], nil) == :working
    end

    test "a blocked row (pending ask) outranks a running-turn overlay" do
      s = new_session()
      seed_pending_ask(s, "approval", "r1")
      {1, _} = StudioChat.set_agent_state(s.id, "blocked", :ask)
      s = StudioChat.get_session(s.id)

      assert StudioChat.strip_kind(s, ["approval"], %{state: :working, line: "writing…"}) ==
               :pending_approval
    end

    test "a settled session is QUIET — the wave-12 unseen-finish kind is retired (herd, no read receipts)" do
      # settled (active) with recent activity → no strip entry
      s = set_active(new_session().id, minutes_ago(1))
      assert StudioChat.strip_kind(s, [], nil) == nil

      # exited is just as quiet — settling never surfaces a session
      {:ok, _} = StudioChat.update_status(s.id, "exited")
      s = set_active(s.id, minutes_ago(1))
      assert StudioChat.strip_kind(s, [], nil) == nil

      # ...and the retired kind is gone from the vocabulary entirely
      refute :finished_while_away in StudioChat.strip_kinds()
    end
  end

  describe "needs_you_strip/2 — cross-session aggregation (wave 12)" do
    test "COLD-MOUNT correct: kinds + priority order derive from persisted rows alone" do
      # working (persisted herd column — no overlay)
      working = new_session()
      {1, _} = StudioChat.set_agent_state(working.id, "working", :derived)
      working = StudioChat.get_session(working.id)

      # plan ready / awaiting input / pending approval: the pending ask rows
      # carry the KIND detail; the persisted "blocked" column carries the state
      plan = new_session()
      seed_pending_ask(plan, "plan", "rp")
      {1, _} = StudioChat.set_agent_state(plan.id, "blocked", :ask)
      question = new_session()
      seed_pending_ask(question, "question", "rq")
      {1, _} = StudioChat.set_agent_state(question.id, "blocked", :ask)
      approval = new_session()
      seed_pending_ask(approval, "approval", "rap")
      {1, _} = StudioChat.set_agent_state(approval.id, "blocked", :ask)

      # quiet: settled — no entry (unseen-finish tracking retired, herd)
      quiet = set_active(new_session().id, minutes_ago(2))

      sessions =
        Enum.map(
          [working.id, plan.id, question.id, approval.id, quiet.id],
          &StudioChat.get_session/1
        )

      strip =
        StudioChat.needs_you_strip(sessions,
          pending_roles: StudioChat.pending_ask_roles(Enum.map(sessions, & &1.id)),
          activity: %{}
        )

      assert Enum.map(strip, & &1.kind) ==
               [:pending_approval, :awaiting_input, :plan_ready, :working]

      assert Enum.map(strip, & &1.session.id) ==
               [approval.id, question.id, plan.id, working.id]

      refute Enum.any?(strip, &(&1.session.id == quiet.id))
    end

    test "the on-screen session is never 'away' — excluded even mid-ask" do
      s = new_session()
      seed_pending_ask(s, "approval", "r1")
      {1, _} = StudioChat.set_agent_state(s.id, "blocked", :ask)
      s = StudioChat.get_session(s.id)

      assert StudioChat.needs_you_strip([s],
               current_session_id: s.id,
               pending_roles: %{s.id => ["approval"]}
             ) == []

      # …and present for every OTHER viewer
      assert [%{kind: :pending_approval}] =
               StudioChat.needs_you_strip([s], pending_roles: %{s.id => ["approval"]})
    end

    test "within a kind, most recently active first" do
      older = new_session()
      {1, _} = StudioChat.set_agent_state(older.id, "working", :derived)
      older = set_active(older.id, minutes_ago(30))

      newer = new_session()
      {1, _} = StudioChat.set_agent_state(newer.id, "working", :derived)
      newer = set_active(newer.id, minutes_ago(5))

      assert [%{session: %{id: first}}, %{session: %{id: second}}] =
               StudioChat.needs_you_strip([older, newer])

      assert {first, second} == {newer.id, older.id}
    end

    test "the live overlay contributes the line and live arrive/leave kinds" do
      s = new_session()

      # arrive: a :working overlay surfaces the session with its live tool line
      assert [%{kind: :working, line: "Bash — mix test"}] =
               StudioChat.needs_you_strip([s],
                 activity: %{s.id => %{state: :working, line: "Bash — mix test"}}
               )

      # leave: overlay gone (idle deletes the entry) + settled row → no entry;
      # the strip yields to the store
      assert StudioChat.needs_you_strip([s], activity: %{}) == []
    end

    test "list_sessions carries the strip fields (select must not orphan the derivation)" do
      s = set_active(new_session().id, minutes_ago(2))

      # the herd column rides the sidebar select (herd wave 1): a select that
      # omitted it would feed the schema default ("idle") to every pill/strip
      {1, _} = StudioChat.set_agent_state(s.id, "working", :derived)
      listed = Enum.find(StudioChat.list_sessions(), &(&1.id == s.id))
      assert listed.agent_state == "working"
      assert %DateTime{} = listed.agent_state_at
      assert [%{kind: :working}] = StudioChat.needs_you_strip([listed])
    end

    test "strip_kinds/0 IS the priority order (S7's notification vocabulary)" do
      assert StudioChat.strip_kinds() ==
               [:pending_approval, :awaiting_input, :plan_ready, :working]
    end
  end

  describe "agent_state store writes (herd wave 1, charter D38–D41h)" do
    test "set_agent_state persists state + stamp in one update_all; the vocabulary is guarded" do
      s = new_session()
      assert s.agent_state == "idle"
      assert s.agent_state_at == nil

      assert {1, nil} = StudioChat.set_agent_state(s.id, "working", :derived)

      updated = StudioChat.get_session(s.id)
      assert updated.agent_state == "working"
      assert %DateTime{} = updated.agent_state_at

      # four states ONLY — "done" does not exist (herd doctrine)
      assert_raise FunctionClauseError, fn ->
        StudioChat.set_agent_state(s.id, "done", :derived)
      end
    end

    test "touch_agent_state_at bumps ONLY the liveness stamp — never the state" do
      s = new_session()
      seed_pending_ask(s, "approval", "touch-1")
      {1, _} = StudioChat.set_agent_state(s.id, "blocked", :ask)
      %{agent_state_at: at0} = StudioChat.get_session(s.id)

      {1, _} = StudioChat.touch_agent_state_at(s.id)

      touched = StudioChat.get_session(s.id)
      assert touched.agent_state == "blocked"
      assert DateTime.compare(touched.agent_state_at, at0) == :gt
    end

    test "the DB CHECK mirrors the four-state vocabulary (constraint, not just code)" do
      s = new_session()

      assert_raise Postgrex.Error, ~r/chat_sessions_agent_state_check/, fn ->
        Repo.update_all(
          from(x in Session, where: x.id == ^s.id),
          set: [agent_state: "done"]
        )
      end
    end

    test "resolving the LAST pending ask flips blocked→working; an earlier resolve keeps blocked" do
      s = new_session()
      seed_pending_ask(s, "approval", "ub-1")
      seed_pending_ask(s, "question", "ub-2")
      {1, _} = StudioChat.set_agent_state(s.id, "blocked", :ask)

      # one ask down, one still pending — the human is still needed
      {:ok, _} = StudioChat.update_approval_status(s.id, "ub-1", "allowed")
      assert StudioChat.get_session(s.id).agent_state == "blocked"

      # the LAST ask resolves: the turn resumes, the persisted state unblocks
      {:ok, _} = StudioChat.update_approval_status(s.id, "ub-2", "denied")
      assert StudioChat.get_session(s.id).agent_state == "working"
    end

    test "resolution never resurrects a non-blocked row (a dangling cancel after death)" do
      s = new_session()
      seed_pending_ask(s, "approval", "ub-3")
      # the Recorder already died mid-turn: the offline rule wrote "unknown"
      {1, _} = StudioChat.set_agent_state(s.id, "unknown", :derived)

      {:ok, _} = StudioChat.update_approval_status(s.id, "ub-3", "canceled")
      assert StudioChat.get_session(s.id).agent_state == "unknown"
    end
  end

  # A live execution-lease fence for `session_id` (herd-s6 fixtures): a real
  # registered host + a real chat_execution_leases row, because the :reported
  # corroboration is an in-WHERE EXISTS over that table — never a stub.
  defp lease_fence!(session_id, opts \\ []) do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Barkpark.Tenancy.create_workspace(%{slug: "s6-#{suffix}", name: "S6 #{suffix}"})
    {:ok, %{host: host}} = Barkpark.ChatHosts.issue_enrollment(ws.id, %{name: "reporter"})

    {:ok, lease} =
      %Barkpark.ChatHosts.ExecutionLease{}
      |> Barkpark.ChatHosts.ExecutionLease.changeset(%{
        host_id: host.id,
        workspace_id: ws.id,
        session_id: session_id,
        provider: "claude",
        command_key: "ck-#{suffix}",
        status: Keyword.get(opts, :status, "running"),
        expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
      })
      |> Repo.insert()

    lease
  end

  describe "blocked-source guard at the choke point (herd-s6, charter D80h)" do
    test "blocked with :ask is corroborated IN-WHERE: pending_approvals==0 writes {0, nil}" do
      s = new_session()

      # MUTATION-PROVEN guard: a declared :ask with no pending ask row writes
      # NOTHING — remove the corroboration WHERE and this red-lines.
      assert {0, nil} = StudioChat.set_agent_state(s.id, "blocked", :ask)
      assert StudioChat.get_session(s.id).agent_state == "idle"

      # …and the SAME call with real store evidence writes.
      seed_pending_ask(s, "approval", "bsg-1")
      assert {1, nil} = StudioChat.set_agent_state(s.id, "blocked", :ask)
      assert StudioChat.get_session(s.id).agent_state == "blocked"
    end

    test "blocked with :reported demands a LIVE lease fence: a self-report without one writes {0, nil}" do
      s = new_session()

      # no lease at all → nothing written
      assert {0, nil} = StudioChat.set_agent_state(s.id, "blocked", :reported)
      assert StudioChat.get_session(s.id).agent_state == "idle"

      # an EXPIRED lease is not a fence either (the dead-reporter clock)
      _expired =
        lease_fence!(s.id, expires_at: DateTime.add(DateTime.utc_now(), -5, :second))

      assert {0, nil} = StudioChat.set_agent_state(s.id, "blocked", :reported)

      # a live leased/running lease IS the corroboration
      _live = lease_fence!(s.id)
      assert {1, nil} = StudioChat.set_agent_state(s.id, "blocked", :reported)
      assert StudioChat.get_session(s.id).agent_state == "blocked"
    end

    test "no heuristic blocked: :derived-blocked and any unlisted source raise" do
      s = new_session()

      # blocked is NEVER a derived/heuristic write — only :ask or :reported
      assert_raise FunctionClauseError, fn ->
        StudioChat.set_agent_state(s.id, "blocked", :derived)
      end

      # an unlisted source raises for EVERY state — the vocabulary of writers
      # is closed, exactly like the four-state vocabulary itself
      assert_raise FunctionClauseError, fn ->
        StudioChat.set_agent_state(s.id, "working", :heuristic)
      end

      assert_raise FunctionClauseError, fn ->
        StudioChat.set_agent_state(s.id, "blocked", :sweep)
      end
    end

    test "census tripwire: every agent_state update_all lives in studio_chat.ex; the literal blocked write only in set_agent_state" do
      lib = Path.expand("../../lib", __DIR__)
      files = Path.wildcard(Path.join(lib, "**/*.ex"))
      assert files != [], "census must scan a real lib tree"

      set_writers =
        for f <- files,
            Regex.match?(~r/set:\s*\[[^\]]*\bagent_state:/, File.read!(f)),
            do: Path.relative_to(f, lib)

      assert set_writers == ["barkpark/studio_chat.ex"],
             "agent_state update_all writes must funnel through studio_chat.ex, found: #{inspect(set_writers)}"

      blocked_writers =
        for f <- files,
            String.contains?(File.read!(f), ~s(agent_state: "blocked")),
            do: Path.relative_to(f, lib)

      assert blocked_writers == ["barkpark/studio_chat.ex"],
             ~s(the literal blocked write may exist only in set_agent_state, found: #{inspect(blocked_writers)})
    end
  end

  describe "tenant seam — owner_workspace_id scope (Connectors epic wave 1, D14/D15/D17/D19b)" do
    test "create_session stamps owner_workspace_id from scope ({:workspace,ws}=>ws, :global=>nil)" do
      ws_a = ws()

      tenant = owned_session({:workspace, ws_a})
      assert tenant.owner_workspace_id == ws_a

      # :global (the default) and an unscoped create both stamp NULL — the admin
      # / legacy session, invisible to any workspace-scoped caller.
      global = owned_session(:global)
      assert is_nil(global.owner_workspace_id)

      {:ok, defaulted} = StudioChat.create_session(%{id: Ecto.UUID.generate()})
      assert is_nil(defaulted.owner_workspace_id)

      # A bare workspace binary is accepted defensively (same stamp as the tuple).
      bare = owned_session(ws_a)
      assert bare.owner_workspace_id == ws_a
    end

    test "get_session is fail-closed: ws-B cannot see a ws-A-owned session, :global + ws-A can" do
      ws_a = ws()
      ws_b = ws()
      a = owned_session({:workspace, ws_a})

      # Owner and the global superuser resolve it…
      assert StudioChat.get_session(a.id, ws_a).id == a.id
      assert StudioChat.get_session(a.id, :global).id == a.id
      # …a foreign workspace and a nil scope get nil (indistinguishable from missing).
      assert StudioChat.get_session(a.id, ws_b) == nil
      assert StudioChat.get_session(a.id, nil) == nil

      # A :global (NULL-owner) session is admin-only: no workspace scope sees it
      # (a NULL never matches the owner_workspace_id equality — legacy rows stay
      # invisible without a blanket is_nil carve-out).
      g = owned_session(:global)
      assert StudioChat.get_session(g.id, :global).id == g.id
      assert StudioChat.get_session(g.id, ws_a) == nil
    end

    test "get_session_with_messages honours the scope gate" do
      ws_a = ws()
      ws_b = ws()
      a = owned_session({:workspace, ws_a})
      {:ok, _} = StudioChat.append_message(a, %{role: "user", source_markdown: "secret"})

      assert %Session{} = StudioChat.get_session_with_messages(a.id, ws_a)
      assert StudioChat.get_session_with_messages(a.id, ws_b) == nil
    end

    test "list_sessions is scoped: each workspace sees only its own; :global sees all" do
      ws_a = ws()
      ws_b = ws()
      a = owned_session({:workspace, ws_a})
      b = owned_session({:workspace, ws_b})
      g = owned_session(:global)

      a_ids = StudioChat.list_sessions([], ws_a) |> Enum.map(& &1.id)
      assert a.id in a_ids
      refute b.id in a_ids
      refute g.id in a_ids

      b_ids = StudioChat.list_sessions([], ws_b) |> Enum.map(& &1.id)
      assert b.id in b_ids
      refute a.id in b_ids

      global_ids = StudioChat.list_sessions([], :global) |> Enum.map(& &1.id)
      assert a.id in global_ids
      assert b.id in global_ids
      assert g.id in global_ids

      # a nil scope is fail-closed — zero rows, never a cross-tenant leak.
      assert StudioChat.list_sessions([], nil) == []
    end

    test "list_messages is fail-closed: ws-B reads [] on a ws-A session; :global + ws-A read it" do
      ws_a = ws()
      ws_b = ws()
      a = owned_session({:workspace, ws_a})
      {:ok, _} = StudioChat.append_message(a, %{role: "user", source_markdown: "one"})
      {:ok, _} = StudioChat.append_message(a, %{role: "assistant", source_markdown: "two"})

      assert length(StudioChat.list_messages(a.id, :global)) == 2
      assert length(StudioChat.list_messages(a.id, ws_a)) == 2
      # foreign tenant: no transcript leak.
      assert StudioChat.list_messages(a.id, ws_b) == []
      # the scoped LIMIT form (charter D17 "+/2 limit threads it") is gated too.
      assert length(StudioChat.list_messages(a.id, 1, ws_a)) == 1
      assert StudioChat.list_messages(a.id, 1, ws_b) == []
    end

    test "delete_session is fail-closed: ws-B cannot delete a ws-A session; ws-A can" do
      ws_a = ws()
      ws_b = ws()
      a = owned_session({:workspace, ws_a})

      # foreign workspace: no-op, the row survives.
      assert :noop = StudioChat.delete_session(a.id, ws_b)
      assert StudioChat.get_session(a.id, ws_a).id == a.id

      # owner deletes it for real.
      assert {:ok, %Session{}} = StudioChat.delete_session(a.id, ws_a)
      assert StudioChat.get_session(a.id, :global) == nil
    end

    test "archive/unarchive are fail-closed against a foreign workspace" do
      ws_a = ws()
      ws_b = ws()
      a = owned_session({:workspace, ws_a})

      # ws-B cannot archive ws-A's session — no-op, archived_at stays nil.
      assert :noop = StudioChat.archive_session(a.id, ws_b)
      assert is_nil(StudioChat.get_session(a.id, ws_a).archived_at)

      # owner archives, then ws-B cannot unarchive it back.
      {:ok, archived} = StudioChat.archive_session(a.id, ws_a)
      assert archived.archived_at != nil
      assert :noop = StudioChat.unarchive_session(a.id, ws_b)

      {:ok, unarchived} = StudioChat.unarchive_session(a.id, ws_a)
      assert is_nil(unarchived.archived_at)
    end

    test "back-compat: the default scope is :global — every legacy call site is unchanged" do
      s = new_session()
      {:ok, _} = StudioChat.append_message(s, %{role: "user", source_markdown: "hi"})

      # /1 + /2-limit legacy arities keep resolving globally.
      assert StudioChat.get_session(s.id).id == s.id
      assert Enum.any?(StudioChat.list_sessions(), &(&1.id == s.id))
      assert length(StudioChat.list_messages(s.id)) == 1
      assert length(StudioChat.list_messages(s.id, 1)) == 1
    end
  end
end
