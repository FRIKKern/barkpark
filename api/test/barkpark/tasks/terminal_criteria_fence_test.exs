defmodule Barkpark.Tasks.TerminalCriteriaFenceTest do
  @moduledoc """
  THE TERMINAL-CRITERIA FENCE (task-3c3094aa8f5f3847).

  ## The witness, reproduced here against a SCRATCH row and nothing else

  `task-2b7cbaf8265f6b4e` closed `done` on 2026-08-24T21:52Z carrying ZERO
  acceptance criteria. `bp doc history` shows its published doc untouched until
  2026-09-04T06:09:15/37/39Z, where a `discardDraft` -> `create draft` ->
  `publish` triple wrote a 7-entry criteria list — 6 met, c6 unmet — onto the
  already-`done` published row. The row has ZERO `task.criterion` events in its
  life: no stamp, no withdrawal, no attribution. False-done, silently.

  NO LIVE ROW WAS TOUCHED TO PROVE THIS. The first test below builds its own
  scratch row in this test's own dataset and walks the whole lifecycle —
  publish, claim, stamp met, close `done` — and only then runs the document
  door at it. No probe was run against the production ledger, on a scratch row
  or otherwise; the reproduction is entirely in-repo.

  ## Why the two doors already in place cannot see it

  `Content.Lifecycle`'s `criteria_fence/2` is a REGRESSION fence: it walks the
  PUBLISHED row's proof-bearing criteria (`met: true` or non-blank `evidence`)
  and refuses a draft that drops or unproves one. The witness's published row
  carried NO criteria, so there was nothing to regress. The variant reproduced
  below is one notch narrower and still passes it: a row closed 1/1 gains a NEW
  unmet criterion at index 1, which regresses nothing at index 0, and the row
  lands `done 1/2`. `Tasks.DraftTerminalFence` says in its own moduledoc that a
  row with a published twin is "untouched — the publish door owns it".

  ## RED without / GREEN with

  Test (a) is the mutation proof: with `TerminalCriteriaFence.check/6`
  collapsed to `:ok` it FAILS with the flunk message the test itself composes,
  which quotes the landed state (lifecycle, met count, rev before/after, and
  the empty withdrawals list). With the fence wired it passes. The rest of the
  file pins what the fence must NOT break.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "terminal_criteria_fence_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

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

  # ── fixtures ─────────────────────────────────────────────────────────────

  @c0 "the scratch row carries one provable criterion"
  @unmet_c1 "MERGE GATE (lead): PR #14072 is merged to main — the witness's own c6"

  defp base_content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [%{"criterion" => @c0, "met" => false}]
    }
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # The DOCUMENT door — the seam every raw write (`/v1/data/mutate` create /
  # createOrReplace / patch-merge, `bp doc create`, the MCP bridge, Studio)
  # funnels through. `doc_id` is passed verbatim, so a `drafts.`-prefixed id
  # addresses the draft and a bare id addresses the published row.
  defp doc_write(doc_id, content, scope, opts \\ []) do
    Content.create_document(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => "Terminal criteria fence fixture #{doc_id}",
        "content" => content
      },
      @dataset,
      Keyword.merge(scope, opts)
    )
  end

  # A scratch row walked all the way to `done` through the SANCTIONED verbs
  # only: document create -> publish -> claim -> stamp met -> close.
  defp closed_done_row!(doc_id, scope) do
    {:ok, _draft} = doc_write(doc_id, base_content(%{}), scope)
    {:ok, _pub} = Content.publish_document(doc_id, "task", @dataset, scope)

    {:ok, claimed} = Tasks.claim_by_id(doc_id, "tcf-worker", scope)
    epoch = claimed.content["claim"]["epoch"]

    {:ok, stamped} =
      Tasks.stamp(claimed.id, "tcf-worker",
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: @c0,
        outcome: {:met, "proven by terminal_criteria_fence_test.exs"}
      )

    assert met_count(stamped.content) == 1

    {:ok, closed} = Tasks.close(claimed.id, "tcf-worker", observed_epoch: epoch)
    assert closed.content["lifecycle_status"] == "done"
    assert met_count(closed.content) == 1
    assert length(criteria(closed.content)) == 1

    %{doc: closed, epoch: epoch}
  end

  defp published(doc_id, scope) do
    {:ok, %Document{} = doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  defp criteria(content), do: content["acceptance_criteria"] || []
  defp met_count(content), do: Enum.count(criteria(content), &(&1["met"] == true))

  defp withdrawals(content) do
    content |> criteria() |> Enum.flat_map(&(&1["withdrawals"] || []))
  end

  # ── (a) THE WITNESS — the door, reproduced, then refused ─────────────────

  test "THE WITNESS (task-2b7cbaf8265f6b4e): a document-door write of a criteria list " <>
         "carrying an UNMET criterion onto an already-done row is REFUSED",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-witness", scope)
    before_rev = published("tcf-witness", scope).rev

    # The witness triple's middle step: mint a draft off the CURRENT published
    # content — claim, close_reason, landed, lifecycle all byte-identical, so
    # `stale_claim?/2`, the `done -> done` transition table and
    # `task_door_field_fence/2` all wave it through — and append an unmet
    # criterion to the list.
    divergent =
      Map.put(
        closed.content,
        "acceptance_criteria",
        criteria(closed.content) ++ [%{"criterion" => @unmet_c1, "met" => false}]
      )

    result = doc_write("drafts.tcf-witness", divergent, scope)

    case result do
      {:error, {:invalid_task_content, details}} ->
        message = details["acceptance_criteria"] |> List.first()
        assert message =~ "CLOSED terminal"
        assert message =~ "1/1 met → 1/2 met"
        assert message =~ "--withdraw"
        assert message =~ "D745"

        # And the row did not move.
        after_doc = published("tcf-witness", scope)
        assert after_doc.rev == before_rev
        assert met_count(after_doc.content) == 1
        assert length(criteria(after_doc.content)) == 1

      {:ok, _draft} ->
        # The PRECONDITION arm. Without the fence the draft lands and the
        # publish copies it over the done row wholesale. Compose the evidence
        # sentence out of what actually happened, so the red QUOTES the hole.
        {:ok, _} = Content.publish_document("tcf-witness", "task", @dataset, scope)
        after_doc = published("tcf-witness", scope)

        flunk("""
        PRECONDITION PROVEN — THE DOOR IS OPEN. The document-door write landed and \
        the publish copied it onto the already-`done` published row:
          lifecycle_status : #{inspect(closed.content["lifecycle_status"])} -> \
        #{inspect(after_doc.content["lifecycle_status"])}
          criteria met     : #{met_count(closed.content)}/#{length(criteria(closed.content))} -> \
        #{met_count(after_doc.content)}/#{length(criteria(after_doc.content))}
          rev              : #{before_rev} -> #{after_doc.rev}
          withdrawals      : #{inspect(withdrawals(after_doc.content))}
        A row that reads `done` while carrying an unmet criterion, with no \
        withdrawal record and no task.criterion event — the exact false-done shape \
        D745's append-only withdrawals list exists to prevent.
        """)
    end
  end

  test "the same refusal on a DIRECT write to the PUBLISHED id (the published-first " <>
         "patch door, task-b9c618482e688500)",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-published-direct", scope)

    divergent =
      Map.put(
        closed.content,
        "acceptance_criteria",
        criteria(closed.content) ++ [%{"criterion" => @unmet_c1, "met" => false}]
      )

    assert {:error, {:invalid_task_content, details}} =
             doc_write("tcf-published-direct", divergent, scope)

    assert details["acceptance_criteria"] |> List.first() =~ "CLOSED terminal"
    assert met_count(published("tcf-published-direct", scope).content) == 1
  end

  test "a met criterion cannot be silently UNPROVED on a done row either " <>
         "(the lower, not just the add)",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-lower", scope)

    lowered =
      Map.put(closed.content, "acceptance_criteria", [%{"criterion" => @c0, "met" => false}])

    assert {:error, {:invalid_task_content, _}} = doc_write("drafts.tcf-lower", lowered, scope)
    assert met_count(published("tcf-lower", scope).content) == 1
  end

  # ── (b) THE ESCAPES — what the fence must NOT break ──────────────────────

  test "byte-identical criteria pass: the patch-then-publish idiom on a done row " <>
         "still lands",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-identical", scope)

    assert {:ok, _draft} =
             doc_write("drafts.tcf-identical", Map.put(closed.content, "priority", 3), scope)

    assert {:ok, _} = Content.publish_document("tcf-identical", "task", @dataset, scope)
    assert published("tcf-identical", scope).content["priority"] == 3
  end

  test "a write that does not NAME acceptance_criteria is untouched (no read, no opinion)",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-unnamed", scope)

    assert {:ok, draft} =
             doc_write(
               "drafts.tcf-unnamed",
               closed.content |> Map.delete("acceptance_criteria") |> Map.put("priority", 1),
               scope
             )

    assert draft.content["priority"] == 1
  end

  test "a REOPEN in the same write is allowed: an open row with unmet criteria is honest",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-reopen", scope)

    reopened =
      closed.content
      |> Map.put("lifecycle_status", "open")
      |> Map.put(
        "acceptance_criteria",
        criteria(closed.content) ++ [%{"criterion" => @unmet_c1, "met" => false}]
      )

    assert {:ok, draft} = doc_write("drafts.tcf-reopen", reopened, scope)
    assert length(criteria(draft.content)) == 2
  end

  test "a BIRTH is exempt: an importer can still file an already-done row with criteria",
       %{scope: scope} do
    assert {:ok, doc} =
             doc_write(
               "tcf-birth",
               base_content(%{
                 "lifecycle_status" => "done",
                 "acceptance_criteria" => [
                   %{"criterion" => @c0, "met" => true, "evidence" => "imported"},
                   %{"criterion" => @unmet_c1, "met" => false}
                 ]
               }),
               scope
             )

    assert doc.content["lifecycle_status"] == "done"
    assert length(criteria(doc.content)) == 2
  end

  test "`blocked` is NOT a close: a blocked row's criteria stay editable",
       %{scope: scope} do
    {:ok, _} = doc_write("tcf-blocked", base_content(%{"lifecycle_status" => "blocked"}), scope)
    {:ok, _} = Content.publish_document("tcf-blocked", "task", @dataset, scope)

    assert {:ok, draft} =
             doc_write(
               "drafts.tcf-blocked",
               base_content(%{
                 "lifecycle_status" => "blocked",
                 "acceptance_criteria" => [
                   %{"criterion" => @c0, "met" => false},
                   %{"criterion" => @unmet_c1, "met" => false}
                 ]
               }),
               scope
             )

    assert length(criteria(draft.content)) == 2
  end

  test "`source: :sync` is exempt: replication mirrors an upstream row verbatim",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-sync", scope)

    divergent =
      Map.put(
        closed.content,
        "acceptance_criteria",
        criteria(closed.content) ++ [%{"criterion" => @unmet_c1, "met" => false}]
      )

    assert {:ok, draft} = doc_write("drafts.tcf-sync", divergent, scope, source: :sync)
    assert length(criteria(draft.content)) == 2
  end

  # ── (c) THE CONTROLS — every legitimate task verb still reaches the row ──
  #
  # THE FILING SAID these verbs "publish" and would therefore traverse this
  # door. They do not: `Tasks.{Close,Stamp,Stage}` write the published row in
  # place through `Tasks.Internal.fenced_content_write/4`, a rev-fenced
  # `Repo.update_all` that never passes through `Content.Writer` (where this
  # fence is wired) and never through `Content.Lifecycle.publish_document/4`.
  # These three tests MEASURE that rather than asserting it: each drives the
  # verb against a row this fence would refuse a document write to, and each
  # still lands.

  test "CONTROL — `bp task close`: publish → claim → stamp → close still reaches done",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-control-close", scope)
    assert closed.content["lifecycle_status"] == "done"
    assert closed.content["claim"]["closed_by"] == "tcf-worker"
  end

  test "CONTROL — `bp task stamp --withdraw` (D745) still LOWERS a lock on the closed row " <>
         "and records the withdrawal",
       %{scope: scope} do
    %{doc: closed, epoch: epoch} = closed_done_row!("tcf-control-withdraw", scope)

    assert {:ok, withdrawn} =
             Tasks.stamp(closed.id, "tcf-reviewer",
               observed_epoch: epoch,
               observed_rev: closed.rev,
               criterion: 0,
               criterion_text: @c0,
               outcome: {:withdraw, "review found the proof did not hold"}
             )

    assert withdrawn.content["lifecycle_status"] == "done"
    assert met_count(withdrawn.content) == 0
    assert [%{"worker" => "tcf-reviewer"} | _] = withdrawals(withdrawn.content)
  end

  test "CONTROL — `bp task stage` still writes a closed row (done → done)",
       %{scope: scope} do
    %{doc: closed} = closed_done_row!("tcf-control-stage", scope)

    assert {:ok, staged} = Tasks.stage(closed.id, "done", note: "staged by the control")
    assert staged.content["lifecycle_status"] == "done"
    assert met_count(staged.content) == 1
  end
end
