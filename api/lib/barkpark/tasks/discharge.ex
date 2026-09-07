defmodule Barkpark.Tasks.Discharge do
  @moduledoc false
  # THE BACK-LINK MARK — the write half of `POST /v1/tasks/:doc_id/discharges`.
  #
  # WHY IT EXISTS (task-29781d0921e5a885). A merged PR credits ONE row, through
  # its one `Task:` trailer. When the same merge also discharged a criterion on
  # a SIBLING row, the ledger had no link from the PR to that sibling, so the
  # sibling kept advertising work that no longer existed. Five measured
  # instances in one day, each costing a re-triage or a dispatched builder.
  #
  # WHAT THIS WRITES, AND WHY IT CANNOT WRITE THE OTHER THING
  # --------------------------------------------------------------------------
  # A back-link is EVIDENCE ABOUT a row, offered by someone who does not hold
  # its claim. It is emphatically NOT a verdict on it: whether a criterion is
  # discharged is the holder's call, made against origin/main, and a mark that
  # could answer it for them would be `Tasks.Landed`'s fabricated-done defect
  # (task-48ff3f84e68aecbb) wearing a new hat — worse, because THIS verb marks
  # rows the caller was never credited with.
  #
  # So the fence is structural, not conditional. There is no code path here that
  # can set `met`, and none that can write `evidence`, `lifecycle_status`, the
  # claim, the disposition or a label:
  #
  #   * with a criterion index → ONE `Map.put(entry, "discharge_marks", …)` on
  #     ONE criterion entry. That literal key is the only key this module ever
  #     puts into a criterion. `Tasks.Internal.merge_criteria/2` — the met-flip
  #     path, with its D56 text guard — is not imported and not called.
  #   * with no criterion index → the sentence unions into `content.landed`
  #     through `Tasks.Internal.merge_landed/2`, the SAME merge a close and a
  #     landing use, under `notes` ONLY.
  #
  # `notes` ONLY, DELIBERATELY. `content.landed.commits` means "THIS row's work
  # landed as this sha" — it is what `scripts/landed-mark.sh` reads to decide a
  # row is already marked. A back-link is a different claim ("a PR credited to
  # ANOTHER row touched you"), so writing the sha there would both overstate it
  # and make a later genuine landing of that sha read as already-done.
  #
  # IDEMPOTENT BY VALUE. A mark is identified by {pr, commit, primary}; a
  # re-run of the same landing finds it present and writes nothing, so a
  # workflow that fires twice does not stack duplicate marks or a second event.
  # The `at` timestamp is deliberately OUT of that key — it is the one field
  # that would differ between two runs of the same fact.
  #
  # Write shape is `Tasks.Landed`'s: per-task advisory lock, in-lock re-read of
  # the PUBLISHED row the controller resolved, CAS-on-rev, a durable
  # `task.discharged` mutation_event carrying the caller token id, post-commit
  # broadcast.

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      merge_landed: 2,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.LockKey

  @event_task_discharged "task.discharged"

  @doc """
  Leave a back-link on `task_id` naming the PR that may have discharged it.

  ## Options
    * `:pr` — the PR number (string or integer). Required in practice: the
      sentence is useless without it.
    * `:commit` — the merge sha.
    * `:primary` — the doc_id of the row the PR's `Task:` trailer credited.
    * `:criterion` — optional zero-based index of the criterion the citation
      named. Out of range is `:criteria_index_out_of_range`; absent means the
      sentence lands in `content.landed.notes` instead.
    * `:caller_token_id` — audit stamp on the event row.

  Returns `{:ok, :marked, doc}`, `{:ok, :already, doc}` (the identical mark was
  already on the row — nothing written), or `{:error, reason}`.
  """
  @spec record(binary(), keyword()) ::
          {:ok, :marked | :already, Document.t()} | {:error, term()}
  def record(task_id, opts \\ []) when is_binary(task_id) do
    pr = trimmed(Keyword.get(opts, :pr))
    commit = trimmed(Keyword.get(opts, :commit))
    primary = trimmed(Keyword.get(opts, :primary))
    index = Keyword.get(opts, :criterion)
    caller_token_id = Keyword.get(opts, :caller_token_id)

    cond do
      is_nil(pr) and is_nil(commit) ->
        # A back-link with neither a PR nor a sha names nothing a reader could
        # go and check, which is the whole product.
        {:error, :empty_discharge}

      not (is_nil(index) or (is_integer(index) and index >= 0)) ->
        {:error, :invalid_criteria}

      true ->
        do_record(task_id, mark(pr, commit, primary), index, caller_token_id)
    end
  end

  @doc """
  The sentence a back-link mark carries, verbatim — the wording
  task-29781d0921e5a885 asked for. Public so the docs and the tests quote ONE
  string instead of two that drift.
  """
  @spec sentence(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def sentence(pr, commit, primary) do
    "possibly discharged by PR #{pr_label(pr)}#{sha_label(commit)}#{primary_label(primary)}; " <>
      "verify against origin/main before re-deriving it"
  end

  defp pr_label(nil), do: "(unnumbered)"
  defp pr_label(pr), do: "##{pr}"

  defp sha_label(nil), do: ""
  defp sha_label(commit), do: " (#{String.slice(commit, 0, 10)})"

  defp primary_label(nil), do: ""
  defp primary_label(primary), do: " under row #{primary}"

  defp mark(pr, commit, primary) do
    %{
      "pr" => pr,
      "commit" => commit,
      "primary" => primary,
      "note" => sentence(pr, commit, primary),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp do_record(task_id, mark, index, caller_token_id) do
    result =
      Repo.transaction(fn ->
        # Close-family advisory lock — the same key close/stamp/landed take, so
        # a back-link cannot interleave halfway through someone's criteria merge.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_id)])

        # global-read: by-PK re-read inside the close-family advisory lock — tenancy was resolved and authorized at the controller (doc_id → task.id), the Close/Stamp/Landed posture. (ONE LINE, directly above the read: tenant-scope-check.sh reads only the immediately-preceding line, so a wrapped justification reads as UNJUSTIFIED.)
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            content = doc.content || %{}

            case apply_mark(content, index, mark) do
              {:error, reason} ->
                {:error, reason}

              :already ->
                {:ok, :already, doc, []}

              {:ok, new_content} ->
                case fenced_content_write(doc, observed_rev, new_content, generate_rev()) do
                  :stale ->
                    {:error, :stale_claim}

                  {:ok, updated} ->
                    ev =
                      insert_mutation_event!(
                        updated,
                        @event_task_discharged,
                        observed_rev,
                        "api",
                        Map.merge(
                          %{"discharge_mark" => Map.put(mark, "criterion", index)},
                          caller_stamp(caller_token_id)
                        )
                      )

                    {:ok, :marked, updated,
                     [task_broadcast(updated, @event_task_discharged, ev, observed_rev)]}
                end
            end
        end
      end)

    case result do
      {:ok, {:ok, outcome, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, outcome, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── The two write shapes ──────────────────────────────────────────────────
  #
  # NO INDEX: the citation named the row, not a criterion. The sentence unions
  # into content.landed under `notes` (see the moduledoc on why not `commits`).
  defp apply_mark(content, nil, mark) do
    note = Map.fetch!(mark, "note")

    if note in landed_notes(content) do
      :already
    else
      {:ok, merge_landed(content, %{"notes" => [note]})}
    end
  end

  # AN INDEX: exactly one criterion entry gains exactly one key. This clause is
  # the whole blast radius of the criterion arm — there is no `met` here to
  # forget to guard, because nothing in it writes a key it did not name.
  defp apply_mark(content, index, mark) do
    criteria = criteria_list(content)

    case Enum.at(criteria, index) do
      %{} = entry ->
        existing = marks_of(entry)

        if Enum.any?(existing, &same_mark?(&1, mark)) do
          :already
        else
          updated = Map.put(entry, "discharge_marks", existing ++ [mark])

          {:ok,
           Map.put(content, "acceptance_criteria", List.replace_at(criteria, index, updated))}
        end

      _ ->
        {:error, :criteria_index_out_of_range}
    end
  end

  defp criteria_list(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp marks_of(entry) do
    case Map.get(entry, "discharge_marks") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp landed_notes(content) do
    with %{} = landed <- Map.get(content, "landed"),
         list when is_list(list) <- Map.get(landed, "notes") do
      list
    else
      _ -> []
    end
  end

  # IDENTITY IS {pr, commit, primary} — `at` is excluded on purpose: it is the
  # one field two runs of the same landing disagree about, so including it would
  # make every re-run append a duplicate.
  defp same_mark?(%{} = a, %{} = b) do
    Enum.all?(["pr", "commit", "primary"], fn k -> Map.get(a, k) == Map.get(b, k) end)
  end

  defp same_mark?(_, _), do: false

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(value) when is_integer(value), do: Integer.to_string(value)
  defp trimmed(_), do: nil
end
