defmodule Barkpark.Tasks.Internal do
  @moduledoc false
  # Shared low-level primitives for the task CAS write paths. Extracted from
  # `Barkpark.Tasks` so the facade and the per-operation modules
  # (`Tasks.Mutations`, …) reuse one definition instead of each carrying its own
  # rev/event/broadcast helpers. Pure substrate — no public task API lives here.

  import Ecto.Query, only: [from: 2]

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

  # ─── The fenced content write (PDS-D451: the receipt is the STORED row) ───
  #
  # Every task CAS write path used to do the same two things: run a rev-fenced
  # `Repo.update_all(set: [content:, rev:, updated_at:])`, which returns a ROW
  # COUNT and never a row, and then RECONSTRUCT the receipt as
  # `%{doc | content: new_content, rev: new_rev}`. That reconstruction is a
  # statement of INTENT, not of storage: `updated_at` is deliberately written to
  # the DB and deliberately absent from the struct, so every claim/stamp/close
  # receipt carried the PREVIOUS write's timestamp — measured, byte-exact, on
  # every verb. Worse as a CLASS: `documents` carries `slug_text`/`author_text`/
  # `category_text` as `GENERATED ALWAYS AS (…) STORED` (`Content.Document`,
  # `read_after_writes: true`), which a struct-merge cannot recompute at all.
  #
  # IMPLEMENTATION CHOSEN: `select: d` on the update query, so it compiles to
  # `UPDATE … RETURNING` and the row Postgres actually holds — generated columns
  # included — comes back in ONE statement. This is the idiom the document spine
  # already uses (`content/writer.ex` fenced update, `auth.ex consume_login_ticket`).
  # The alternative, `Repo.get!(Document, doc.id)` in the `{1, _}` branch, is
  # equally correct under the per-task `pg_advisory_xact_lock` every caller holds,
  # but costs a second round trip and reads a row the same txn just wrote.
  # NEVER Ecto's `:returning` option — `update_all` SILENTLY IGNORES it and
  # yields `{count, nil}` (documented in-repo at `auth.ex` consume_login_ticket).
  #
  # Returns `{:ok, stored_doc}` on a won fence and `:stale` on a lost one. The
  # atom is deliberately NOT an `{:error, …}` tuple: callers map it to their own
  # existing error (`:stale_claim` for the lifecycle/claim arms, `:stale_rev` for
  # the merge reconcile), so no caller's return shape moves.
  def fenced_content_write(%Document{} = doc, observed_rev, new_content, new_rev) do
    query =
      from(d in Document,
        where: d.id == ^doc.id and d.rev == ^observed_rev,
        select: d
      )

    case Repo.update_all(query,
           set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
         ) do
      {1, [stored]} -> {:ok, stored}
      {0, _} -> :stale
    end
  end

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

  # ─── Close-honesty predicates (PDS-D288 / D289 / D290) ────────────────────
  #
  # THESE ARE HONESTY GATES, NOT AUTHORIZATION. `worker_id` is a client-supplied
  # body param (`tasks_controller.ex` close/2 reads it straight out of the JSON
  # body), never derived from the api_token — anyone who can call close can name
  # any worker. What these predicates buy is that the LEDGER stops recording a
  # close as if the closer held the lease and the criteria were proven when
  # neither was true: an ACCIDENT is refused, and a DELIBERATE foreign close has
  # to say so out loud and is auditable afterwards. Do not sell them as access
  # control.

  # Close-holder predicate (PDS-D288). Deliberately NOT `check_holder/2` above:
  # that one fails on a nil claim, which would refuse every never-claimed
  # root/container close AND every self-resume close. Three allow-arms:
  #
  #   * `:unclaimed`   — no claim map at all. Nothing was ever leased, so there
  #     is no holder to contradict (this is what `Close.check_fencing/2`'s bare
  #     `_ -> :ok` has always permitted, preserved verbatim).
  #   * `:holder`      — `claim.worker == worker_id`. The ordinary close.
  #   * `:self_resume` — the lease was given up (`claim.worker` nil) and THIS
  #     worker is the one who gave it up. BOTH keys are checked on purpose: a
  #     TTL reap writes `previous_worker` (`ttl_sweeper.ex`) while a voluntary
  #     release writes `released_by` (`release.ex`), so keying on one silently
  #     refuses the other path.
  #
  # Anything else is `{:error, {:not_holder, held_by}}` — the caller may retry
  # with an explicit, recorded override (see `Tasks.Close`), never silently.
  def close_holder(%Document{content: content}, worker_id) when is_binary(worker_id) do
    case claim_map(content) do
      nil ->
        {:ok, :unclaimed}

      claim ->
        cond do
          Map.get(claim, "worker") == worker_id ->
            {:ok, :holder}

          is_nil(Map.get(claim, "worker")) and
              worker_id in [Map.get(claim, "previous_worker"), Map.get(claim, "released_by")] ->
            {:ok, :self_resume}

          true ->
            {:error, {:not_holder, held_by(claim)}}
        end
    end
  end

  # Who the ledger believes holds (or last held) the lease — the `held_by` the
  # override record has to name. nil when the claim map names nobody at all.
  def held_by(claim) when is_map(claim) do
    Map.get(claim, "worker") || Map.get(claim, "previous_worker") ||
      Map.get(claim, "released_by")
  end

  def held_by(_), do: nil

  defp claim_map(content) do
    case Map.get(content || %{}, "claim") do
      claim when is_map(claim) -> claim
      _ -> nil
    end
  end

  # Every acceptance criterion that is NOT proven, as
  # `[%{"index" => i, "criterion" => text_or_nil}]` in list order. Counting
  # matches `Tasks.Criteria.progress/1` exactly: `met` must be EXACTLY `true`,
  # and garbage (a non-map entry, a missing key, `"yes"`, `1`) counts as UNMET
  # rather than crashing — an unreadable criterion is not a proven one. Absent
  # or non-list criteria yield `[]` (nothing to prove, never "0/0").
  def unmet_criteria(content) do
    case Map.get(content || %{}, "acceptance_criteria") do
      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reject(fn {entry, _i} -> met?(entry) end)
        |> Enum.map(fn {entry, i} -> %{"index" => i, "criterion" => criterion_text(entry)} end)

      _ ->
        []
    end
  end

  defp met?(entry) when is_map(entry),
    do: Map.get(entry, "met") == true or Map.get(entry, :met) == true

  defp met?(_entry), do: false

  defp criterion_text(entry) when is_map(entry) do
    case Map.get(entry, "criterion") || Map.get(entry, :criterion) do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp criterion_text(_entry), do: nil

  # Sentinel worker ids (PDS-D290). 21 recorded closes carry the literal string
  # `"None"` as `closed_by` — a stringified null from some caller's templating,
  # accepted because `Params.fetch_string/2` only asks for a non-empty binary.
  # A close attributed to "None" reads as a real close to every downstream gate,
  # so refuse the shapes that can only be a missing value, at the engine.
  @sentinel_worker_ids ~w(none null nil -)

  def check_worker_id(worker_id) when is_binary(worker_id) do
    trimmed = String.trim(worker_id)

    if trimmed == "" or String.downcase(trimmed) in @sentinel_worker_ids do
      {:error, {:sentinel_worker_id, worker_id}}
    else
      :ok
    end
  end

  # ─── Acceptance-criteria merge (shared by Close and Stamp) ────────────────
  #
  # Applies updates onto content["acceptance_criteria"]. An update names its row
  # in one of TWO dialects, and a caller speaks exactly one of them per command
  # (the mixed-array refusal lives one layer up, in `Params.parse_criteria/1`,
  # where it costs no document read):
  #
  #   * INDEXED — `%{"index" => i, …}`, 0-based, with `"criterion"` as the
  #     stored-text CAS. REQUIRED on any met-flip (D56, below).
  #   * TEXT-KEYED — `%{"criterion" => "<the exact stored wording>", …}` with no
  #     index: the AUTHORING rubric shape, resolved to an index here by exact
  #     match (see `apply_criteria_update/2`'s text-keyed clause). It carries its
  #     own guard by construction, so it can never flip a neighbour.
  #
  # Orthogonally, two update KINDS, discriminated by the presence of an
  # `"attempt"` key:
  #
  #   * met/evidence (close + `stamp --met`): `met` defaults to true —
  #     CLOSE-TIME semantics, you are proving the expectation. Callers that
  #     must never flip a lock implicitly (stamp) always pass `met`
  #     EXPLICITLY; the default exists for the close body's back-compat.
  #     An omitted `evidence` key preserves the stored value; an explicitly
  #     present string is written verbatim, including `""` to clear it.
  #   * miss (`stamp --miss`): `"attempt" => %{"note","ts","worker"}` appends
  #     to the entry's `attempts` list, bounded to the @attempts_bound most
  #     recent, and PINS `met` to its current stored value — explicitly
  #     written, never inherited from the met→true default above, which would
  #     flip a lock on an honest miss (the proven footgun D8 names).
  #   * withdrawal (`stamp --withdraw`, D745): `"withdrawal" => %{"note","ts",
  #     "worker"}` LOWERS `met` to false and APPENDS the record to the entry's
  #     `withdrawals` list, snapshotting the evidence it supersedes. See the
  #     WITHDRAWAL block below.
  #
  # The stored `criterion` text is never touched. The `"criterion"` guard is a
  # CAS at criteria grain: it must equal the stored text at that index or the
  # whole write aborts with :criteria_mismatch (the caller's view of the list is
  # stale — rows reordered/edited since read, or the index is off by one).
  # Conflicts (index out of range, guard mismatch) abort the CALLER's whole
  # transaction — deliberate race handling, not silent partial state.
  #
  # FAIL CLOSED ON A MET-FLIP (D56, wave 5). The guard used to be OPTIONAL, so
  # in the wild it never fired: an index-only `met: true` update landed silently
  # on whatever row the (frequently 1-based-by-habit) index happened to hit, and
  # five of eight Wave-4 builders shifted their evidence onto a NEIGHBOUR — one
  # of them fabricating a met=true on a merge-gated criterion it could not
  # possibly have proven. A guard that reads as protection and is not is worse
  # than no guard. So: ANY update whose effective `met` is `true` MUST carry a
  # non-empty `"criterion"` text, or it is `{:error, :criterion_text_required}`.
  # The two permissive paths that flip NOTHING are untouched:
  #
  #   * `--miss` (an `"attempt"` key) — records an honest attempt, pins `met` to
  #     its stored value. Nothing to fabricate, no text needed.
  #   * an explicit `met: false` — un-flipping / an honest unmet close.
  #
  # Blast radius is accepted and named: every caller that flips a lock by index
  # alone now gets a 409 telling it exactly what to pass (see the controller's
  # `criteria_hint/2`). Close's own merge-gate autostamp threads the stored text
  # in (close.ex `autostamp_merge_gate/6`) rather than riding the old hole.
  #
  # THE WITHDRAWAL (D745, wave 62). A met flag that review later refutes had no
  # verb: the write surface offers `--met` and `--miss` only, so a reviewer who
  # found a stamped proof false could not lower the lock and wrote the
  # correction into the criterion's own `evidence` prose instead
  # ("[WITHDRAWN BY WAVE REVIEW … the ledger refuses a met:true -> met:false
  # patch, so read this evidence, not the flag]"). Twelve criteria across two
  # rows now carry exactly that, and every board reads them MET. The fix is not
  # "permit a silent un-flip" — an un-flip that leaves no trace is the same
  # unaccountable rewrite the append-only instinct exists to refuse. It is to
  # make the withdrawal FIRST-CLASS:
  #
  #   * `met` goes to FALSE, so criteria_progress drops and every board that
  #     counts locks tells the truth without reading prose.
  #   * `evidence` is NOT touched. The original stamp stays exactly where it was
  #     written and stays readable — the append-only guarantee is kept by
  #     ADDING, never by clearing.
  #   * a record lands on the entry's `withdrawals` list naming WHO withdrew it,
  #     WHY, WHEN, and the evidence it supersedes (snapshotted at withdrawal
  #     time, so a later re-stamp cannot quietly rewrite what was withdrawn).
  #   * the list is UNBOUNDED, deliberately, unlike `attempts`. A bound is a
  #     silent drop, and a silent drop of a correction is the defect this verb
  #     exists to end. Withdrawals are rare; attempts are chatter.
  #
  # A withdrawal carries the SAME `"criterion"` text CAS as a met-flip. Lowering
  # the wrong neighbour is as much a lie as raising it, so both directions fail
  # closed on a missing guard (`:criterion_text_required`).
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

  # TEXT-KEYED ENTRIES (the AUTHORING rubric shape). An update with NO "index"
  # but a non-empty "criterion" names its row the way `bp task get` prints it —
  # `%{"criterion" => …, "met" => …, "evidence" => …}`, exactly the stored row —
  # so an agent can flip the rubric it just read instead of reconstructing
  # 0-based indices by hand (the ergonomic half of gh-2314).
  #
  # Resolution is EXACT string equality against the stored `criterion` text,
  # performed HERE — inside the caller's transaction, against the list as the
  # write sees it — never in the pure param parser, which has no document. The
  # resolved index then falls through to the SAME indexed clause below, so a
  # text-keyed update inherits every guard verbatim: the text it resolved by IS
  # the `criterion` CAS, which means a met-flip is guarded by construction.
  #
  # AMBIGUITY IS REFUSED, NEVER GUESSED. Two stored rows may carry identical
  # wording; picking the first would be the same silent-neighbour bug D56 closed
  # for unguarded indices, wearing a different hat. Zero matches is equally
  # loud. Both abort the whole write:
  #
  #   * `:criterion_not_found`  — no stored row has that exact wording (the text
  #     was edited, or the caller retyped rather than copied).
  #   * `:criterion_ambiguous`  — 2+ rows share it; pass `"index"` to say which.
  defp apply_criteria_update(list, %{"criterion" => text} = update)
       when is_binary(text) and text != "" and not is_map_key(update, "index") do
    case resolve_criterion_index(list, text) do
      {:ok, index} -> apply_criteria_update(list, Map.put(update, "index", index))
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_criteria_update(list, %{"index" => index} = update)
       when is_integer(index) and index >= 0 do
    case Enum.at(list, index) do
      %{} = entry ->
        guard = Map.get(update, "criterion")

        cond do
          # Stale/off-by-one view of the list: the caller named a criterion, and
          # it is not the one stored at `index`. Abort the whole write.
          is_binary(guard) and guard != Map.get(entry, "criterion") ->
            {:error, :criteria_mismatch}

          # Fail closed: a met-flip with no text to CAS against is exactly the
          # false-done vector (an unverifiable index landing on a neighbour).
          flips_met_true?(update) and not guarded?(guard) ->
            {:error, :criterion_text_required}

          # A withdrawal LOWERS a lock, so it cannot fabricate a done — but an
          # unguarded index would lower the WRONG row, which is its own lie.
          # Same guard, same error, one definition for both directions.
          withdraws?(update) and not guarded?(guard) ->
            {:error, :criterion_text_required}

          # A withdrawal of a criterion that was never met records a retraction
          # of nothing. Refuse it rather than write a misleading history entry
          # onto an already-honest row.
          withdraws?(update) and Map.get(entry, "met") != true ->
            {:error, :criterion_not_met}

          true ->
            with {:ok, entry} <- apply_entry_update(entry, update) do
              {:ok, List.replace_at(list, index, entry)}
            end
        end

      _ ->
        {:error, :criteria_index_out_of_range}
    end
  end

  defp apply_criteria_update(_list, _update), do: {:error, :invalid_criteria}

  # Exact-match row lookup for a text-keyed update. Exactly one hit resolves;
  # zero and many are both named refusals (see the clause above).
  defp resolve_criterion_index(list, text) do
    list
    |> Enum.with_index()
    |> Enum.filter(fn {entry, _i} -> is_map(entry) and Map.get(entry, "criterion") == text end)
    |> case do
      [{_entry, index}] -> {:ok, index}
      [] -> {:error, :criterion_not_found}
      _many -> {:error, :criterion_ambiguous}
    end
  end

  # A guard only guards when it has words: `nil` and `""` are no guard at all.
  # (An `""` that "matches" a text-less criterion row must not buy a free flip.)
  defp guarded?(guard), do: is_binary(guard) and guard != ""

  # Does this update flip the lock to true? The miss path (an `"attempt"` key)
  # never flips — it pins met to the stored value. Everything else is the
  # met/evidence path, where an ABSENT `"met"` key means true (close's
  # back-compat default), so an index+evidence update flips too.
  defp flips_met_true?(%{"attempt" => %{}}), do: false
  defp flips_met_true?(%{"withdrawal" => %{}}), do: false
  defp flips_met_true?(update), do: Map.get(update, "met", true) == true

  # A withdrawal is discriminated by its `"withdrawal"` record, never by the
  # `met: false` it also carries — an honest unmet close writes that too and is
  # not a withdrawal.
  defp withdraws?(%{"withdrawal" => %{}}), do: true
  defp withdraws?(_update), do: false

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

  # Withdrawal path (D745): lower the lock, append the record, and LEAVE THE
  # EVIDENCE ALONE. The record snapshots the evidence it supersedes so the
  # withdrawn proof is legible even if the criterion is later re-stamped, and
  # the list is unbounded because dropping a correction silently is the whole
  # defect. Ordered before the met/evidence clause so a withdrawal never falls
  # through to it.
  defp apply_entry_update(entry, %{"withdrawal" => %{} = record}) do
    withdrawals =
      case Map.get(entry, "withdrawals") do
        list when is_list(list) -> list
        _ -> []
      end

    record =
      Map.put(record, "superseded_evidence", to_string(Map.get(entry, "evidence") || ""))

    {:ok,
     entry
     |> Map.put("met", false)
     |> Map.put("withdrawals", withdrawals ++ [record])}
  end

  # Met/evidence path (close-time semantics — see merge_criteria/2 above).
  defp apply_entry_update(entry, update) do
    met = Map.get(update, "met", true)

    if is_boolean(met) do
      entry = Map.put(entry, "met", met)

      case Map.fetch(update, "evidence") do
        :error -> {:ok, entry}
        {:ok, evidence} when is_binary(evidence) -> {:ok, Map.put(entry, "evidence", evidence)}
        {:ok, _invalid} -> {:error, :invalid_criteria}
      end
    else
      {:error, :invalid_criteria}
    end
  end

  # ─── The land digest (ONE merge rule, shared) ─────────────────────────────
  #
  # UNION into any existing `content.landed` so a re-close, a CI backfill and a
  # non-holder landing mark ACCUMULATE rather than clobber. A nil/empty/
  # malformed payload leaves content untouched (never erases a prior digest).
  #
  # This lived as a `defp` on `Tasks.Close` until `Tasks.Landed` needed the SAME
  # rule (task-59fe7b40b719b379): two verbs write one key, so they must not grow
  # two subtly-different merges — the `merge_criteria` precedent, applied to the
  # digest.
  #
  # `commits` and `notes` joined the key list with that move. They are the two
  # halves of a landing SENTENCE ("this commit, and what it means") that only a
  # landing mark carries; before, a caller that passed either got a 2xx and no
  # persisted key. Widening a union can only persist MORE of what a caller
  # actually sent — no existing close passes them, so close's stored shape is
  # unchanged.
  @landed_keys ~w(prs files capability_slugs commits notes)

  def merge_landed(content, landed) when is_map(landed) and map_size(landed) > 0 do
    existing =
      case Map.get(content, "landed") do
        m when is_map(m) -> m
        _ -> %{}
      end

    merged =
      Enum.reduce(@landed_keys, existing, fn key, acc ->
        case normalize_landed_list(Map.get(landed, key) || Map.get(landed, safe_atom(key))) do
          [] -> acc
          incoming -> Map.put(acc, key, Enum.uniq((Map.get(acc, key) || []) ++ incoming))
        end
      end)

    if map_size(merged) == 0, do: content, else: Map.put(content, "landed", merged)
  end

  def merge_landed(content, _), do: content

  def normalize_landed_list(nil), do: []
  def normalize_landed_list(list) when is_list(list), do: Enum.reject(list, &is_nil/1)
  def normalize_landed_list(scalar), do: [scalar]

  def safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__missing__
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
