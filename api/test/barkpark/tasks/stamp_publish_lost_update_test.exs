defmodule Barkpark.Tasks.StampPublishLostUpdateTest do
  @moduledoc """
  THE PUBLISH DOOR'S CRITERIA FENCE IS READ OUTSIDE THE WRITE'S TRANSACTION
  (`pds-bl-stamp-writeback-reverts-a-stamped-criterion`).

  OBSERVED, during PDS wave 23: a `bp task stamp` returned `ok: true` with
  `criteria_progress` 5/6 and a later re-read showed that criterion back at
  `met: false` with EMPTY evidence. Re-stamping held. This file names the
  mechanism.

  TWO DOORS WRITE ONE TASK ROW.

    * The TASK door (`Barkpark.Tasks.Stamp` and siblings) writes the published
      row through `Internal.fenced_content_write/4`: a `pg_advisory_xact_lock`
      on `task:<uuid>`, an in-lock re-read, and a rev-CAS'd `UPDATE`. Airtight.
    * The DOCUMENT door (`Content.Lifecycle.publish_document/4`) copies the
      draft's content onto the published row WHOLESALE
      (`publish_after_gate/5`'s `"content" => pub_content`). It is guarded by
      `criteria_fence/2`, which refuses a draft that would lower a stamped
      criterion.

  THE GAP IS THE ORDER OF OPERATIONS, not the absence of a guard.
  `do_publish_document/4` reads the published row and runs the fence BEFORE
  `publish_after_gate/5` is even entered — outside any transaction, outside any
  lock. `publish_after_gate/5` then runs the authoring wall, fires the
  `:before_publish` hook chain, and only then opens the transaction, re-reads
  the published row into `existing` and does
  `existing |> Document.changeset(pub_attrs) |> Repo.update()`. That re-read is
  used for the paper revision counter and the broadcast's `prev_pub_rev`; the
  criteria fence WAS never re-evaluated against it, and for `type: "task"`
  `lock_published_paper/2` fell to its passthrough clause, so there was neither
  a `FOR UPDATE` lock nor a rev fence on the published row. Both halves are
  closed below.

  Anything that lands in that window is therefore silently overwritten. The
  window is real wall-clock time: the authoring wall alone issues the exemption
  read, the label-spine check, the tag-registry check and the dedup scan.

  HOW THIS FILE DRIVES THE WINDOW DETERMINISTICALLY. A concurrent stamp would
  reproduce it only by luck, so the interleave is placed at the one sanctioned
  seam that already sits inside the window: a `:before_publish` hook. The hook
  runs after the fence has passed and before the transaction opens — exactly
  where a concurrent stamp lands — and it performs a REAL `Tasks.Stamp.stamp/3`
  against the REAL published row. Nothing about the defect is hook-specific;
  the hook is a clock, not a cause.

  THE CONTROL comes first, and it is a permanent regression guard in its own
  right: when the stamp lands BEFORE the publish begins, the fence sees it and
  the publish is REFUSED. That arm proves the fixture, the fence and the stamp
  all work, which is what makes the second arm's verdict mean something.

  ### The second test WAS a characterization; it is now the GUARD

  It shipped asserting the DEFECT (two lines marked `FLIP ON FIX`) because
  `Barkpark.Content.Lifecycle` was outside the reproducing change's fence. Both
  lines have since been INVERTED against the fix: `lock_published_row/2` now
  locks the published row `FOR UPDATE` for `"task"` as well as `"paper"`, and
  `assert_no_criteria_regression!/3` re-evaluates `criteria_fence/2` against
  that locked row INSIDE the publish transaction, so the publish that would
  overwrite the stamp is refused instead. Reverting either half reds this test
  by name — that is the mutation proof the row asks for.

  THE PROPERTY THE FIX MUST HOLD: a stamp that returned `ok: true` is never
  reverted by a concurrent non-stamp write. The mechanism has to be inside the
  publish transaction — re-run `criteria_fence/2` against the row read under a
  `FOR UPDATE` lock, or rev-fence the published update against the rev the gate
  read — because no amount of pre-transaction checking can close a window that
  is defined by being after the check.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Stamp

  @dataset "production"

  # The authoring wall (E1 label spine / E3 tag registry) refuses a task publish
  # without a >= 20-char description and a registered tag. Both are fixture
  # scaffolding for the publish door, not part of what is under test.
  @description "The publish door must not copy a stale draft over a stamped criterion."

  # The interleave seam. `before_publish` hooks run SEQUENTIALLY AND IN THE
  # CALLING PROCESS (`Plugins.Hooks.fire/2`), so the callback is handed over in
  # the process dictionary: no application-wide switch, and a concurrently
  # running async test that happens to publish something sees an inert hook.
  defmodule InterleavedWriter do
    @moduledoc false
    def lifecycle_hooks, do: %{before_publish: [&__MODULE__.run/1]}

    def run(payload) do
      case Process.get(:stamp_publish_interleave) do
        fun when is_function(fun, 1) -> fun.(payload)
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    LabelFixtures.register_tags!(@dataset)

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    previous = Application.get_env(:barkpark, :plugins)

    Application.put_env(
      :barkpark,
      :plugins,
      Barkpark.Plugins.Registry.all() ++ [InterleavedWriter]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark, :plugins)
        list -> Application.put_env(:barkpark, :plugins, list)
      end
    end)

    %{scope: scope}
  end

  # ─── Fixtures ──────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp criteria do
    [
      %{"criterion" => "the gate is green on the merge commit", "met" => false, "evidence" => ""},
      %{"criterion" => "the doc card names the new anchor", "met" => false, "evidence" => ""}
    ]
  end

  # A published, CLAIMED task — the only shape `bp task stamp --met` accepts.
  # Returns the published row and the live claim epoch.
  defp published_claimed_task!(doc_id, scope) do
    {:ok, _draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "Publish door must not revert a stamped criterion #{doc_id}",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "description" => @description,
            "tags" => [
              %{
                "tag" => "fixture-tag-1",
                "strength" => 85,
                "rationale" => "this row is filed under the PDS epic backlog"
              }
            ],
            "acceptance_criteria" => criteria()
          }
        },
        @dataset,
        scope
      )

    {:ok, _published} = Content.publish_document(doc_id, "task", @dataset, scope)
    {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)

    {:ok, published} = Content.get_document(doc_id, "task", @dataset)
    {published, claimed.content["claim"]["epoch"]}
  end

  # The stale draft: byte-identical to the published row as the publisher read
  # it. This is the ordinary `bp doc patch` → `bp doc publish` idiom — the claim
  # is carried verbatim (so `stale_claim?/2` passes), the lifecycle is unchanged
  # (so `Transitions.legal?/2` passes) and the criteria are the UNSTAMPED list
  # (so `criteria_fence/2` passes, because nothing is proven yet).
  defp mint_stale_draft!(%Document{} = published, scope) do
    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => published.doc_id,
          "title" => published.title,
          "content" => published.content
        },
        @dataset,
        scope
      )

    draft
  end

  defp stamp_first_criterion!(%Document{} = published, epoch) do
    Stamp.stamp(published.id, "w",
      observed_epoch: epoch,
      criterion: 0,
      criterion_text: "the gate is green on the merge commit",
      outcome: {:met, "CI run 12345: 431 tests, 0 failures"}
    )
  end

  defp published_criteria(doc_id) do
    {:ok, %Document{content: content}} = Content.get_document(doc_id, "task", @dataset)
    content["acceptance_criteria"]
  end

  # ─── CONTROL: the stamp lands BEFORE the publish starts ────────────────────

  describe "criteria_fence — the arm that already works" do
    test "a publish whose draft predates the stamp is REFUSED, and the proof survives",
         %{scope: scope} do
      doc_id = uniq("lost-update-control")
      {published, epoch} = published_claimed_task!(doc_id, scope)
      _draft = mint_stale_draft!(published, scope)

      # PRECONDITION, asserted rather than assumed: the stamp really landed on
      # the PUBLISHED row. Without this the refusal below could be a refusal for
      # some unrelated reason on a row that was never stamped.
      assert {:ok, stamped} = stamp_first_criterion!(published, epoch)
      assert hd(stamped.content["acceptance_criteria"])["met"] == true
      assert hd(published_criteria(doc_id))["met"] == true

      assert {:error, {:invalid_task_content, errors}} =
               Content.publish_document(doc_id, "task", @dataset, scope)

      assert %{"acceptance_criteria" => [message]} = errors
      assert message =~ "would clear the `met: true` flag for acceptance criterion 0"
      assert message =~ "the gate is green on the merge commit"

      # The refusal is worth nothing if it did not protect the proof.
      [first, _second] = published_criteria(doc_id)
      assert first["met"] == true
      assert first["evidence"] == "CI run 12345: 431 tests, 0 failures"
    end
  end

  # ─── THE DEFECT: the stamp lands INSIDE the publish's window ───────────────

  describe "the window between the fence read and the published write" do
    test "a stamp that returns ok:true inside the publish window is silently reverted",
         %{scope: scope} do
      doc_id = uniq("lost-update-window")
      {published, epoch} = published_claimed_task!(doc_id, scope)
      _draft = mint_stale_draft!(published, scope)

      # Nothing is proven yet, so the fence — which is read BEFORE this publish
      # enters `publish_after_gate/5` — has nothing to protect.
      assert hd(published_criteria(doc_id))["met"] == false

      test_pid = self()

      Process.put(:stamp_publish_interleave, fn payload ->
        # Only this document's publish, so a concurrent async test that
        # publishes something is untouched by the global plugin list.
        if payload.doc.doc_id == "drafts.#{doc_id}" do
          send(test_pid, {:stamp_result, stamp_first_criterion!(published, epoch)})
        end

        :ok
      end)

      publish_result = Content.publish_document(doc_id, "task", @dataset, scope)

      Process.delete(:stamp_publish_interleave)

      # The stamp inside the window RETURNED OK — this is the receipt the wave-23
      # builder saw, and it is the whole reason the revert is invisible.
      assert_received {:stamp_result, {:ok, stamped}}
      assert hd(stamped.content["acceptance_criteria"])["met"] == true

      assert hd(stamped.content["acceptance_criteria"])["evidence"] ==
               "CI run 12345: 431 tests, 0 failures"

      [first, _second] = published_criteria(doc_id)

      # FLIPPED (1/2) — this WAS the characterization `assert {:ok, %Document{}}
      # = publish_result`. The fence is now re-evaluated inside the publish
      # transaction against the published row read under `FOR UPDATE`
      # (`Lifecycle.assert_no_criteria_regression!/3`), so the publish that
      # would overwrite the stamp is REFUSED with the same
      # `{:invalid_task_content, _}` shape the door-level fence uses. Putting
      # the guard back (drop the in-transaction fence, or narrow
      # `lock_published_row/2` back to "paper" only) reds this line.
      assert {:error, {:invalid_task_content, errors}} = publish_result

      assert %{"acceptance_criteria" => [message]} = errors
      assert message =~ "would clear the `met: true` flag for acceptance criterion 0"

      # FLIPPED (2/2) — this WAS `assert first["met"] == false` plus
      # `assert first["evidence"] == ""`, byte-for-byte the wave-23
      # observation. The stamp that answered `ok: true` inside the publish
      # window now SURVIVES the publish, evidence included.
      assert first["met"] == true,
             "the publish window reverted a stamped criterion — the defect " <>
               "`pds-bl-stamp-writeback-reverts-a-stamped-criterion` describes is BACK. " <>
               "A stamp that returned ok:true was overwritten by a concurrent publish " <>
               "whose draft predates it."

      assert first["evidence"] == "CI run 12345: 431 tests, 0 failures"
    end
  end
end
