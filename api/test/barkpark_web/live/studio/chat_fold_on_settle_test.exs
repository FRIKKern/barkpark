defmodule BarkparkWeb.Studio.ChatFoldOnSettleTest do
  @moduledoc """
  THE TURN FOLD, unit half (task-8f904a88b9bc3d59).

  A settled turn's tool rows collapse under ONE header row — "Worked for 3m 12s",
  or "You stopped after 42s" when a Stop ended the turn — on BOTH transcripts.
  This suite owns the parts that need no LiveView:

    * the SERVER STAMP — `StudioChat.turn_settle_stamp/1` (the ONE builder both
      the Recorder's durable write and Studio's live mirror call) and
      `settle_tool_rows/2` (the durable write, and what a reopen reads back);
    * the WIRE — `ChatController.message_json/1` ships the stamp verbatim, which
      is the whole reason `bp chat` can fold without a second endpoint;
    * the LABEL — byte-locked to the Go formatter by the SHARED fixture
      `test/support/fixtures/chat_fold_labels.json`, which `internal/chat/
      fold_test.go` reads too. Change one formatter and the OTHER surface reds;
    * the GROUPING — `ChatLive.fold_settled_turns/1`, the pass that turns a
      settled turn's consecutive rows into one fold item.

  The LiveView half (settle→fold, interrupt→label, live→unfolded, expand on
  click) lives in `chat_live_test.exs`'s own fold describe.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.StudioChat
  alias BarkparkWeb.ChatController
  alias BarkparkWeb.Studio.ChatLive
  alias BarkparkWeb.Studio.ChatToolRenderer

  @label_fixture Path.expand("../../../support/fixtures/chat_fold_labels.json", __DIR__)

  defp new_session do
    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate()})
    session
  end

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

  # ── the shared label lock ───────────────────────────────────────────────────

  describe "fold_label/2 against the SHARED cross-surface fixture" do
    test "every fixture case matches byte for byte" do
      cases = @label_fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

      # A vacuous lock proves nothing: the fixture must actually carry cases,
      # and `internal/chat/fold_test.go` asserts the same floor on its side.
      assert length(cases) > 0

      for %{"duration_ms" => ms, "outcome" => outcome, "label" => label} <- cases do
        assert ChatToolRenderer.fold_label(outcome, ms) == label,
               "fold_label(#{inspect(outcome)}, #{ms}) drifted from the shared fixture"
      end
    end

    test "the label reads the row's SERVER-stamped facts, never a local clock" do
      assert ChatToolRenderer.fold_label(%{turn_outcome: "settled", turn_duration_ms: 192_000}) ==
               "Worked for 3m 12s"

      assert ChatToolRenderer.fold_label(%{
               turn_outcome: "interrupted",
               turn_duration_ms: 42_000
             }) == "You stopped after 42s"

      # A row from a server too old to stamp the duration degrades to an honest
      # zero — never a blank header, never a raise.
      assert ChatToolRenderer.fold_label(%{}) == "Worked for 0s"
    end
  end

  # ── the server stamp ────────────────────────────────────────────────────────

  describe "turn_settle_stamp/1 — the ONE builder both surfaces call" do
    test "a settled turn stamps both instants, the wall-clock duration, and the outcome" do
      started = ~U[2026-09-02T10:00:00.000000Z]
      settled = ~U[2026-09-02T10:03:12.000000Z]

      stamp =
        StudioChat.turn_settle_stamp(%{
          started_at: started,
          settled_at: settled,
          interrupted?: false
        })

      assert stamp["turn_settled"] == true
      assert stamp["turn_outcome"] == "settled"
      assert stamp["turn_duration_ms"] == 192_000
      assert stamp["turn_started_at"] == DateTime.to_iso8601(started)
      assert stamp["turn_settled_at"] == DateTime.to_iso8601(settled)
    end

    test "a Stop stamps interrupted" do
      stamp = StudioChat.turn_settle_stamp(%{duration_ms: 42_000, interrupted?: true})
      assert stamp["turn_outcome"] == "interrupted"
      assert stamp["turn_duration_ms"] == 42_000
    end

    test "with no started_at the runtime's OWN duration is the fallback, and no instant is faked" do
      stamp = StudioChat.turn_settle_stamp(%{duration_ms: 5_000})
      assert stamp["turn_duration_ms"] == 5_000
      refute Map.has_key?(stamp, "turn_started_at")
      assert is_binary(stamp["turn_settled_at"])
    end

    test "a clock that stepped backwards reads 0s, never a negative turn" do
      stamp =
        StudioChat.turn_settle_stamp(%{
          started_at: ~U[2026-09-02T10:03:12Z],
          settled_at: ~U[2026-09-02T10:00:00Z]
        })

      assert stamp["turn_duration_ms"] == 0
    end
  end

  describe "settle_tool_rows/2 — the durable write a reopen reads back" do
    test "the whole stamp lands on every unsettled row of the turn, in ONE statement" do
      s = new_session()
      tool_row(s, "t-a")
      tool_row(s, "t-b")

      stamp =
        StudioChat.turn_settle_stamp(%{
          started_at: ~U[2026-09-02T10:00:00.000000Z],
          settled_at: ~U[2026-09-02T10:03:12.000000Z]
        })

      assert 2 == StudioChat.settle_tool_rows(s.id, stamp)

      for id <- ["t-a", "t-b"] do
        meta = meta_for(s.id, id)
        assert meta["turn_settled"] == true
        assert meta["turn_outcome"] == "settled"
        assert meta["turn_duration_ms"] == 192_000
        assert meta["turn_settled_at"] == "2026-09-02T10:03:12.000000Z"
      end
    end

    test "EXACTLY ONCE: a second terminal frame relabels nothing" do
      s = new_session()
      tool_row(s, "t-once")

      first = StudioChat.turn_settle_stamp(%{duration_ms: 192_000})
      assert 1 == StudioChat.settle_tool_rows(s.id, first)
      stamped = meta_for(s.id, "t-once")

      # The next turn's stamp must not reach back and rewrite this turn's rows —
      # the WHERE excludes an already-settled row, so the count is 0 and the
      # bytes are untouched.
      later = StudioChat.turn_settle_stamp(%{duration_ms: 42_000, interrupted?: true})
      assert 0 == StudioChat.settle_tool_rows(s.id, later)

      assert meta_for(s.id, "t-once") == stamped
      assert stamped["turn_duration_ms"] == 192_000
      assert stamped["turn_outcome"] == "settled"
    end

    test "the merge PRESERVES the row's other envelope facts" do
      s = new_session()
      tool_row(s, "t-merge")
      StudioChat.attach_tool_result(s.id, "t-merge", "a.txt", false)

      assert 1 == StudioChat.settle_tool_rows(s.id, StudioChat.turn_settle_stamp(%{}))

      meta = meta_for(s.id, "t-merge")
      # `||` merges, it does not replace: the settle-gated gutter's own facts and
      # the D38 diff input survive the fold stamp landing on top of them.
      assert meta["output"] == "a.txt"
      assert meta["tool"] == "Bash"
      assert meta["tool_use_id"] == "t-merge"
      assert meta["turn_settled"] == true
    end

    test "the bare arity-1 call still settles — the pre-fold contract is intact" do
      s = new_session()
      tool_row(s, "t-bare")
      assert 1 == StudioChat.settle_tool_rows(s.id)
      assert meta_for(s.id, "t-bare")["turn_settled"] == true
    end
  end

  describe "message_json/1 ships the fold facts to bp chat" do
    test "the stamp rides the wire verbatim — no projection, no second endpoint" do
      s = new_session()
      tool_row(s, "t-wire")
      StudioChat.settle_tool_rows(s.id, StudioChat.turn_settle_stamp(%{duration_ms: 192_000}))

      row = StudioChat.list_messages(s.id) |> Enum.find(&(&1.metadata["tool_use_id"] == "t-wire"))
      json = ChatController.message_json(row)

      assert json.metadata["turn_settled"] == true
      assert json.metadata["turn_outcome"] == "settled"
      assert json.metadata["turn_duration_ms"] == 192_000
      assert is_binary(json.metadata["turn_settled_at"])
    end
  end

  # ── the grouping pass ───────────────────────────────────────────────────────

  describe "turn_fold_key/1 — the fold's group key IS the turn" do
    test "an unsettled row has no key, which is what makes a LIVE turn unfoldable" do
      assert ChatToolRenderer.turn_fold_key(%{turn_settled: false, turn_settled_at: "t"}) == nil
    end

    test "a settled row keys on the turn's settled_at" do
      assert ChatToolRenderer.turn_fold_key(%{turn_settled: true, turn_settled_at: "t1"}) == "t1"
    end

    test "a settled row from a server too old to stamp the fold facts has no key" do
      assert ChatToolRenderer.turn_fold_key(%{turn_settled: true}) == nil
      assert ChatToolRenderer.turn_fold_key(%{turn_settled: true, turn_settled_at: ""}) == nil
    end
  end

  describe "fold_settled_turns/1 — one fold item per settled turn" do
    defp row(id, opts) do
      {:row,
       Map.merge(
         %{id: id, role: :tool, turn_settled: false, turn_outcome: nil, turn_duration_ms: nil},
         Map.new(opts)
       )}
    end

    test "a LIVE turn's rows pass through untouched" do
      items = [row(1, []), row(2, [])]
      assert ChatLive.fold_settled_turns(items) == items
    end

    test "a settled turn's consecutive rows become ONE fold carrying its label" do
      items = [
        row(1,
          turn_settled: true,
          turn_settled_at: "t1",
          turn_outcome: "settled",
          turn_duration_ms: 192_000
        ),
        row(2,
          turn_settled: true,
          turn_settled_at: "t1",
          turn_outcome: "settled",
          turn_duration_ms: 192_000
        )
      ]

      assert [{:turn_fold, "t1", "Worked for 3m 12s", rows}] = ChatLive.fold_settled_turns(items)
      assert length(rows) == 2
    end

    test "two turns are two folds — never one merged header" do
      items = [
        row(1,
          turn_settled: true,
          turn_settled_at: "t1",
          turn_outcome: "settled",
          turn_duration_ms: 192_000
        ),
        row(2,
          turn_settled: true,
          turn_settled_at: "t2",
          turn_outcome: "interrupted",
          turn_duration_ms: 42_000
        )
      ]

      assert [
               {:turn_fold, "t1", "Worked for 3m 12s", [_]},
               {:turn_fold, "t2", "You stopped after 42s", [_]}
             ] = ChatLive.fold_settled_turns(items)
    end

    test "a non-tool row and a D46 agent block BREAK the run" do
      settled = [
        turn_settled: true,
        turn_settled_at: "t1",
        turn_outcome: "settled",
        turn_duration_ms: 1_000
      ]

      items = [
        row(1, settled),
        {:row, %{id: 2, role: :assistant}},
        row(3, settled),
        {:agent, %{id: 4, role: :tool, tool_use_id: "spawn"}, []},
        row(5, settled)
      ]

      folded = ChatLive.fold_settled_turns(items)

      assert [
               {:turn_fold, "t1", _, [_]},
               {:row, %{role: :assistant}},
               {:turn_fold, "t1", _, [_]},
               {:agent, _, []},
               {:turn_fold, "t1", _, [_]}
             ] = folded
    end

    test "an empty transcript folds to nothing" do
      assert ChatLive.fold_settled_turns([]) == []
    end
  end
end
