defmodule Barkpark.Tasks.Internal do
  @moduledoc false
  # Shared low-level primitives for the task CAS write paths. Extracted from
  # `Barkpark.Tasks` so the facade and the per-operation modules
  # (`Tasks.Mutations`, …) reuse one definition instead of each carrying its own
  # rev/event/broadcast helpers. Pure substrate — no public task API lives here.

  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Repo

  # New rev token, same shape as `Content.generate_rev/0`. Kept here so the task
  # modules do not depend on a private function in another module.
  def generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  def current_epoch(%Document{content: %{"claim" => %{"epoch" => e}}}) when is_integer(e), do: e
  def current_epoch(_), do: 0

  # Holder check shared by the holder-gated write paths (release, stamp, pulse):
  # the caller must BE the lease holder — `claim.worker` must equal `worker_id`
  # — or the write is `{:error, :not_holder}`. A task with no claim at all also
  # fails (nil ≠ worker_id): there is no lease to act on. Extracted from
  # `Tasks.Release` (D7, expressive-agent-loops) so every new holder-only verb
  # reuses one definition instead of growing its own subtly-different copy.
  def check_holder(%Document{content: content}, worker_id) do
    case get_in(content, ["claim", "worker"]) do
      ^worker_id -> :ok
      _ -> {:error, :not_holder}
    end
  end

  # ─── Acceptance-criteria merge (shared by Close and Stamp) ────────────────
  #
  # Applies `[%{"index" => i, ...}]` updates onto content["acceptance_criteria"].
  # Two update shapes, discriminated by the presence of an `"attempt"` key:
  #
  #   * met/evidence (close + `stamp --met`): `met` defaults to true —
  #     CLOSE-TIME semantics, you are proving the expectation. Callers that
  #     must never flip a lock implicitly (stamp) always pass `met`
  #     EXPLICITLY; the default exists for the close body's back-compat.
  #     `evidence` is written only when a non-empty string.
  #   * miss (`stamp --miss`): `"attempt" => %{"note","ts","worker"}` appends
  #     to the entry's `attempts` list, bounded to the @attempts_bound most
  #     recent, and PINS `met` to its current stored value — explicitly
  #     written, never inherited from the met→true default above, which would
  #     flip a lock on an honest miss (the proven footgun D8 names).
  #
  # The stored `criterion` text is never touched. The optional `"criterion"`
  # guard is a CAS at criteria grain: when given, it must equal the stored
  # text at that index or the whole write aborts with :criteria_mismatch (the
  # caller's view of the list is stale — rows reordered/edited since read).
  # Conflicts (index out of range, guard mismatch) abort the CALLER's whole
  # transaction — deliberate race handling, not silent partial state.
  @attempts_bound 5

  def merge_criteria(content, []), do: {:ok, content}

  def merge_criteria(content, updates) when is_list(updates) do
    existing =
      case Map.get(content, "acceptance_criteria") do
        list when is_list(list) -> list
        _ -> []
      end

    updates
    |> Enum.reduce_while({:ok, existing}, fn update, {:ok, acc} ->
      case apply_criteria_update(acc, update) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, merged} -> {:ok, Map.put(content, "acceptance_criteria", merged)}
      {:error, reason} -> {:error, reason}
    end
  end

  def merge_criteria(_content, _other), do: {:error, :invalid_criteria}

  defp apply_criteria_update(list, %{"index" => index} = update)
       when is_integer(index) and index >= 0 do
    case Enum.at(list, index) do
      %{} = entry ->
        guard = Map.get(update, "criterion")

        if is_binary(guard) and guard != Map.get(entry, "criterion") do
          {:error, :criteria_mismatch}
        else
          with {:ok, entry} <- apply_entry_update(entry, update) do
            {:ok, List.replace_at(list, index, entry)}
          end
        end

      _ ->
        {:error, :criteria_index_out_of_range}
    end
  end

  defp apply_criteria_update(_list, _update), do: {:error, :invalid_criteria}

  # Miss path: append the attempt, bound the list, PIN met explicitly to its
  # current stored value (normalized to a boolean — only a stored `true` is
  # met; absent/malformed pins `false`). A miss NEVER flips a lock.
  defp apply_entry_update(entry, %{"attempt" => %{} = attempt}) do
    attempts =
      case Map.get(entry, "attempts") do
        list when is_list(list) -> list
        _ -> []
      end

    {:ok,
     entry
     |> Map.put("met", Map.get(entry, "met") == true)
     |> Map.put("attempts", Enum.take(attempts ++ [attempt], -@attempts_bound))}
  end

  # Met/evidence path (close-time semantics — see merge_criteria/2 above).
  defp apply_entry_update(entry, update) do
    met = Map.get(update, "met", true)

    if is_boolean(met) do
      entry = Map.put(entry, "met", met)

      entry =
        case Map.get(update, "evidence") do
          e when is_binary(e) and e != "" -> Map.put(entry, "evidence", e)
          _ -> entry
        end

      {:ok, entry}
    else
      {:error, :invalid_criteria}
    end
  end

  # Mutation-events insert. The existing `mutation_events` schema (used by the
  # document spine) is reused verbatim — the `mutation` text column carries our
  # `task.claimed` / `task.closed` / `task.mutated` kinds, the `document` map
  # carries an Envelope-shaped view of the post-update row. Tenancy stamps mirror
  # `Content.save_event/6` so workspace-scoped `recent_activity` reads surface
  # task ops.
  #
  # `source` (P2 push origin tag) defaults to "api" so task events are LOCAL by
  # default → pushable, routed to the claim/epoch path by `type`. Stamping
  # "sync" for a remote-claim-mirror-back requires a seam through tasks.ex and
  # is DEFERRED to P3 — all current callers (in tasks.ex, untouched) use the
  # default.
  #
  # `extra_document` is merged into the `document` map so a typed op can carry
  # its own payload alongside the Envelope-shaped view — e.g. the rail-l3
  # `task.reparented` event stamps `%{"reparented" => %{"from" => …, "to" => …}}`
  # and the rail-l4 allow-and-fence `task.mutated` event stamps
  # `%{"fenced" => "edge_added", "edge" => …}`. It mirrors how `TtlSweeper`
  # nests its `"lease_expired"` reap payload. Defaults to `%{}` (no-op merge),
  # so the claim/close/relabel callers passing arity 3/4 are untouched.
  def insert_mutation_event!(
        %Document{} = doc,
        kind,
        previous_rev,
        source \\ "api",
        extra_document \\ %{}
      ) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: kind,
      rev: doc.rev,
      previous_rev: previous_rev,
      source: to_string(source),
      document:
        Map.merge(
          %{
            "doc_id" => doc.doc_id,
            "type" => doc.type,
            "title" => doc.title,
            "status" => doc.status,
            "content" => doc.content,
            "rev" => doc.rev
          },
          extra_document
        ),
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # Audit stamp: the id of the api_token that drove this workflow mutation.
  # Returns an `extra_document`-shaped fragment so it merges into the event's
  # `document` map (see `insert_mutation_event!/5`) as `"caller_token_id"`,
  # attributing the event to the CALLING TOKEN — distinct from the self-declared
  # `content.claim.worker`. Backward-compatible: an anonymous / tokenless /
  # internal caller (no bearer resolved to `conn.assigns[:api_token]`) threads
  # `nil` and emits NO key, so pre-existing events stay byte-identical.
  def caller_stamp(token_id) when is_binary(token_id), do: %{"caller_token_id" => token_id}
  def caller_stamp(_), do: %{}

  # Every CAS write path bypasses Content's canonical write path
  # (`tap_broadcast/5`), so these mirror its PubSub so the SSE listen endpoint
  # and workspace activity reads see task ops. Content stays the single owner of
  # the topic shapes — task_broadcast/4 only assembles the payload; emit fires it.
  def task_broadcast(%Document{} = doc, kind, %MutationEvent{} = ev, previous_rev) do
    %{doc: doc, kind: kind, event_id: ev.id, previous_rev: previous_rev}
  end

  def emit_broadcasts(broadcasts) when is_list(broadcasts) do
    Enum.each(broadcasts, fn %{doc: doc, kind: kind, event_id: eid, previous_rev: prev} ->
      Content.broadcast_document_mutation(doc, kind, event_id: eid, previous_rev: prev)
    end)

    :ok
  end
end
