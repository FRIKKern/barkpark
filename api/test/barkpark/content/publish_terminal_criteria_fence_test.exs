defmodule Barkpark.Content.PublishTerminalCriteriaFenceTest do
  @moduledoc """
  THE PUBLISH SEAM'S TERMINAL-CRITERIA DOOR (task-b821ec4b2bcf8087).

  `Barkpark.Tasks.TerminalCriteriaFence` (#17949) refuses a DOCUMENT-DOOR write
  that changes `acceptance_criteria` on a task row that is, and stays,
  closed-terminal. It is wired into `Content.Writer`'s two task chains. Its own
  moduledoc states the residue it does NOT cover: a draft whose criteria list
  was LEGAL when it was written, published onto the closed row AFTER the
  published row's criteria moved underneath it. That publish write is
  `Document.changeset |> Repo.update` inside `Content.Lifecycle`, not Writer.

  ## THE SEQUENCE, corrected against the filing

  The row's criterion describes "mint a draft of an open task, close the
  published twin done, then publish the pre-existing draft carrying an extra
  UNMET criterion". Neither half of that ordering is reachable on main, and
  saying so is part of the proof:

    * a draft minted while the twin is OPEN and carrying `lifecycle_status:
      "done"` is refused by `Tasks.ChangeGuards.transition_legal/6` ("`done` is
      reached only through the close primitive"), and one carrying `"open"`
      REOPENS the row on publish — which this fence exempts by design;
    * a draft minted while the twin is open carries the PRE-close claim map, and
      `Tasks.Close` stamps `closed_by`/`closed_at` INSIDE `content.claim`, so
      `Content.Lifecycle`'s `stale_claim?/2` refuses that publish long before
      any criteria gate looks.

  What IS open is the same harm one verb later: the draft is minted BYTE-
  IDENTICAL to the closed published row (every gate waves it through, because
  nothing diverges yet), and then a SANCTIONED task-door verb moves the
  published row's criteria underneath it — `bp task stamp --withdraw` (D745),
  the one verb allowed to lower a lock on a closed row. The stale draft now
  carries the pre-withdrawal proof. Publishing it copies that proof back over
  the published row: `met` flips back to true and the append-only `withdrawals`
  record is DELETED, with no attribution and no event. False-done, restored by
  a door that never named the field.

  Every gate in `gate_task_publish/2` passes on its own terms: `done -> done` is
  a legal no-op, the claim is byte-identical, no task-door-owned field moves,
  and the regression fence sees the published criterion's evidence preserved
  (the draft ADVANCES `met` rather than regressing it).

  ## RED without / GREEN with

  Test (a) composes its flunk message out of the LANDED state, so the red quotes
  the hole rather than asserting about it.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.TerminalCriteriaFence

  @dataset "publish_terminal_criteria_fence_test"

  @c0 "the scratch row carries one provable criterion"
  @extra %{"criterion" => "an entry no close was ever granted on", "met" => false}

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

  defp base_content do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [%{"criterion" => @c0, "met" => false}]
    }
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    # The Tasks plugin's :before_publish brief wall (inert until #19303).
    |> Barkpark.TaskBriefFixtures.with_brief()
  end

  defp doc_write(doc_id, content, scope) do
    Content.create_document(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => "Publish terminal criteria fixture #{doc_id}",
        "content" => content
      },
      @dataset,
      scope
    )
  end

  defp published(doc_id, scope) do
    {:ok, %Document{} = doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  defp criteria(c), do: c["acceptance_criteria"] || []
  defp met_count(c), do: Enum.count(criteria(c), &(&1["met"] == true))
  defp withdrawals(c), do: c |> criteria() |> Enum.flat_map(&(&1["withdrawals"] || []))

  # A scratch row walked to `done` through the SANCTIONED verbs only.
  defp closed_done_row!(doc_id, scope) do
    {:ok, _draft} = doc_write(doc_id, base_content(), scope)
    {:ok, _pub} = Content.publish_document(doc_id, "task", @dataset, scope)

    {:ok, claimed} = Tasks.claim_by_id(doc_id, "ptcf-worker", scope)
    epoch = claimed.content["claim"]["epoch"]

    {:ok, _stamped} =
      Tasks.stamp(claimed.id, "ptcf-worker",
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: @c0,
        outcome: {:met, "proven by publish_terminal_criteria_fence_test.exs"}
      )

    {:ok, closed} = Tasks.close(claimed.id, "ptcf-worker", observed_epoch: epoch)
    assert closed.content["lifecycle_status"] == "done"
    assert met_count(closed.content) == 1

    %{doc: closed, epoch: epoch}
  end

  # Step 2: the draft is minted BYTE-IDENTICAL to the closed row, so every
  # existing gate — #17949's fence included — legitimately waves it through.
  defp mint_verbatim_draft!(doc_id, closed, scope) do
    {:ok, draft} = doc_write("drafts." <> doc_id, closed.content, scope)
    draft
  end

  # Step 3: the SANCTIONED correction that moves the published row underneath
  # the draft — D745's withdraw, the only verb allowed to lower a lock on a
  # closed row.
  defp withdraw!(closed, epoch, scope) do
    current = published(closed.doc_id, scope)

    {:ok, withdrawn} =
      Tasks.stamp(closed.id, "ptcf-reviewer",
        observed_epoch: epoch,
        observed_rev: current.rev,
        criterion: 0,
        criterion_text: @c0,
        outcome: {:withdraw, "review found the proof did not hold"}
      )

    assert met_count(withdrawn.content) == 0
    assert [%{"worker" => "ptcf-reviewer"} | _] = withdrawals(withdrawn.content)
    withdrawn
  end

  # ── (a) THE RESIDUE — reproduced, then refused ───────────────────────────

  test "publishing a stale draft over a WITHDRAWN criterion on a done row is REFUSED",
       %{scope: scope} do
    id = "ptcf-witness"
    %{doc: closed, epoch: epoch} = closed_done_row!(id, scope)
    _draft = mint_verbatim_draft!(id, closed, scope)
    withdrawn = withdraw!(closed, epoch, scope)
    before_rev = published(id, scope).rev

    case Content.publish_document(id, "task", @dataset, scope) do
      {:error, {:invalid_task_content, details}} ->
        message = details["acceptance_criteria"] |> List.first()
        assert message =~ "CLOSED terminal"
        assert message =~ "--withdraw"
        assert message =~ "D745"

        after_doc = published(id, scope)
        assert after_doc.rev == before_rev
        assert met_count(after_doc.content) == 0
        assert withdrawals(after_doc.content) != []

      {:ok, _published} ->
        after_doc = published(id, scope)

        flunk("""
        PRECONDITION PROVEN — THE PUBLISH SEAM IS OPEN. The stale draft published \
        over the withdrawal on the already-`done` row:
          lifecycle_status : #{inspect(withdrawn.content["lifecycle_status"])} -> \
        #{inspect(after_doc.content["lifecycle_status"])}
          criteria met     : #{met_count(withdrawn.content)}/#{length(criteria(withdrawn.content))} -> \
        #{met_count(after_doc.content)}/#{length(criteria(after_doc.content))}
          rev              : #{before_rev} -> #{after_doc.rev}
          withdrawals      : #{inspect(withdrawals(withdrawn.content))} -> \
        #{inspect(withdrawals(after_doc.content))}
        D745's append-only withdrawal record was DELETED by a publish that named \
        no such intent, and the row reads `done` on proof a reviewer had taken \
        back — TerminalCriteriaFence's own rule, at the one door it was never \
        wired into.
        """)
    end
  end

  test "the refusal is the FENCE's own sentence, not a second spelling of it", %{scope: scope} do
    id = "ptcf-one-spelling"
    %{doc: closed, epoch: epoch} = closed_done_row!(id, scope)
    _draft = mint_verbatim_draft!(id, closed, scope)
    withdrawn = withdraw!(closed, epoch, scope)

    assert {:error, {:invalid_task_content, details}} =
             Content.publish_document(id, "task", @dataset, scope)

    {:error, {:invalid_task_content, fence_details}} =
      TerminalCriteriaFence.refusal(withdrawn.content, closed.content)

    assert List.first(details["acceptance_criteria"]) ==
             List.first(fence_details["acceptance_criteria"])
  end

  # ── (b) CONTROLS — what the fence must NOT break ─────────────────────────

  test "CONTROL: a publish that REOPENS the row in the same write still lands", %{scope: scope} do
    id = "ptcf-reopen"
    %{doc: closed} = closed_done_row!(id, scope)

    reopening =
      closed.content
      |> Map.put("lifecycle_status", "open")
      |> Map.put("acceptance_criteria", criteria(closed.content) ++ [@extra])

    {:ok, _} = doc_write("drafts." <> id, reopening, scope)

    assert {:ok, %Document{} = pub} = Content.publish_document(id, "task", @dataset, scope)
    assert pub.content["lifecycle_status"] == "open"
    assert length(criteria(pub.content)) == 2
  end

  test "CONTROL: a publish that does not CHANGE acceptance_criteria on a done row still lands",
       %{scope: scope} do
    id = "ptcf-untouched"
    %{doc: closed} = closed_done_row!(id, scope)

    _draft =
      mint_verbatim_draft!(
        id,
        %{closed | content: Map.put(closed.content, "notes", "a field no gate owns")},
        scope
      )

    assert {:ok, %Document{} = pub} = Content.publish_document(id, "task", @dataset, scope)
    assert pub.content["lifecycle_status"] == "done"
    assert met_count(pub.content) == 1
    assert pub.content["notes"] == "a field no gate owns"
  end

  test "CONTROL: a FIRST publish of a born-done draft is a birth and still lands",
       %{scope: scope} do
    id = "ptcf-birth"

    born_done =
      base_content()
      |> Map.put("lifecycle_status", "done")
      |> Map.put("acceptance_criteria", [%{"criterion" => @c0, "met" => true}, @extra])

    {:ok, _} = doc_write(id, born_done, scope)

    assert {:ok, %Document{} = pub} = Content.publish_document(id, "task", @dataset, scope)
    assert pub.content["lifecycle_status"] == "done"
    assert length(criteria(pub.content)) == 2
  end
end
