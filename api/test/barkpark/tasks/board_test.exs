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

  describe "snapshot/1 draft label contract (PDS-D749)" do
    # NAMED FAILURE MODE: `to_card/4` keys the card by
    # `Content.published_id(doc.doc_id)`, which DESTROYS the `drafts.` prefix —
    # the only signal a row is not published — and used to print nothing in its
    # place. Every reader downstream of this projection therefore painted an
    # unpaired draft as an ordinary card. The fix reads the spelling off the RAW
    # `doc.doc_id`, through `DraftId.draft?/1` (the single owner of the prefix
    # rule), and carries it as `:draft`.
    #
    # The two arms are deliberately asymmetric under the mutation "derive the
    # flag from the card's own (already-stripped) doc_id instead of the raw one":
    #
    #   * the DRAFT arm goes RED (true → false),
    #   * the PUBLISHED arm stays QUIET (false → false) — it reds only on the
    #     other way to get this wrong, a flag that is true for everything.

    defp label_task!(doc_id, title, status) do
      Repo.insert!(%Document{
        doc_id: doc_id,
        type: "task",
        dataset: "production",
        status: status,
        title: title,
        rev: "rev-#{doc_id}",
        content: %{"lifecycle_status" => "open"}
      })
    end

    test "an unpaired drafts. row's card carries draft: true" do
      label_task!("drafts.label-solo", "Solo draft", "draft")

      card = Board.snapshot(dataset: "production").cards_by_id["label-solo"]

      assert card != nil, "the unpaired draft must survive the collapse"

      assert card.doc_id == "label-solo",
             "the card's own doc_id is still the PUBLISHED id — the spelling is gone from it"

      assert card.draft == true,
             "the drafts. spelling must survive Content.published_id/1 as the :draft flag"
    end

    test "a published row's card carries draft: false, not a missing key" do
      label_task!("label-pub", "Published row", "published")

      card = Board.snapshot(dataset: "production").cards_by_id["label-pub"]

      assert Map.has_key?(card, :draft),
             "the card is a fixed-shape projection — :draft is always present"

      assert card.draft == false
    end

    test "the flag follows the SPELLING, not the physical status" do
      # A `drafts.`-spelled row that is physically `status: \"published\"` (the
      # shape a mutate-created row can take) is STILL a draft row: PDS-D749 names
      # the prefix as the sole discriminator, so a status read here would be a
      # second, disagreeing rule.
      label_task!("drafts.label-mixed", "Spelled draft, stored published", "published")

      card = Board.snapshot(dataset: "production").cards_by_id["label-mixed"]

      assert card.draft == true
    end

    test "card_from_broadcast/3 derives the flag from the RAW broadcast doc_id" do
      # The realtime path never touches the DB, so it must read the spelling off
      # the event itself — before its own `Content.published_id/1` call.
      readable? = fn _ -> true end

      draft =
        Board.card_from_broadcast(
          %{
            doc_id: "drafts.bc-draft",
            title: "Draft over the wire",
            status: "draft",
            content: %{"lifecycle_status" => "open"},
            updated_at: DateTime.utc_now()
          },
          nil,
          readable?
        )

      published =
        Board.card_from_broadcast(
          %{
            doc_id: "bc-pub",
            title: "Published over the wire",
            status: "published",
            content: %{"lifecycle_status" => "open"},
            updated_at: DateTime.utc_now()
          },
          nil,
          readable?
        )

      assert draft.doc_id == "bc-draft", "the card keys by the published id, as snapshot does"
      assert draft.draft == true
      assert published.draft == false
    end
  end

  describe "snapshot/1 twin collapse (TwinCollapse.canonical/1 — published wins, unpaired draft is the row of record)" do
    # NAMED FAILURE MODE: `load_task_docs/1` groups the corpus by
    # `Content.published_id/1` and hands each bucket to `canonical_twin/1`. Before
    # the tie-break, that function was
    #
    #     Enum.find(twins, hd(twins), fn d -> d.status == "published" end)
    #
    # and the `hd(twins)` DEFAULT — reached whenever a bucket holds no published
    # row — read Postgres STORAGE ORDER off an `ORDER BY`-less `Repo.all`.
    #
    # The two arms below pin the policy in BOTH directions and are deliberately
    # asymmetric under mutation:
    #
    #   * "a PAIRED bucket yields the PUBLISHED row" pins the COLLAPSE: it reds
    #     when `load_task_docs/1` stops grouping by `Content.published_id/1` and
    #     both twins reach the board. It measures the COLUMNS, not
    #     `cards_by_id` — `to_card/4` keys every card by the published id, so
    #     both twins land on the SAME key and `map_size(cards_by_id)` is 1
    #     whether or not anything collapsed. A count taken there is vacuous.
    #   * "an UNPAIRED drafts. row resolves as itself" is the QUIET arm — it
    #     passes straight through a lost published preference (a one-member
    #     bucket has no preference to express) and reds only on a BLANKET
    #     `drafts.` drop, which is the OTHER way to get this wrong: it would
    #     make the whole mutate-created population unreadable.
    #   * "with NO published row the winner is the RULE" reds on the pre-
    #     tie-break `Enum.find(twins, hd(twins), …)`, i.e. on storage order.
    #   * "rule 1 decides when the published row is the drafts.-spelled one" is
    #     the ONLY arm that reds when the `d.status == "published"` clause is
    #     deleted. In every bucket a normal corpus produces the published copy
    #     is the BARE id, so rule 2 agrees with rule 1 and hides it; without
    #     this arm the headline policy (published wins) is pinned by nothing.
    #
    # No arm names a line number.

    # Like `task!/3` but lets the caller choose the physical `status`, which is
    # the whole subject here.
    defp twin_task!(doc_id, title, status, content \\ %{}) do
      Repo.insert!(%Document{
        doc_id: doc_id,
        type: "task",
        dataset: "production",
        status: status,
        title: title,
        rev: "rev-#{doc_id}",
        content: Map.put(content, "lifecycle_status", content["lifecycle_status"] || "open")
      })
    end

    test "a PAIRED bucket yields the PUBLISHED row, never the draft twin" do
      # DRAFT FIRST on purpose: with the published preference deleted, `hd/1`
      # takes this row and the assertions below flip.
      twin_task!("drafts.twin-paired", "Draft twin", "draft")
      twin_task!("twin-paired", "Published twin", "published")

      board = Board.snapshot(dataset: "production")

      card = board.cards_by_id["twin-paired"]
      assert card != nil, "the published twin must be the row the board shows"
      assert card.title == "Published twin"

      # The pair COLLAPSES to one card. `to_card/4` keys every card by the
      # PUBLISHED id, so the surviving row is identified by its TITLE, not by
      # the key: "Draft twin" here would mean the draft won the slot — and for
      # the same reason `map_size(board.cards_by_id)` CANNOT see a lost
      # collapse (both twins share the key). Count what the columns hold: that
      # is the list a non-collapsing `load_task_docs/1` grows to two.
      live_cards = board.columns |> Map.values() |> List.flatten()

      assert length(live_cards) == 1,
             "the pair must COLLAPSE — the draft twin is not a second card"
    end

    test "rule 1 decides when the published row is the drafts.-spelled one" do
      # The one bucket shape where rules 1 and 2 DISAGREE: the published row
      # carries the `drafts.` spelling and the bare twin does not. Rule 2 alone
      # would answer "Unpublished bare"; only the `status == "published"`
      # clause answers the other way. Every other arm here is satisfied by
      # rules 2-3, so this is the arm that keeps rule 1 from rotting into
      # dead code unnoticed.
      twin_task!("rule1-inverted", "Unpublished bare", "draft")
      twin_task!("drafts.rule1-inverted", "Published draft-spelled", "published")

      board = Board.snapshot(dataset: "production")

      assert board.cards_by_id["rule1-inverted"].title == "Published draft-spelled",
             "status == published must outrank the bare-id tie-break"
    end

    test "an UNPAIRED drafts. row IS the row of record and resolves as ITSELF" do
      # No published twin exists for this id. The carve-out (TwinResolver rule 1
      # with its premise absent) keeps it on the board as itself.
      twin_task!("drafts.twin-solo", "Solo draft", "draft")

      board = Board.snapshot(dataset: "production")

      # `to_card/4` keys by the published id even for an unpaired draft, so the
      # key is the bare id; the point is that the ROW SURVIVES at all. A blanket
      # `drafts.` drop in canonical_twin/1 empties the board here.
      card = board.cards_by_id["twin-solo"]
      assert card != nil, "an unpaired drafts. row must survive the collapse as itself"
      assert card.title == "Solo draft"
    end

    test "with NO published row the winner is the RULE, not the insertion order" do
      # Two buckets, each holding only unpublished members, seeded in OPPOSITE
      # orders. Rule 2 (bare id beats `drafts.`-prefixed) decides both, so the
      # answer cannot depend on which row the storage hands back first.
      twin_task!("drafts.order-a", "Draft A", "draft")
      twin_task!("order-a", "Bare A", "draft")

      twin_task!("order-b", "Bare B", "draft")
      twin_task!("drafts.order-b", "Draft B", "draft")

      board = Board.snapshot(dataset: "production")

      assert board.cards_by_id["order-a"].title == "Bare A"
      assert board.cards_by_id["order-b"].title == "Bare B"

      assert map_size(board.cards_by_id) == 2,
             "each bucket must collapse to exactly one card"
    end

    # ── the SEAM between this collapse and the draft label contract ────────
    #
    # These two changes land on the same projection from opposite sides:
    # `TwinCollapse.canonical/1` decides WHICH twin becomes a card, and
    # `to_card/4` then reads `draft: DraftId.draft?(doc.doc_id)` off THAT row's
    # RAW doc_id. The arms above pin the choice and the draft-label arms pin the
    # derivation, but neither watches the hand-off: in a COLLAPSED bucket both
    # spellings exist, so a flag read off the losing twin — or off the bucket
    # key, which `Content.published_id/1` has already stripped — is wrong while
    # every single-row arm stays green. The two cases below disagree on the
    # expected value, so no constant-valued flag satisfies both.

    test "a collapsed bucket reports the SURVIVOR's own spelling, not its twin's" do
      # Survivor is the BARE published row; the loser carries the `drafts.`
      # spelling. A flag that leaked from the losing twin reads true here.
      twin_task!("drafts.seam-bare", "Draft twin", "draft")
      twin_task!("seam-bare", "Published twin", "published")

      # Survivor is the `drafts.`-SPELLED published row (rule 1 over rule 2);
      # the loser is the bare id. A flag read off the card's own (stripped)
      # doc_id, or off the bare loser, reads false here.
      twin_task!("seam-drafty", "Unpublished bare", "draft")
      twin_task!("drafts.seam-drafty", "Published draft-spelled", "published")

      cards = Board.snapshot(dataset: "production").cards_by_id

      assert cards["seam-bare"].title == "Published twin"
      assert cards["seam-bare"].draft == false

      assert cards["seam-drafty"].title == "Published draft-spelled"

      assert cards["seam-drafty"].draft == true,
             "the surviving row is drafts.-spelled — the label must follow the row that WON"
    end
  end
end
