defmodule Barkpark.Plugins.Indx.IndexerWorker do
  @moduledoc """
  Oban worker that drives a debounced BLUE/GREEN rebuild of one scope's
  search corpus into the dedicated Indx instance.

  ## Queue + uniqueness

  Runs on the `:indx` queue. Unique on the `index_key` partition key over a
  debounce window (`@debounce_seconds`) across `:available` / `:scheduled`
  / `:executing` — so a burst of saves to the same TENANT's scope collapses
  into a single rebuild instead of one rebuild per document, while a
  co-tenant's rebuild of the same dataset string stays its own job. This is
  the whole reason the lifecycle hooks enqueue a SCOPE rebuild rather than
  touching the index per-document (and it dovetails with the spike's
  serialise-loads rule).

  ## Three ops

  The job carries an `"op"` discriminator:

    * `"op" => "rebuild"` (default) — today's BLUE/GREEN full rebuild of
      the whole scope corpus. Routed by `:after_save` / `:after_publish`
      when the `incremental_upsert` flag is OFF (the default).
    * `"op" => "upsert"` — INCREMENTAL per-document insert/update of a
      single `"_id"` into the CURRENT live dataset, no rebuild. Routed by
      `:after_save` / `:after_publish` ONLY when the `incremental_upsert`
      flag is ON. INERT by default.
    * `"op" => "delete"` — INCREMENTAL per-document delete of a single
      `"_id"` from the CURRENT live dataset, no rebuild. Routed by
      `:after_delete` / `:after_unpublish` (always incremental).

  ## perform/1 — rebuild op

    1. List the scope's WHOLE corpus via `Barkpark.Content.list_documents/3`
       for every PUBLIC schema type (`indexed_types/2`, NOT the enqueued
       `"types"` slice) at the requested `perspective`. The rebuild is
       types-blind on purpose — the blue/green swap replaces the entire live
       dataset, so it must carry every public type or the swap erases the rest.
    2. Hand the corpus to `Indexer.rebuild/3` (blue/green: loads into a
       fresh `<prefix>_<index_key>_v<n>`, NEVER re-loads a live dataset).
    3. On success, `Indexer.swap/2` flips the live pointer, then
       `Indexer.delete_dataset/2` drops the old dataset.

  ## perform/1 — upsert op

    1. Fetch the SINGLE document by `"_id"` (+ its `"type"`) from Barkpark
       via `Content.get_document/3` — NEVER re-list the whole corpus.
    2. Hand it to `Indexer.upsert_record/3` (insert when the `_id` is new
       to the live index, update when it already holds a record).
    3. `:ok` → done. `{:reindex_required, _}` → fall back to a FULL
       rebuild (same `run_rebuild/4` the rebuild op runs). `{:error, _}` →
       classified by `classify_upsert_error/1`, which DIVERGES from the
       delete classification on ONE case: no-live-dataset → FULL REBUILD
       (the post-restart self-heal — boot-recovery hadn't seated the pointer
       yet, so the first edit rebuilds the scope, then subsequent edits go
       incremental). All other cases mirror the delete op (404 → cancel;
       NetworkError → snooze; else backoff). A document that no longer
       exists in Barkpark → `{:cancel, :doc_gone}`.

  ## perform/1 — delete op

    1. `Indexer.delete_record/3` resolves the stored key for `"_id"` and
       DELETEs it from the live dataset.
    2. `:ok` → done. `{:reindex_required, _}` → fall back to a FULL
       rebuild (enqueue + await a rebuild-op job for the same scope) so
       the change becomes query-visible. `{:error, _}` → classified by
       `classify_delete_error/1`:
         * no live dataset → `{:cancel, :no_live_dataset}` (PERMANENT —
           nothing to delete from; a future rebuild lands the index minus
           the deleted doc),
         * 404 from the delete endpoint → `{:cancel, :delete_endpoint_unavailable}`
           (PERMANENT — the C# `DeleteJsonRecord` action is not deployed;
           retrying a missing endpoint is pointless, the [error] log makes
           the misconfig obvious),
         * `NetworkError` (Indx unreachable) → `{:snooze, N}` (TRANSIENT),
         * other non-2xx (5xx) → `{:error, _}` (Oban backoff).

  ## Job args (string-keyed, Oban-serialised)

      %{
        "op"          => "rebuild" | "upsert" | "delete",  # default "rebuild"
        "scope"       => "production",          # dataset string (required)
        "types"       => ["post"],              # the mutated doc's type; used by
                                                # upsert (single-doc fetch). IGNORED
                                                # by the rebuild op, which derives the
                                                # whole public-schema corpus itself.
        "perspective" => "published",           # default "published"
        "_id"         => "drafts.p1",           # upsert/delete op only (required)
        "workspace_id"=> "...",                 # optional tenancy scope
        "project_id"  => "...",                  # optional tenancy scope
        "index_key"   => "production_t4f1…",     # ALWAYS present; the index this
                                                # job acts on (Indexer.index_key/2
                                                # over scope + the two ids above).
                                                # It is the uniqueness partition —
                                                # see the `unique:` note below.
        "indexer"     => "...",                  # TEST-ONLY indexer module override
        "content"     => "..."                   # TEST-ONLY content module override
      }

  `"scope"` and `"index_key"` are NOT interchangeable: `"scope"` addresses the
  Barkpark CORPUS (what `Content.list_documents/3` reads, narrowed by the
  tenancy args), `"index_key"` addresses the SEARCH INDEX that corpus is loaded
  into and swapped onto. They differ per tenant, which is the point.

  The `"indexer"` arg is a test seam (a module name string) — never set by
  the lifecycle enqueue paths, so production always uses the real
  `Indexer`.

  ## Indx-down tolerance

  A `NetworkError` from the client (Indx unreachable) → `{:snooze, N}` so
  the work retries later without burning an Oban attempt. PERMANENT delete
  failures (no live dataset, or a 404 from the not-yet-deployed delete
  endpoint) → `{:cancel, reason}` — retrying them never succeeds. Other
  Indx errors (`IndexError` 5xx / `SearchError` / `AuthError`) →
  `{:error, reason}` so Oban applies its normal backoff. A missing/empty
  `types` list → `{:cancel, reason}` (nothing to index, not a transient
  failure).
  """

  # Uniqueness keyed on `(op, index_key, _id)` — deliberately NO `:types`:
  #   * rebuild jobs carry NO `_id` → they dedup on `(rebuild, index_key, nil)`,
  #     i.e. unique per INDEX. This is CORRECT because a rebuild is
  #     types-BLIND: `run_rebuild_op/2` ignores the enqueued `"types"` and
  #     rebuilds the WHOLE public-schema corpus for the scope (see below), so
  #     collapsing a mixed-type save burst into one job loses nothing — the
  #     single surviving job re-indexes every public type anyway.
  #   * upsert/delete jobs carry an `_id` → they dedup on
  #     `(upsert|delete, index_key, _id)` — many distinct upserts/deletes in a
  #     burst all enqueue, repeated ones of the SAME doc collapse.
  #
  # `:index_key`, NOT `:scope`. The key must be the INDEX's identity, and the
  # index is per-TENANT: every workspace is born owning a dataset called
  # `production`, so keying on the dataset string collapsed workspace B's
  # rebuild into workspace A's in-flight job — B's rebuild simply never ran,
  # and the surviving job then listed A's corpus and swapped it into the slot B
  # reads from. `Indexer.index_key/2` folds `:workspace_id` + `:project_id`
  # into one always-present scalar arg (see `job_index_key/1`).
  #
  # It must be a DEDICATED arg, not the two tenancy args already in the map.
  # Oban's `keys:` filter is `args @> <taken subset>` (Oban.Engines.Basic
  # `unique_field/2`), i.e. CONTAINMENT — and `drop_nil/1` omits a nil
  # `workspace_id` entirely. So a workspace-LESS job, whose subset is just
  # `{op, scope}`, is contained by EVERY tenant's job and would still be
  # deduped away by whichever tenant happened to be in flight. An always-present
  # `index_key` has no such third state: nil tenancy hashes to its own key.
  #
  # Do NOT add `:types` to the key. The sibling `EdgeProjector.ProjectorWorker`
  # DOES key on `:types` (lvw-t11-followup-dedup) because its projection deletes
  # only the listed docs' OWN outbound edges, so per-type rebuilds are additive
  # and must each run. That fix is NON-PORTABLE here: Indx's rebuild does a
  # blue/green WHOLE-DATASET swap built from ONLY the enqueued types' docs
  # (`rebuild → swap → delete old`), so a per-type rebuild ERASES every other
  # type from live search. Two per-type keyed jobs would each swap a one-type
  # dataset — last swap wins, the rest vanish. The fix for THIS worker is the
  # opposite lever: make the rebuild whole-corpus (types-blind) and keep the key
  # types-blind too. (task indx-rebuild-types-dedup.) The WORKSPACE dimension is
  # the mirror case: that same "last swap wins" argument holds verbatim across
  # tenants, which is why the workspace belongs IN the key while types stay out.
  use Oban.Worker,
    queue: :indx,
    max_attempts: 5,
    unique: [
      keys: [:op, :index_key, :_id],
      states: [:available, :scheduled, :executing],
      period: 30
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.Errors.{IndexError, NetworkError}
  alias Barkpark.Plugins.Indx.Indexer

  @debounce_seconds 5
  @snooze_seconds 60

  @doc """
  Build a debounced REBUILD job for `scope` (the default op). The
  lifecycle hooks call this with a fast (<100ms) hand-off — it only
  constructs and inserts the job.

  Schedules the job `@debounce_seconds` in the future so a burst of saves
  to the same scope collapses (combined with the `unique` clause). `opts`
  may carry `:types`, `:perspective`, `:workspace_id`, `:project_id`.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(scope, opts \\ []) when is_binary(scope) do
    %{
      "op" => "rebuild",
      "scope" => scope,
      "types" => Keyword.get(opts, :types, []),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> put_index_key(scope, opts)
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Build a debounced DELETE job removing a single `id` from `scope`'s live
  dataset. Routed by `:after_delete` / `:after_unpublish`. Unique per
  `(scope, id)` so repeated deletes of the same doc collapse while
  distinct deletes in a burst all enqueue. `opts` may carry `:types`,
  `:workspace_id`, `:project_id` (forwarded to the reindex-fallback
  rebuild).
  """
  @spec enqueue_delete(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_delete(scope, id, opts \\ []) when is_binary(scope) and is_binary(id) do
    %{
      "op" => "delete",
      "scope" => scope,
      "_id" => id,
      "types" => Keyword.get(opts, :types, []),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> put_index_key(scope, opts)
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Build a debounced UPSERT job inserting/updating a single `id` into
  `scope`'s live dataset. Routed by `:after_save` / `:after_publish` ONLY
  when the `incremental_upsert` flag is ON (default OFF — see
  `Lifecycle.enqueue_rebuild/1`). Unique per `(scope, id)` so repeated
  saves of the same doc collapse while distinct saves in a burst all
  enqueue. `opts` may carry `:types`, `:workspace_id`, `:project_id`
  (forwarded to the reindex-fallback rebuild and the single-doc fetch).
  """
  @spec enqueue_upsert(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_upsert(scope, id, opts \\ []) when is_binary(scope) and is_binary(id) do
    %{
      "op" => "upsert",
      "scope" => scope,
      "_id" => id,
      "types" => Keyword.get(opts, :types, []),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> put_index_key(scope, opts)
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  # Stamp the tenant-partitioned index identity onto the job args. Applied
  # AFTER `drop_nil/1` on purpose: this key must be present on EVERY job, nil
  # tenancy included, or Oban's containment-based uniqueness lets a
  # workspace-less job be swallowed by a co-tenant's (see the `unique:` note
  # at the top of the module).
  defp put_index_key(args, scope, opts) do
    Map.put(
      args,
      "index_key",
      Indexer.index_key(scope,
        workspace_id: Keyword.get(opts, :workspace_id),
        project_id: Keyword.get(opts, :project_id)
      )
    )
  end

  # The index identity this job acts on. Jobs enqueued by the three helpers
  # above always carry it; the fallback re-derives it from the tenancy args so
  # a job enqueued by a PREVIOUS release (and any `perform_job/2` fixture that
  # hand-writes args) resolves to exactly the key its enqueue would have
  # produced, rather than to the tenant-blind dataset string.
  defp job_index_key(args) do
    case Map.get(args, "index_key") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        Indexer.index_key(Map.get(args, "scope", ""),
          workspace_id: Map.get(args, "workspace_id"),
          project_id: Map.get(args, "project_id")
        )
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    scope = Map.get(args, "scope")
    op = Map.get(args, "op", "rebuild")

    cond do
      not is_binary(scope) or scope == "" ->
        {:cancel, :missing_scope}

      op == "delete" ->
        run_delete(scope, args)

      op == "upsert" ->
        run_upsert(scope, args)

      true ->
        run_rebuild_op(scope, args)
    end
  end

  # A rebuild is types-BLIND: it rebuilds the WHOLE public-schema corpus for
  # the scope, NOT the single `"types"` slice the lifecycle enqueued. This is
  # what makes the blue/green swap safe — the new dataset the swap points at
  # holds every public type, so nothing is erased. Sourcing the corpus from the
  # enqueued type (the pre-fix behaviour) meant a `types ["post"]` job rebuilt a
  # post-only dataset and the swap dropped every other type from live search;
  # worse, a mixed-type burst dedups (per `(rebuild, scope, nil)`) to whichever
  # single-type job won, so search silently collapsed to one type after a save.
  # Deriving from the registered schemas (not a hardcoded list) also closes the
  # SearchController `@reindex_types` drift TODO.
  defp run_rebuild_op(scope, args) do
    types = indexed_types(scope, args)
    perspective = perspective_atom(Map.get(args, "perspective", "published"))

    if types == [] do
      # No public schemas resolved → refuse to rebuild-to-empty (an empty
      # rebuild would swap in an empty dataset and wipe live search). Cancel
      # instead; a later save re-enqueues once schemas exist.
      {:cancel, :no_indexed_types}
    else
      run_rebuild(scope, types, perspective, args)
    end
  end

  # Per-document incremental delete. Reindex-required → fall back to a full
  # rebuild for the scope (await it inline so this job's success reflects a
  # query-visible result). PERMANENT failures (no live dataset, missing
  # delete endpoint) → {:cancel, _} — retrying them is pointless. TRANSIENT
  # failures (Indx unreachable) → {:snooze, _}; other non-2xx → {:error, _}
  # so Oban applies normal backoff. See classify_delete_error/1.
  defp run_delete(scope, args) do
    id = Map.get(args, "_id")

    if not is_binary(id) or id == "" do
      {:cancel, :missing_id}
    else
      case indexer_mod(args).delete_record(job_index_key(args), id) do
        :ok ->
          Logger.info("Indx.IndexerWorker: deleted _id=#{id} from scope=#{scope}")
          :ok

        {:reindex_required, _status} ->
          Logger.info(
            "Indx.IndexerWorker: delete of _id=#{id} on scope=#{scope} requires reindex — " <>
              "falling back to full rebuild"
          )

          rebuild_fallback(scope, args)

        {:error, err} ->
          handle_delete_error(classify_delete_error(err), err, scope, id)
      end
    end
  end

  # Per-document incremental upsert. Fetches the SINGLE doc by _id (+ type)
  # from Barkpark — NEVER re-lists the whole corpus — and hands it to
  # Indexer.upsert_record/3. Reindex-required → fall back to a full rebuild
  # (await it inline). A doc that no longer exists in Barkpark →
  # {:cancel, :doc_gone}. Client errors reuse the delete-path classification.
  defp run_upsert(scope, args) do
    id = Map.get(args, "_id")
    type = args |> Map.get("types", []) |> first_type()

    cond do
      not is_binary(id) or id == "" ->
        {:cancel, :missing_id}

      is_nil(type) ->
        {:cancel, :no_type_for_upsert}

      # Schema-visibility gate (search-template W10 / D62) — the incremental
      # twin of the rebuild path's public-only corpus (`indexed_types/2`
      # below). Without it, a private-type save with `incremental_upsert` ON
      # re-contaminates the live index the rebuild deliberately kept clean
      # ("never index a type a public reader can't fetch"). Same derivation,
      # same predicate, same seam — one invariant, two enforcement points.
      type not in indexed_types(scope, args) ->
        Logger.info(
          "Indx.IndexerWorker: refusing upsert of _id=#{id} type=#{type} scope=#{scope} — " <>
            "type is not a public schema type (never index a type a public reader can't fetch)"
        )

        {:cancel, :non_public_type}

      true ->
        case content_mod(args).get_document(id, type, scope) do
          {:ok, doc} ->
            upsert_doc(scope, id, doc, args)

          {:error, :not_found} ->
            Logger.info(
              "Indx.IndexerWorker: upsert _id=#{id} type=#{type} scope=#{scope} — doc gone, cancelling"
            )

            {:cancel, :doc_gone}
        end
    end
  end

  defp upsert_doc(scope, id, doc, args) do
    case indexer_mod(args).upsert_record(job_index_key(args), doc) do
      :ok ->
        Logger.info("Indx.IndexerWorker: upserted _id=#{id} into scope=#{scope}")
        :ok

      {:reindex_required, _status} ->
        Logger.info(
          "Indx.IndexerWorker: upsert of _id=#{id} on scope=#{scope} requires reindex — " <>
            "falling back to full rebuild"
        )

        rebuild_fallback(scope, args)

      {:error, err} ->
        handle_upsert_error(classify_upsert_error(err), err, scope, id, args)
    end
  end

  # Upsert error classification DIVERGES from delete on exactly one case:
  # no-live-dataset. For a DELETE, no live dataset is a genuine no-op (cancel
  # — nothing to delete from). For an UPSERT it is the post-restart hole this
  # whole feature closes: boot-recovery hadn't seated the pointer (Indx was
  # down at boot, or this is the first edit before recovery ran), so the
  # FIRST edit after a restart must REBUILD the scope — which establishes the
  # pointer + key_map + seeds the corpus — then subsequent edits go
  # incremental. Every other case reuses the delete classification.
  defp classify_upsert_error(%IndexError{message: msg} = err) when is_binary(msg) do
    if String.contains?(msg, "no live dataset") do
      :rebuild
    else
      classify_delete_error(err)
    end
  end

  defp classify_upsert_error(err), do: classify_delete_error(err)

  # :rebuild → the ultimate self-heal: full blue/green rebuild of the scope
  # (the SAME rebuild-fallback the {:reindex_required, _} path uses), which
  # establishes the pointer + key_map + seeds the corpus. All other outcomes
  # mirror the delete-error handling (cancel / snooze / backoff).
  defp handle_upsert_error(:rebuild, _err, scope, id, args) do
    Logger.info(
      "Indx.IndexerWorker: upsert of _id=#{id} on scope=#{scope} found no live dataset — " <>
        "falling back to full rebuild (post-restart self-heal)"
    )

    rebuild_fallback(scope, args)
  end

  defp handle_upsert_error(outcome, err, scope, id, _args) do
    handle_delete_error(outcome, err, scope, id)
  end

  defp first_type([t | _]) when is_binary(t) and t != "", do: t
  defp first_type(_), do: nil

  # Map a classified delete failure to the right Oban outcome + log level.
  #   * {:cancel, reason}  — PERMANENT: nothing to retry. [error] log so the
  #     misconfig (missing endpoint) or expected no-op (no live dataset) is
  #     visible; no rebuild is enqueued.
  #   * :snooze            — TRANSIENT: Indx unreachable; retry later off the
  #     attempt budget.
  #   * :backoff           — other non-2xx (5xx): let Oban back off.
  defp handle_delete_error({:cancel, reason}, err, scope, id) do
    Logger.error(
      "Indx.IndexerWorker: delete of _id=#{id} on scope=#{scope} cancelled (#{reason}): " <>
        "#{inspect(err)}"
    )

    {:cancel, reason}
  end

  defp handle_delete_error(:snooze, err, scope, _id) do
    Logger.warning(
      "Indx.IndexerWorker: Indx unreachable on delete scope=#{scope}, snoozing: #{inspect(err)}"
    )

    {:snooze, @snooze_seconds}
  end

  defp handle_delete_error(:backoff, err, scope, id) do
    Logger.error(
      "Indx.IndexerWorker: delete of _id=#{id} failed for scope=#{scope}: #{inspect(err)}"
    )

    {:error, err}
  end

  # Classify a delete-path client error into permanent / transient / backoff.
  #
  #   * No live dataset (the IndexError raised by delete_record/3 when the
  #     scope has no live pointer) → PERMANENT cancel :no_live_dataset.
  #     Nothing to delete from; a future rebuild establishes the index
  #     already minus the now-deleted doc.
  #   * 404 from the delete endpoint (the C# DeleteJsonRecord action not
  #     deployed yet) → PERMANENT cancel :delete_endpoint_unavailable.
  #     Retrying a missing endpoint never succeeds.
  #   * NetworkError (Indx unreachable) → TRANSIENT snooze.
  #   * anything else (5xx, etc.) → backoff via Oban.
  defp classify_delete_error(%NetworkError{}), do: :snooze

  defp classify_delete_error(%IndexError{status: 404}),
    do: {:cancel, :delete_endpoint_unavailable}

  defp classify_delete_error(%IndexError{message: msg}) when is_binary(msg) do
    if String.contains?(msg, "no live dataset") do
      {:cancel, :no_live_dataset}
    else
      :backoff
    end
  end

  defp classify_delete_error(_other), do: :backoff

  # Reindex-required fallback: run the SAME blue/green rebuild the rebuild
  # op runs, inline, for the affected scope. Needs the doc types — the
  # delete job carries them so the corpus listing is correct. With no types
  # we cancel (nothing to rebuild) rather than fail the job forever.
  defp rebuild_fallback(scope, args) do
    types = indexed_types(scope, args)
    perspective = perspective_atom(Map.get(args, "perspective", "published"))

    if types == [] do
      {:cancel, :no_types_for_reindex_fallback}
    else
      run_rebuild(scope, types, perspective, args)
    end
  end

  # The full set of PUBLIC document types to index for `scope`, derived from the
  # registered schemas (via the `content` seam so tests can inject fakes). A
  # blue/green rebuild MUST cover the whole corpus — see `run_rebuild_op/2` and
  # the uniqueness note at the top of the module. `visibility: "private"`
  # schemas 404 on the public API, so they are excluded here too (never index a
  # type a public reader can't fetch — no new search-leak surface). The enqueued
  # `"types"` arg is intentionally NOT consulted: it names the single mutated
  # type, which is the wrong scope for a whole-dataset swap.
  defp indexed_types(scope, args) do
    list_opts =
      []
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    scope
    |> content_mod(args).list_schemas(list_opts)
    |> Enum.filter(&schema_public?/1)
    |> Enum.map(&schema_name/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  rescue
    # Schema listing must never crash a rebuild into a poison-retry. On any
    # failure fall back to the enqueued single type (a partial rebuild is
    # better than an Oban backoff storm, and the next save re-covers the rest).
    _ ->
      case Map.get(args, "types", []) do
        list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
        _ -> []
      end
  end

  # A schema is public ONLY when it EXPLICITLY declares `visibility: "public"`
  # — ALLOWLIST, not denylist (search-template W10 / D62): unified with the
  # query route's `Content.schema_public?/3` and the search read path's
  # anonymous allowlist (`DocumentsRetriever`), so a nil/unknown/future
  # visibility value fails CLOSED everywhere instead of indexing here while
  # 404ing there. Real `%SchemaDefinition{}` rows default `"public"`, so only
  # explicitly-non-public (or legacy nil-visibility) rows change. Handles both
  # the struct (atom key) and a plain map (string key) so the `content` test
  # seam can return either shape.
  defp schema_public?(%{visibility: v}), do: v == "public"
  defp schema_public?(%{"visibility" => v}), do: v == "public"
  defp schema_public?(_), do: false

  defp schema_name(%{name: n}), do: n
  defp schema_name(%{"name" => n}), do: n
  defp schema_name(_), do: nil

  # Per-type published-doc cap for a rebuild listing. A type with MORE than
  # this many published docs is silently truncated out of the index — so we
  # WARN (naming the type) when a listing comes back exactly at the cap.
  @rebuild_list_limit 1000

  # Two identities, deliberately not one: the corpus is LISTED by the Barkpark
  # `scope` (dataset string) narrowed by the tenancy opts, while the INDEX it is
  # loaded into and swapped onto is addressed by `job_index_key/1`. Passing
  # `scope` where the index key belongs is the cross-tenant clobber this whole
  # change exists to close — `Indexer`'s `is_index_key/1` guard makes that
  # mistake raise rather than silently merge two tenants' corpora.
  defp run_rebuild(scope, types, perspective, args) do
    limit = list_limit(args)
    index_key = job_index_key(args)

    list_opts =
      [perspective: perspective, limit: limit]
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    indexer = indexer_mod(args)
    content = content_mod(args)

    docs =
      Enum.flat_map(types, fn type ->
        listed = content.list_documents(type, scope, list_opts)
        warn_if_truncated(scope, type, listed, limit)
        listed
      end)

    case indexer.rebuild(index_key, docs) do
      {:ok, result} ->
        old = indexer.swap(index_key, result)
        indexer.delete_dataset(old, [])

        Logger.info(
          "Indx.IndexerWorker: rebuilt scope=#{scope} index=#{index_key} " <>
            "dataset=#{result.new_dataset} count=#{result.count} (dropped #{inspect(old)})"
        )

        :ok

      {:error, %NetworkError{} = err} ->
        Logger.warning(
          "Indx.IndexerWorker: Indx unreachable for scope=#{scope}, snoozing: #{inspect(err)}"
        )

        {:snooze, @snooze_seconds}

      {:error, err} ->
        Logger.error("Indx.IndexerWorker: rebuild failed for scope=#{scope}: #{inspect(err)}")
        {:error, err}
    end
  end

  # Test-only override of the per-type list cap (mirrors `indexer_mod/1`).
  # Prod never sets this arg, so the real @rebuild_list_limit is always used;
  # tests set a small cap to exercise the truncation-warning branch without
  # seeding a thousand documents.
  defp list_limit(args) do
    case Map.get(args, "list_limit") do
      n when is_integer(n) and n > 0 -> n
      _ -> @rebuild_list_limit
    end
  end

  # A listing that comes back at exactly the cap almost certainly means the
  # type has MORE published docs than we fetched, so the overflow is silently
  # dropped from the index on every rebuild. Full pagination is deferred (the
  # AnalyzeString timeout tradeoff makes a much larger corpus riskier this
  # round) — so at minimum WARN, naming the type, so the truncation is visible.
  defp warn_if_truncated(scope, type, listed, limit) when length(listed) >= limit do
    Logger.warning(
      "Indx.IndexerWorker: type=#{type} scope=#{scope} hit the #{limit}-doc " <>
        "rebuild list cap — published docs beyond the cap are TRUNCATED out of the index. " <>
        "Pagination is not yet implemented; the index is incomplete for this type."
    )
  end

  defp warn_if_truncated(_scope, _type, _listed, _limit), do: :ok

  # The indexer module is `Indexer` in production. Tests pass an
  # `"indexer"` arg naming a fake module so the worker's op branching +
  # reindex fallback can be exercised without a live Indx engine. The arg
  # is never set by the lifecycle enqueue paths, so prod always uses the
  # real Indexer.
  defp indexer_mod(args) do
    case Map.get(args, "indexer") do
      mod when is_binary(mod) -> String.to_existing_atom("Elixir." <> mod)
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Indexer
    end
  end

  # The content module is `Content` in production. The upsert op's
  # single-doc fetch resolves through this seam so the worker's upsert
  # branch can be exercised against a fake module without a DB. Never set
  # by the lifecycle enqueue paths, so prod always uses the real Content.
  defp content_mod(args) do
    case Map.get(args, "content") do
      mod when is_binary(mod) -> String.to_existing_atom("Elixir." <> mod)
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Content
    end
  end

  defp perspective_atom("drafts"), do: :drafts
  defp perspective_atom("raw"), do: :raw
  defp perspective_atom("published"), do: :published
  defp perspective_atom(other) when is_atom(other), do: other
  defp perspective_atom(_), do: :published

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
