defmodule Barkpark.Tasks.BoardTest do
  @moduledoc """
  Field-visibility seal for `Barkpark.Tasks.Board` — the sibling of the peek
  seal (`board_live_test.exs` "peek field-visibility seal (Envelope gate)").

  `Board.snapshot/1` hand-picks content fields straight off the raw `type:task`
  doc in `to_card/4` — unlike the sanctioned `tasks/query.ex` read path, nothing
  here rides `Envelope.render`. So without the Envelope cross-check a
  schema-declared PRIVATE field would leak through the deck card AND every
  derived copy (`family_walk/4`'s tree rows / the gantt, `focus_of/1`'s focus
  line) to any board viewer.

  These tests seed a `task` schema (the SAME one `snapshot/1` resolves via
  `Content.get_schema/3`) that marks the two text-bearing content fields
  (`description`, `acceptance_criteria`) private, plus a doc carrying them, and
  assert the projection OMITS them. They are mutation-proven: strip the
  `if(readable?...)` gate from `Board.to_card/4` and the private text reappears
  in `description_excerpt` / `criteria_list` / `next_criterion` (and, through
  them, in the family rows the gantt paints) — these assertions go RED.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board

  setup do
    # HERMETIC GUARD (mirrors board_live_test): `snapshot/1` reads the WHOLE
    # `type:task` corpus GLOBALLY, so any committed stray (an `unboxed_run`
    # fixture a killed run stranded) would poison the exact-card assertions.
    # This delete rolls back with the test's sandbox transaction.
    Repo.delete_all(from(d in Document, where: d.type == "task"))
    :ok
  end

  # A `task` schema declaring `description` + `acceptance_criteria` PRIVATE and
  # leaving `labels` / `priority` UNDECLARED (legacy-parity control).
  defp seal_schema! do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "task",
          "title" => "Task",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "description",
              "title" => "Body",
              "type" => "text",
              "visibility" => "private"
            },
            %{
              "name" => "acceptance_criteria",
              "title" => "Criteria",
              "type" => "array",
              "visibility" => "private"
            }
          ]
        },
        "production"
      )

    :ok
  end

  defp task!(doc_id, title, content) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: "production",
      status: "published",
      title: title,
      rev: "rev-#{doc_id}",
      content: Map.put(content, "lifecycle_status", content["lifecycle_status"] || "open")
    })
  end

  describe "snapshot/1 field-visibility seal (deck card)" do
    setup do
      seal_schema!()

      task!("sec-task", "Sealed task", %{
        "lifecycle_status" => "in_progress",
        "description" => "SECRET-BODY-should-not-leak",
        "acceptance_criteria" => [
          %{"criterion" => "SECRET-CRITERION", "met" => false, "evidence" => ""},
          %{"criterion" => "SECRET-CRITERION-2", "met" => true, "evidence" => "done"}
        ]
      })

      :ok
    end

    test "a schema-private text field is OMITTED from the deck card" do
      board = Board.snapshot(dataset: "production")
      card = board.cards_by_id["sec-task"]

      assert card, "the sealed task must still appear on the board"
      # The always-public title survives...
      assert card.title == "Sealed task"

      # ...but every private text-bearing projection is redacted. `description`
      # private ⇒ description_excerpt nil; `acceptance_criteria` private ⇒ both
      # readers of its raw text (criteria_list AND next_criterion) nil. Removing
      # the gate makes the SECRET text reappear here — the mutation bites.
      assert card.description_excerpt == nil
      assert card.criteria_list == nil
      assert card.next_criterion == nil
    end

    test "the derived criteria COUNT stays UNGATED (pure %{met,total}, never text)" do
      board = Board.snapshot(dataset: "production")
      card = board.cards_by_id["sec-task"]

      # The count is a pure tally — it carries no criterion text, so the peek's
      # own count-vs-text law leaves it public even when the text is sealed.
      assert card.criteria == %{met: 1, total: 2}
    end
  end

  describe "snapshot/1 field-visibility seal (gantt / family rows inherit)" do
    setup do
      seal_schema!()

      # A family: an in_progress root + an in_progress child, BOTH carrying the
      # private text. The gantt (`gantt_data/1`) reads the ROOT card's
      # `criteria_list`; the family rows (`family_walk/4`) read each in-flight
      # CHILD's `description_excerpt` + `criteria_list`. Both must inherit the
      # to_card/4 redaction — never re-read the raw doc.
      task!("fam-root", "Family root", %{
        "lifecycle_status" => "in_progress",
        "description" => "SECRET-ROOT-BODY",
        "acceptance_criteria" => [%{"criterion" => "SECRET-ROOT-CRIT", "met" => false}]
      })

      task!("fam-child", "Family child", %{
        "lifecycle_status" => "in_progress",
        "parent_id" => "fam-root",
        "description" => "SECRET-CHILD-BODY",
        "acceptance_criteria" => [%{"criterion" => "SECRET-CHILD-CRIT", "met" => false}]
      })

      :ok
    end

    test "the family root card carries no private text for the gantt to paint" do
      board = Board.snapshot(dataset: "production")
      root = board.cards_by_id["fam-root"]

      # gantt_data/1 builds its root row from card[:criteria_list] (and the
      # family rows from the child cards) — both nil here, so nothing to leak.
      assert root.criteria_list == nil
      assert root.description_excerpt == nil
      assert root.next_criterion == nil
    end

    test "the family tree rows omit each in-flight child's private text" do
      board = Board.snapshot(dataset: "production")
      view = Board.view(board)

      child_row =
        view.lanes
        |> Enum.flat_map(fn lane -> Map.values(lane.columns) end)
        |> List.flatten()
        |> Enum.flat_map(fn card -> (card[:family] && card.family.rows) || [] end)
        |> Enum.find(fn row -> row.doc_id == "fam-child" end)

      assert child_row, "the in-flight child must appear as a family row"

      # `family_walk/4` populates `desc`/`crits` for in-flight rows straight
      # from the child card's gated fields — redacted to nil here. Strip the
      # to_card/4 gate and "SECRET-CHILD-BODY" / "SECRET-CHILD-CRIT" leak into
      # the gantt through these keys → RED.
      assert child_row.desc == nil
      assert child_row.crits == nil
    end
  end

  describe "snapshot/1 safety cap (felix W25 — bounded HTTP reader, unbounded LiveView twin)" do
    # NAMED FAILURE MODE: `load_task_docs/1` re-runs an unbounded `Repo.all` over
    # the whole `type:task` corpus every 15s per connected Studio board socket.
    # This proves the safety cap `@snapshot_max` (config-overridable) bounds the
    # scan. MUTATION: drop `limit: ^snapshot_max()` from `load_task_docs/1` and
    # `map_size(board.cards_by_id)` becomes cap+1 → this assertion REDS; with the
    # bound in place it caps at `cap` → GREENS.
    test "load_task_docs caps the corpus scan at the config-overridable bound" do
      cap = 3
      prev = Application.get_env(:barkpark, :board_snapshot_max)
      Application.put_env(:barkpark, :board_snapshot_max, cap)
      on_exit(fn -> restore_env(:board_snapshot_max, prev) end)

      # cap + 1 DISTINCT, LIVE (non-cancelled), NON-TWIN task docs — distinct
      # doc_ids so no draft/published collapse folds them, so each is its own
      # card. Unbounded, all cap+1 reach cards_by_id; capped, at most `cap` do.
      for i <- 1..(cap + 1) do
        task!("cap-task-#{i}", "Cap task #{i}", %{"lifecycle_status" => "open"})
      end

      board = Board.snapshot(dataset: "production")

      assert map_size(board.cards_by_id) <= cap,
             "the safety cap must bound cards_by_id to #{cap}, got #{map_size(board.cards_by_id)}"
    end
  end

  # Restore an Application env key to its prior state (delete when it had none).
  defp restore_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_env(key, prev), do: Application.put_env(:barkpark, key, prev)

  describe "snapshot/1 field-visibility seal (legacy parity — selective, not blanket)" do
    test "an UNDECLARED field stays public (the gate reads the schema, not a blanket redaction)" do
      seal_schema!()

      # `labels` and `priority` are undeclared in the seeded schema ⇒
      # field_readable? true ⇒ they project normally. Proves the seal is
      # selective — it redacts only what the schema marks private.
      task!("pub-task", "Public-fielded task", %{
        "lifecycle_status" => "open",
        "labels" => ["urgent-label"],
        "priority" => 1,
        "description" => "SECRET-BODY"
      })

      board = Board.snapshot(dataset: "production")
      card = board.cards_by_id["pub-task"]

      assert card.labels == ["urgent-label"]
      assert card.priority == 1
      # ...while the declared-private description is still sealed.
      assert card.description_excerpt == nil
    end

    test "with NO task schema, every field is undeclared ⇒ public (nil-schema parity)" do
      # No seal_schema!/0 — snapshot's get_schema misses, the gate falls to
      # allow-all, and legacy behavior is preserved (no crash, text projects).
      task!("noschema-task", "No-schema task", %{
        "lifecycle_status" => "in_progress",
        "description" => "VISIBLE-BODY",
        "acceptance_criteria" => [%{"criterion" => "VISIBLE-CRIT", "met" => false}]
      })

      board = Board.snapshot(dataset: "production")
      card = board.cards_by_id["noschema-task"]

      assert card.description_excerpt == "VISIBLE-BODY"
      assert card.next_criterion == "VISIBLE-CRIT"
      assert [%{text: "VISIBLE-CRIT"}] = card.criteria_list
    end
  end
end
