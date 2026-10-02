defmodule Barkpark.Tasks.CriteriaSeedTest do
  @moduledoc """
  task-00f5bc88af7de2e9 — a task whose `acceptance_criteria` key is ABSENT could
  never be given one.

  `Internal.merge_criteria/2` normalises an absent key and a stored `[]` to the
  SAME empty list, and the indexed update then resolved its target with
  `Enum.at/2`, which misses on every index against `[]`. So no writer could grow
  the array from empty: `bp task stamp` answered `:criteria_index_out_of_range`
  at index 0, `bp task close --set criteria` answered it identically, and a raw
  HTTP content mutate — outside every honesty gate — was the only remaining
  door. Six live zero-criteria rows were born that way.

  ## The two shapes are tested separately, on purpose

  A test that covers only the stored-`[]` shape is VACUOUS for the absent-key
  shape and vice versa, because the conflation happens inside the function under
  test: both normalise to `[]` at the top of `merge_criteria/2`. So every seed
  assertion here runs against BOTH, and the absent-key fixture asserts the key
  is genuinely absent before the merge rather than trusting the map literal.

  ## The dangerous half

  Seeding is the false-done vector wearing a helpful face. The repair is only
  acceptable while create-and-meet in a single write stays impossible on every
  writer, in every arrangement, so the adversarial block below proves all three:
  an explicit `met: true`, the met-key-absent default (close-time semantics),
  and a two-update payload that seeds an index and then flips it inside the SAME
  merge.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, Internal, Stamp}

  import Ecto.Query, only: [from: 2]

  @dataset "production"

  # ─── Pure fixtures (no DB) ────────────────────────────────────────────────

  # The two shapes the bug conflates. `@absent` has NO "acceptance_criteria"
  # key at all; `@empty` stores the key with `[]`.
  @absent %{"kind" => "task", "lifecycle_status" => "open"}
  @empty Map.put(@absent, "acceptance_criteria", [])

  @stored [
    %{"criterion" => "the gate is green", "met" => false, "evidence" => ""},
    %{"criterion" => "the docs are updated", "met" => true, "evidence" => "PR #1"}
  ]
  @non_empty Map.put(@absent, "acceptance_criteria", @stored)

  defp seed(text), do: %{"index" => 0, "criterion" => text, "met" => false}

  defp criteria(content), do: Map.get(content, "acceptance_criteria")

  # ─── (1) THE BUG: seeding from empty, both shapes ─────────────────────────

  describe "merge_criteria/2 — seeding an empty criteria array" do
    test "index 0 with text seeds a criteria-less row (ABSENT key)" do
      refute Map.has_key?(@absent, "acceptance_criteria"),
             "fixture precondition: the key must be genuinely absent"

      assert {:ok, content} =
               Internal.merge_criteria(@absent, [seed("a bar the row can be held to")])

      assert criteria(content) == [
               %{
                 "criterion" => "a bar the row can be held to",
                 "met" => false,
                 "evidence" => ""
               }
             ]
    end

    test "index 0 with text seeds a criteria-less row (stored [])" do
      assert Map.get(@empty, "acceptance_criteria") == [],
             "fixture precondition: the key is present and empty"

      assert {:ok, content} =
               Internal.merge_criteria(@empty, [seed("a bar the row can be held to")])

      assert criteria(content) == [
               %{
                 "criterion" => "a bar the row can be held to",
                 "met" => false,
                 "evidence" => ""
               }
             ]
    end

    test "a seed may carry evidence as long as it says met: false explicitly" do
      update = %{
        "index" => 0,
        "criterion" => "carries context",
        "met" => false,
        "evidence" => "see the design note"
      }

      assert {:ok, content} = Internal.merge_criteria(@empty, [update])
      assert [%{"met" => false, "evidence" => "see the design note"}] = criteria(content)
    end

    test "several seeds in one payload append in order" do
      updates = [
        %{"index" => 0, "criterion" => "first", "met" => false},
        %{"index" => 1, "criterion" => "second", "met" => false}
      ]

      assert {:ok, content} = Internal.merge_criteria(@empty, updates)
      assert Enum.map(criteria(content), & &1["criterion"]) == ["first", "second"]
      assert Enum.all?(criteria(content), &(&1["met"] == false))
    end
  end

  # ─── (2) A SEED IS NEVER A SILENT OVERWRITE ───────────────────────────────

  describe "merge_criteria/2 — a non-empty array is never clobbered" do
    test "seeding one past the end APPENDS; every stored entry is byte-identical" do
      assert {:ok, content} =
               Internal.merge_criteria(@non_empty, [
                 %{"index" => 2, "criterion" => "a third bar", "met" => false}
               ])

      [first, second, third] = criteria(content)
      assert first == Enum.at(@stored, 0), "stored entry 0 untouched"
      assert second == Enum.at(@stored, 1), "stored entry 1 untouched, met:true preserved"
      assert third == %{"criterion" => "a third bar", "met" => false, "evidence" => ""}
    end

    test "an in-range index still UPDATES rather than seeding" do
      assert {:ok, content} =
               Internal.merge_criteria(@non_empty, [
                 %{
                   "index" => 0,
                   "criterion" => "the gate is green",
                   "met" => true,
                   "evidence" => "PR #2"
                 }
               ])

      assert length(criteria(content)) == 2, "an in-range write must not grow the list"
      assert Enum.at(criteria(content), 0)["evidence"] == "PR #2"
    end
  end

  # ─── (3) A FAILED READ IS NEVER BYTE-IDENTICAL TO A ZERO ──────────────────

  describe "merge_criteria/2 — the range guard is not weakened" do
    test "an index-only update against an empty array still refuses, loudly" do
      for content <- [@absent, @empty] do
        assert {:error, :criteria_index_out_of_range} =
                 Internal.merge_criteria(content, [%{"index" => 0, "met" => false}])
      end
    end

    test "the 1-based off-by-one (index 1 on an empty array) stays out of range" do
      for content <- [@absent, @empty] do
        assert {:error, :criteria_index_out_of_range} =
                 Internal.merge_criteria(content, [
                   %{"index" => 1, "criterion" => "off by one", "met" => false}
                 ])
      end
    end

    test "index + 2 and beyond stay out of range on a populated row" do
      for index <- [3, 4, 99] do
        assert {:error, :criteria_index_out_of_range} =
                 Internal.merge_criteria(@non_empty, [
                   %{"index" => index, "criterion" => "way past", "met" => false}
                 ])
      end
    end

    test "a seed whose text DUPLICATES a stored criterion is criteria_mismatch" do
      assert {:error, :criteria_mismatch} =
               Internal.merge_criteria(@non_empty, [
                 %{"index" => 2, "criterion" => "the gate is green", "met" => false}
               ])
    end

    test "an empty or nil criterion text cannot seed" do
      for text <- ["", nil] do
        update =
          %{"index" => 0, "met" => false}
          |> then(fn u -> if text, do: Map.put(u, "criterion", text), else: u end)

        assert {:error, :criteria_index_out_of_range} = Internal.merge_criteria(@empty, [update])
      end
    end

    test "a withdrawal cannot seed the criterion it claims to withdraw" do
      update = %{
        "index" => 0,
        "criterion" => "never existed",
        "met" => false,
        "withdrawal" => %{"note" => "refuted", "ts" => "2026-09-13T00:00:00Z", "worker" => "w"}
      }

      assert {:error, :criteria_index_out_of_range} = Internal.merge_criteria(@empty, [update])
    end

    test "the text-keyed dialect never seeds — an unknown wording is still not found" do
      assert {:error, :criterion_not_found} =
               Internal.merge_criteria(@empty, [%{"criterion" => "brand new", "met" => false}])

      assert {:error, :criterion_not_found} =
               Internal.merge_criteria(@non_empty, [%{"criterion" => "brand new", "met" => false}])
    end
  end

  # ─── (4) ADVERSARIAL: create-and-meet stays impossible ────────────────────

  describe "merge_criteria/2 — a seed can never be met by the write that made it" do
    test "an explicit met: true seed is refused" do
      for content <- [@absent, @empty] do
        assert {:error, :criterion_seed_not_met} =
                 Internal.merge_criteria(content, [
                   %{
                     "index" => 0,
                     "criterion" => "proved itself",
                     "met" => true,
                     "evidence" => "PR #9"
                   }
                 ])
      end
    end

    test "the met-key-absent default (close-time semantics) is refused" do
      # An index + evidence update with NO "met" key IS a met-flip everywhere
      # else in this module, so a seed must read it the same way or the default
      # becomes the loophole.
      assert {:error, :criterion_seed_not_met} =
               Internal.merge_criteria(@empty, [
                 %{"index" => 0, "criterion" => "quietly proved", "evidence" => "PR #9"}
               ])

      assert {:error, :criterion_seed_not_met} =
               Internal.merge_criteria(@empty, [%{"index" => 0, "criterion" => "quietly proved"}])
    end

    test "a seed-then-flip TWO-UPDATE payload is refused with nothing written" do
      updates = [
        %{"index" => 0, "criterion" => "invented here", "met" => false},
        %{
          "index" => 0,
          "criterion" => "invented here",
          "met" => true,
          "evidence" => "graded my own homework"
        }
      ]

      assert {:error, :criterion_seed_not_met} = Internal.merge_criteria(@empty, updates)
    end

    test "the flip is refused in the TEXT-KEYED dialect too" do
      # The text-keyed clause resolves against the list AS THE MERGE SEES IT, so
      # the seeded row is findable by wording. It must hit the same refusal.
      updates = [
        %{"index" => 0, "criterion" => "invented here", "met" => false},
        %{"criterion" => "invented here", "met" => true, "evidence" => "PR #9"}
      ]

      assert {:error, :criterion_seed_not_met} = Internal.merge_criteria(@empty, updates)
    end

    test "even a miss cannot touch an index seeded by the same call" do
      updates = [
        %{"index" => 0, "criterion" => "invented here", "met" => false},
        %{
          "index" => 0,
          "criterion" => "invented here",
          "attempt" => %{"note" => "tried", "ts" => "2026-09-13T00:00:00Z", "worker" => "w"}
        }
      ]

      assert {:error, :criterion_seed_not_met} = Internal.merge_criteria(@empty, updates)
    end

    test "a seed does NOT lock a pre-existing index in the same payload" do
      # The fence is about rows this write INVENTED. Updating a stored row and
      # appending a new one in one call is ordinary and must keep working.
      updates = [
        %{
          "index" => 0,
          "criterion" => "the gate is green",
          "met" => true,
          "evidence" => "PR #2"
        },
        %{"index" => 2, "criterion" => "a third bar", "met" => false}
      ]

      assert {:ok, content} = Internal.merge_criteria(@non_empty, updates)
      assert length(criteria(content)) == 3
      assert Enum.at(criteria(content), 0)["met"] == true
      assert Enum.at(criteria(content), 2)["met"] == false
    end
  end

  # ─── (5) D56 IS UNCHANGED ─────────────────────────────────────────────────

  describe "merge_criteria/2 — the D56 honesty guards are untouched" do
    test "an in-range index-only met-flip is still criterion_text_required" do
      assert {:error, :criterion_text_required} =
               Internal.merge_criteria(@non_empty, [
                 %{"index" => 0, "met" => true, "evidence" => "unguarded"}
               ])
    end

    test "an in-range stale text guard is still criteria_mismatch" do
      assert {:error, :criteria_mismatch} =
               Internal.merge_criteria(@non_empty, [
                 %{
                   "index" => 0,
                   "criterion" => "the docs are updated",
                   "met" => true,
                   "evidence" => "e"
                 }
               ])
    end

    test "an unguarded flip of a seeded row is refused by D56 in a LATER call" do
      # Seed first, then try to flip the seeded row in a LATER call with no
      # guard: the same-write fence has lifted (different call), so D56 must be
      # the one that refuses — a seeded criterion is an ordinary criterion the
      # moment the write that made it has landed.
      assert {:ok, seeded} = Internal.merge_criteria(@empty, [seed("newly seeded")])

      assert {:error, :criterion_text_required} =
               Internal.merge_criteria(seeded, [
                 %{"index" => 0, "met" => true, "evidence" => "e"}
               ])

      # And the honest, guarded flip of that same row works.
      assert {:ok, flipped} =
               Internal.merge_criteria(seeded, [
                 %{"index" => 0, "criterion" => "newly seeded", "met" => true, "evidence" => "e"}
               ])

      assert [%{"met" => true, "evidence" => "e"}] = criteria(flipped)
    end
  end

  # ─── (6) REACHABILITY FROM THE REAL WRITER SURFACES ───────────────────────

  describe "the writer surfaces can seed" do
    setup do
      {ws, project} = TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      for schema_def <- Tasks.schema_definitions(@dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
      end

      %{scope: scope}
    end

    defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

    defp mk_task!(doc_id, scope, criteria) do
      {:ok, doc} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "acceptance_criteria" => criteria
            }
          },
          @dataset,
          scope
        )

      doc
    end

    # A RAW store write installing the criteria-less shape the create door
    # refuses (`CriteriaRequiredFence`). The six live rows this row is about got
    # there before that door existed, so the fixture has to go in behind it —
    # building it through the front door would silently convert this into a test
    # of the front door.
    defp strip_criteria!(task_id) do
      stored = Repo.get!(Document, task_id)
      content = Map.delete(stored.content, "acceptance_criteria")

      {1, _} =
        from(d in Document, where: d.id == ^stored.id)
        |> Repo.update_all(set: [content: content, rev: Internal.generate_rev()])

      Repo.get!(Document, task_id)
    end

    # `done` is NOT the status used here, and that is the point rather than a
    # dodge: a seeded criterion is born unmet, so a `done` close carrying one
    # is refused by the unmet gate (`{:criteria_unmet, [0]}`) exactly as it
    # should be — seeding buys a closer nothing. `blocked` is the honest
    # partial, and it is where a closer that discovered the row had no stated
    # bar can write one down.
    test "close --set criteria seeds a criterion onto a criteria-less row", %{scope: scope} do
      task =
        mk_task!(uniq("seed-close"), scope, [%{"criterion" => "placeholder", "met" => false}])

      task = strip_criteria!(task.id)

      refute Map.has_key?(task.content, "acceptance_criteria"),
             "precondition: the row is genuinely criteria-less"

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "blocked",
                 criteria: [
                   %{"index" => 0, "criterion" => "the seeded bar", "met" => false}
                 ]
               )

      assert [%{"criterion" => "the seeded bar", "met" => false}] =
               closed.content["acceptance_criteria"]
    end

    test "a done close cannot pass its own gate with a seeded criterion", %{scope: scope} do
      task =
        mk_task!(uniq("seed-close-done"), scope, [%{"criterion" => "placeholder", "met" => false}])

      task = strip_criteria!(task.id)

      assert {:error, {:criteria_unmet, [0]}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{"index" => 0, "criterion" => "the seeded bar", "met" => false}
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      refute Map.has_key?(reloaded.content, "acceptance_criteria")
    end

    test "close refuses to seed AND meet in the same call", %{scope: scope} do
      task =
        mk_task!(uniq("seed-close-bad"), scope, [%{"criterion" => "placeholder", "met" => false}])

      task = strip_criteria!(task.id)

      assert {:error, :criterion_seed_not_met} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "blocked",
                 criteria: [
                   %{
                     "index" => 0,
                     "criterion" => "the seeded bar",
                     "met" => true,
                     "evidence" => "PR #9"
                   }
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open", "nothing was written"
      refute Map.has_key?(reloaded.content, "acceptance_criteria")
    end

    test "stamp --miss seeds a new criterion one past the end", %{scope: scope} do
      doc_id = uniq("seed-stamp")
      task = mk_task!(doc_id, scope, [%{"criterion" => "the first bar", "met" => false}])
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: "the second bar",
                 outcome: {:miss, "opened the work, not done yet"}
               )

      [first, second] = stamped.content["acceptance_criteria"]
      assert first["criterion"] == "the first bar"
      assert second["criterion"] == "the second bar"
      assert second["met"] == false, "a seeded criterion is born unmet"
      assert [%{"note" => "opened the work, not done yet"}] = second["attempts"]
    end

    test "stamp --met one past the end is refused, nothing written", %{scope: scope} do
      doc_id = uniq("seed-stamp-met")
      task = mk_task!(doc_id, scope, [%{"criterion" => "the first bar", "met" => false}])
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]
      before = Repo.get!(Document, task.id).content["acceptance_criteria"]

      assert {:error, :criterion_seed_not_met} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: "the second bar",
                 outcome: {:met, "PR #9 merged as abc1234"}
               )

      assert Repo.get!(Document, task.id).content["acceptance_criteria"] == before
    end

    test "stamp two past the end is still criteria_index_out_of_range", %{scope: scope} do
      doc_id = uniq("seed-stamp-oob")
      task = mk_task!(doc_id, scope, [%{"criterion" => "the first bar", "met" => false}])
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      assert {:error, :criteria_index_out_of_range} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 2,
                 criterion_text: "the third bar",
                 outcome: {:miss, "no such row"}
               )
    end
  end
end
