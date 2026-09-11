defmodule Barkpark.Tasks.CriteriaContract do
  @moduledoc false
  # THE CLAIM-TIME ACCEPTANCE CONTRACT (task-11390a3b900c8a09, c2).
  #
  # INCIDENT, 2026-07-10 19:08:38Z. A concurrent epic session's read-modify-write
  # patch onto `gp-w5-epic-close` carried ANOTHER task's
  # (`era-w8-zero-tax-harness`) acceptance_criteria array as its base: foreign
  # criterion texts at ALL FOUR indexes, foreign evidence at 0 and 3, the
  # writer's own genuine evidence at 1 and 2. Both rows stayed superficially
  # valid; the substitution was recovered by hand from revision history.
  #
  # WHY EVERY EXISTING DOOR LET IT THROUGH. Three guards look like they cover
  # this and none of them does:
  #
  #   * `Tasks.Internal.apply_criteria_update/2` (the stamp/close `--set`
  #     door) CASes each update's `"criterion"` text against the stored text
  #     (`:criteria_mismatch`) and fails closed on an unguarded met-flip
  #     (`:criterion_text_required`). But it only ever UPDATES entries in the
  #     stored list — it cannot replace the list, so it is not this door.
  #   * `Tasks.Close.check_work_digest/2` compares the doc's live
  #     work-field digests to `claim.work_field_digests` and 409s
  #     `doc_changed_since_claim`. That fires at CLOSE — i.e. AFTER the
  #     substitution has already landed and been published.
  #   * `Content.Lifecycle.criteria_fence/2` refuses a publish that REGRESSES a
  #     proof-bearing criterion. It matches the published row's criterion by
  #     TEXT first and then FALLS BACK TO THE POSITIONAL SLOT — deliberately, so
  #     a legitimate reword of an already-met criterion is not read as a drop.
  #     That fallback is the hole: in the incident every index held a foreign
  #     row that ALSO carried met/evidence, so each proof-bearing published row
  #     found a positional counterpart that regressed nothing, and the publish
  #     was accepted with zero warnings.
  #
  # WHAT THIS ADDS, AND ONLY THIS. A wholesale substitution is not an edit of
  # the acceptance contract — it is a DIFFERENT contract wearing the row's id.
  # So: while a lease is live and the published criterion texts still ARE the
  # texts the claim was taken against, a write whose criterion texts share
  # NOTHING with them is refused.
  #
  # THE PREDICATE, and why each clause is there. All must hold to refuse:
  #
  #   1. the published row carries a LIVE claim — a `claim` map with a
  #      `worker`, no `closed_at`/`closed_by`. An unclaimed or already-closed
  #      row has no lease to contradict, and authoring a task's criteria list
  #      stays a plain content edit (the same scope rule `criteria_fence/2`
  #      draws around unproven criteria).
  #   2. the claim carries `work_field_digests["acceptance_criteria"]`. Legacy
  #      leases predating `WorkDigest` are exempt, exactly as
  #      `Close.check_work_digest/2` exempts them.
  #   3. that stored digest still EQUALS the digest of the published criterion
  #      texts. This is what makes the refusal a statement about the CLAIM-TIME
  #      contract rather than about whatever the list happens to hold now: if
  #      the texts already moved since the claim, this gate has no claim-time
  #      set to compare against and says nothing (close's digest fence is the
  #      one that speaks to that drift).
  #   4. the claim-time set holds AT LEAST TWO distinct non-blank texts. On a
  #      single-criterion row "every text replaced" and "the one criterion was
  #      reworded" are the same event, and a reword is legitimate. Refusing
  #      there would convert a legal edit into a wall.
  #   5. the incoming list is non-empty and its texts are DISJOINT from the
  #      claim-time set. Not "different" — disjoint. Adding a criterion keeps
  #      all N; rewording one of N keeps N-1; reordering keeps N; editing
  #      met/evidence/attempts keeps N. Every one of those passes. Only a
  #      write in which not a single claim-time criterion survives is refused.
  #
  # An emptied list (`[]`) is deliberately NOT refused here: dropping the
  # criteria is a regression the proof-bearing `criteria_fence/2` already names
  # per-row, and a criteria-less close has its own artifact gate. This module
  # answers exactly one question — SUBSTITUTION — and leaves deletion to the
  # doors that already own it.
  #
  # Refusals use the `{:invalid_task_content, %{field => [msg]}}` family (→ 422
  # `validation_failed` via `Content.Errors`), the same shape the two gates
  # beside it at the publish seam already use. The gate runs BEFORE the write
  # and touches no claim, so nothing is written and no epoch is consumed.

  alias Barkpark.Tasks.WorkDigest

  @doc """
  `:ok`, or `{:error, {:invalid_task_content, errors}}` when `incoming` would
  substitute the whole claim-time acceptance contract of `published`.

  Both arguments are task `content` maps.
  """
  def check_substitution(published, incoming) when is_map(published) and is_map(incoming) do
    with {:ok, claim} <- live_claim(published),
         {:ok, stored_digest} <- criteria_digest(claim),
         {:ok, contract} <- claim_time_texts(published, stored_digest),
         incoming_texts = text_set(incoming),
         true <- MapSet.size(incoming_texts) > 0,
         true <- MapSet.disjoint?(contract, incoming_texts) do
      {:error, {:invalid_task_content, substitution_error(claim, contract, incoming_texts)}}
    else
      _ -> :ok
    end
  end

  def check_substitution(_published, _incoming), do: :ok

  # A lease nobody is holding right now cannot be contradicted. `closed_at` /
  # `closed_by` are stamped INTO the claim by `Close.apply_close_update/8`, so
  # their presence is the end of the lease even though the map survives.
  defp live_claim(%{"claim" => %{"worker" => worker} = claim}) when is_binary(worker) do
    if is_nil(Map.get(claim, "closed_at")) and is_nil(Map.get(claim, "closed_by")) do
      {:ok, claim}
    else
      :no_live_claim
    end
  end

  defp live_claim(_content), do: :no_live_claim

  defp criteria_digest(claim) do
    case get_in(claim, ["work_field_digests", "acceptance_criteria"]) do
      digest when is_binary(digest) -> {:ok, digest}
      _ -> :no_digest
    end
  end

  # Clauses 3 + 4: the published texts must still hash to the claim-time
  # digest, and there must be two or more of them to tell substitution from a
  # reword. `WorkDigest.field_digests/2` is the ONE definition of how criteria
  # texts hash — re-deriving it here would be a second, driftable copy, so the
  # title is passed through it and only the criteria sub-digest is read.
  defp claim_time_texts(published, stored_digest) do
    current = WorkDigest.field_digests(nil, published)["acceptance_criteria"]

    texts = text_set(published)

    if current == stored_digest and MapSet.size(texts) >= 2 do
      {:ok, texts}
    else
      :not_the_claim_time_contract
    end
  end

  defp text_set(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) ->
        list
        |> Enum.flat_map(fn
          %{"criterion" => text} when is_binary(text) ->
            if String.trim(text) == "", do: [], else: [text]

          _ ->
            []
        end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp substitution_error(claim, contract, incoming_texts) do
    worker = Map.get(claim, "worker")
    epoch = Map.get(claim, "epoch")

    %{
      "acceptance_criteria" => [
        "refused: this write replaces the acceptance contract WHOLESALE — not one of the " <>
          "#{MapSet.size(contract)} criterion texts this row's live claim (worker " <>
          "#{inspect(worker)}, epoch #{inspect(epoch)}) was taken against survives in the " <>
          "#{MapSet.size(incoming_texts)} texts offered. A read-modify-write that picked up " <>
          "ANOTHER task's criteria array looks exactly like this, and it is how " <>
          "gp-w5-epic-close came to carry era-w8-zero-tax-harness's contract on 2026-07-10. " <>
          "Nothing was written and the claim is untouched. Re-read the row " <>
          "(`bp task get <id>`) and send an edit built on ITS criteria: adding a criterion, " <>
          "rewording one, reordering, or stamping evidence all pass this gate. If the " <>
          "contract genuinely must be rewritten from scratch, release the claim first " <>
          "(`bp task release <id> <worker>`)."
      ]
    }
  end
end
