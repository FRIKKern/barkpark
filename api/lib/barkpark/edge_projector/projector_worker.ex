defmodule Barkpark.EdgeProjector.ProjectorWorker do
  @moduledoc """
  Oban worker that drives a debounced projection of one scope's content graph
  into the durable `content_edges` table.

  Mirrors `Barkpark.Plugins.Indx.IndexerWorker` (the three-op discriminator,
  the debounce + uniqueness, the test-seam module overrides) with ONE
  structural divergence: there is NO live dataset / blue-green swap and so NO
  `:no_live_dataset` branch — `content_edges` is a durable Postgres table.

  ## Queue + uniqueness

  Runs on the dedicated `:edge_projector` queue (concurrency 2) so it never
  competes with `:indx`. Unique on `(op, scope, _id, types)` across
  `:available` / `:scheduled` / `:executing` for 30s:

    * rebuild jobs carry NO `_id` → dedup on `(rebuild, scope, nil, types)`,
      i.e. a burst of saves to one scope collapses into a single rebuild PER
      TYPE SET. `types` MUST be in the key (lvw-t11-followup-dedup): the
      lifecycle enqueues per-save with `types: [doc.type]`, so without it a
      `types ["task"]` job swallowed a subsequent `types ["paper"]` enqueue in
      the same window — Oban returned the existing job, the new args were
      discarded, and the paper's edges were never projected (no retry). Keying
      per type is safe because `Projector.rebuild_scope/3` deletes only the
      listed corpus docs' OWN outbound edges, so per-type rebuilds never
      clobber each other. (Contrast `Indx.IndexerWorker`: its blue/green
      whole-dataset swap makes this fix NON-portable there — see task
      indx-rebuild-types-dedup.)
    * upsert/delete jobs carry an `_id` → dedup per `(op, scope, _id, types)`;
      a doc always enqueues with its own single type, so this stays per-doc
      dedup exactly as before.

  `types` is normalised (sorted + deduped) at enqueue so element ORDER cannot
  defeat the uniqueness key.

  ## Three ops

    * `"op" => "rebuild"` (default) — full per-scope rebuild: list the corpus
      (one `list_documents` per `"types"` entry at `perspective: :published`),
      hand it to `Projector.rebuild_scope/3`. Routed by `:after_save` /
      `:after_publish` when the `incremental_project` flag is OFF (the default).
    * `"op" => "upsert"` — per-doc incremental projection of one `"_id"`,
      diffing its outbound edges. Routed by `:after_save` / `:after_publish`
      ONLY when the flag is ON. INERT by default.
    * `"op" => "delete"` — per-doc removal of every edge touching one `"_id"`.
      Routed by `:after_unpublish` / `:after_delete` (always incremental).

  ## Job args (string-keyed, Oban-serialised)

      %{
        "op"          => "rebuild" | "upsert" | "delete",  # default "rebuild"
        "scope"       => "production",          # dataset string (required)
        "types"       => ["post", "page"],      # doc types (rebuild — corpus list)
        "perspective" => "published",           # default "published"
        "_id"         => "drafts.p1",           # upsert/delete op only (required)
        "workspace_id"=> "...",                 # optional tenancy scope
        "project_id"  => "...",                  # optional tenancy scope
        "projector"   => "...",                  # TEST-ONLY projector module override
        "content"     => "..."                   # TEST-ONLY content module override
      }

  The `"types"` arg is forwarded on EVERY op (not just rebuild) so the
  upsert/delete error fallbacks can re-list the corpus for a full rebuild —
  without it the rebuild fallback cancels `:no_types_for_rebuild` (the Indx
  `:no_types_for_reindex_fallback` precedent).

  ## Error classification

    * doc gone (upsert fetch returns `{:error, :not_found}`) → `{:cancel, :doc_gone}`.
    * a raise (DB blip, transaction timeout, poison doc) → `{:error, e}` — Oban
      applies its normal backoff and DISCARDS at `max_attempts` (fail-loud
      doctrine). NEVER `{:snooze, _}` here: Oban's `snooze_job` refunds the
      attempt (`inc: [max_attempts: 1]`), so a snoozing rescue turned every
      poison job into an IMMORTAL retry loop — `max_attempts: 5` was decorative.
    * the projector returns `{:error, _}` → `{:error, _}`, same backoff/discard.
  """

  use Oban.Worker,
    queue: :edge_projector,
    max_attempts: 5,
    unique: [
      keys: [:op, :scope, :_id, :types],
      states: [:available, :scheduled, :executing],
      period: 30
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.EdgeProjector.Projector
  alias Barkpark.Tenancy

  @debounce_seconds 5

  @doc """
  Build a debounced REBUILD job for `scope` (the default op). `opts` may carry
  `:types`, `:perspective`, `:workspace_id`, `:project_id`. Scheduled
  `@debounce_seconds` out so a save burst to one scope collapses.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(scope, opts \\ []) when is_binary(scope) do
    %{
      "op" => "rebuild",
      "scope" => scope,
      "types" => normalize_types(Keyword.get(opts, :types, [])),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Build a debounced UPSERT job projecting a single `id` into `scope`'s graph.
  Routed by `:after_save` / `:after_publish` ONLY when `incremental_project`
  is ON. Unique per `(scope, id, types)` — per-doc in practice, a doc always
  enqueues with its own single type.
  """
  @spec enqueue_upsert(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_upsert(scope, id, opts \\ []) when is_binary(scope) and is_binary(id) do
    %{
      "op" => "upsert",
      "scope" => scope,
      "_id" => id,
      "types" => normalize_types(Keyword.get(opts, :types, [])),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Build a debounced DELETE job removing every edge touching `id` in `scope`'s
  graph. Routed by `:after_unpublish` / `:after_delete`. Unique per
  `(scope, id, types)` — per-doc in practice, a doc always enqueues with its
  own single type.
  """
  @spec enqueue_delete(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_delete(scope, id, opts \\ []) when is_binary(scope) and is_binary(id) do
    %{
      "op" => "delete",
      "scope" => scope,
      "_id" => id,
      "types" => normalize_types(Keyword.get(opts, :types, [])),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
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

  defp run_rebuild_op(scope, args) do
    types = Map.get(args, "types", [])

    if not is_list(types) or types == [] do
      {:cancel, :no_types}
    else
      run_rebuild(scope, types, args)
    end
  end

  # Full per-scope rebuild: list the published corpus across the declared types
  # and hand it to Projector.rebuild_scope/3 (atomic DELETE+bulk-add in a
  # transaction). A DB blip surfaces as an exception → {:error, e} (real
  # backoff, discard at max_attempts — never snooze, see moduledoc).
  #
  # FAIL-CLOSED tenancy (Goal ges/graph-edge-seam, FIX 3): in a multi-tenant
  # install a rebuild enqueued with NO workspace_id (a nil-scope doc whose
  # workspace could not be resolved by Lifecycle.scope_opts/1) would list the
  # corpus ACROSS ALL tenants sharing the dataset string and materialise
  # cross-tenant edges. Skip it — a global-corpus rebuild is unsafe when tenants
  # coexist. With a workspace_id present we set `require_workspace: true` so each
  # endpoint resolution stays inside that workspace (a colliding slug in another
  # tenant can't be picked).
  defp run_rebuild(scope, types, args) do
    ws = Map.get(args, "workspace_id")

    if is_nil(ws) and Tenancy.multi_tenant?() do
      Logger.warning(
        "EdgeProjector.ProjectorWorker: rebuild for scope=#{scope} has NO workspace_id in a " <>
          "multi-tenant install — skipping (fail-closed, would build a cross-tenant corpus)"
      )

      {:cancel, :nil_workspace_multi_tenant}
    else
      run_rebuild_scoped(scope, types, args, ws)
    end
  end

  defp run_rebuild_scoped(scope, types, args, ws) do
    list_opts =
      [perspective: :published, page_size: page_size(args), max_pages: max_pages(args)]
      |> maybe_put(:workspace_id, ws)
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    project_opts =
      [dataset: scope]
      |> maybe_put(:workspace_id, ws)
      |> maybe_put(:project_id, Map.get(args, "project_id"))
      |> maybe_put(:require_workspace, require_workspace?(ws))

    # WALK THE WHOLE CORPUS, and say so when we could not. This used to be a
    # single `list_documents(limit: 1000)` per type — but `list_documents/3`
    # CLAMPS :limit to 1000 and returns a bare list, so a scope holding more
    # than 1000 published docs of a type was rebuilt from a 1000-row PREFIX.
    # `rebuild_scope/3` deletes outbound edges only for docs IN the corpus it
    # is handed, so every doc past the cap kept its pre-rebuild edges FOREVER
    # while the log below reported a clean rebuild. `rebuild_scope`'s own
    # transaction budget is sized for "the largest measured corpus (~4k docs)"
    # — 4x the cap — so the capped read was never the intended contract.
    {docs, truncated} =
      types
      |> Enum.map_reduce(nil, fn type, trunc_acc ->
        {page, trunc} = content_mod(args).collect_all_documents(type, scope, list_opts)
        {page, trunc_acc || trunc}
      end)
      |> then(fn {per_type, trunc} ->
        {per_type |> Enum.concat() |> hydrate_task_edges(), trunc}
      end)

    case projector_mod(args).rebuild_scope(scope, docs, project_opts) do
      {:ok, %{added: added, deleted: deleted}} ->
        # A bounded walk that stopped at its cap rebuilt a PREFIX. Never let
        # that pass as a clean rebuild — docs past the walk keep stale edges.
        if truncated == :cap do
          Logger.warning(
            "EdgeProjector.ProjectorWorker: scope=#{scope} corpus walk hit its page cap — " <>
              "the rebuild covered #{length(docs)} docs but the corpus is LARGER. Docs beyond " <>
              "the walk keep their pre-rebuild edges; this scope is INCOMPLETE."
          )
        end

        Logger.info(
          "EdgeProjector.ProjectorWorker: rebuilt scope=#{scope} " <>
            "docs=#{length(docs)} added=#{added} deleted=#{deleted} " <>
            "truncated=#{truncated == :cap}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "EdgeProjector.ProjectorWorker: rebuild failed for scope=#{scope}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "EdgeProjector.ProjectorWorker: rebuild raised for scope=#{scope}, erroring " <>
          "(attempt consumed): " <> Exception.message(e)
      )

      {:error, e}
  end

  # Per-doc incremental upsert. Fetches the SINGLE doc by _id (+ type) — never
  # re-lists the corpus — and hands it to Projector.upsert_record/2. A doc that
  # no longer exists → {:cancel, :doc_gone}.
  defp run_upsert(scope, args) do
    id = Map.get(args, "_id")
    type = args |> Map.get("types", []) |> first_type()

    cond do
      not is_binary(id) or id == "" ->
        {:cancel, :missing_id}

      is_nil(type) ->
        {:cancel, :no_type_for_upsert}

      true ->
        case content_mod(args).get_document(id, type, scope) do
          {:ok, doc} ->
            do_upsert(scope, id, hydrate_task_edges(doc), args)

          {:error, :not_found} ->
            Logger.info(
              "EdgeProjector.ProjectorWorker: upsert _id=#{id} type=#{type} scope=#{scope} — " <>
                "doc gone, cancelling"
            )

            {:cancel, :doc_gone}
        end
    end
  rescue
    e ->
      Logger.error(
        "EdgeProjector.ProjectorWorker: upsert raised for scope=#{scope}, erroring " <>
          "(attempt consumed): " <> Exception.message(e)
      )

      {:error, e}
  end

  defp do_upsert(scope, id, doc, args) do
    # FAIL-CLOSED tenancy (FIX 3): prefer the enqueue's workspace_id, else the
    # fetched doc's OWN workspace_id (the upsert path has the real doc in hand,
    # so it can recover the scope the rebuild path cannot). When a multi-tenant
    # install still resolves NO workspace, set `require_workspace: true` so the
    # endpoint resolutions fail closed rather than crossing tenants.
    ws = Map.get(args, "workspace_id") || doc_workspace_id(doc)

    project_opts =
      [dataset: scope]
      |> maybe_put(:workspace_id, ws)
      |> maybe_put(:project_id, Map.get(args, "project_id"))
      |> maybe_put(:require_workspace, require_workspace?(ws))

    case projector_mod(args).upsert_record(doc, project_opts) do
      {:ok, %{added: added, removed: removed}} ->
        Logger.info(
          "EdgeProjector.ProjectorWorker: upserted _id=#{id} into scope=#{scope} " <>
            "added=#{added} removed=#{removed}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "EdgeProjector.ProjectorWorker: upsert of _id=#{id} failed for scope=#{scope}: " <>
            "#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Per-doc delete: remove every edge touching the doc PK. The doc is fetched
  # only to resolve its PK; if it is already gone the projector resolves no PK
  # and deletes nothing (the publish-coalesced PK may still resolve via the
  # draft twin, which is why we pass the bare _id through).
  defp run_delete(scope, args) do
    id = Map.get(args, "_id")

    if not is_binary(id) or id == "" do
      {:cancel, :missing_id}
    else
      ws = Map.get(args, "workspace_id")

      # FAIL-CLOSED tenancy (FIX 3): the delete path resolves the doc's PK via
      # Projector.doc_pk/2 before removing its edges. Forward the same
      # `require_workspace` decision the rebuild/upsert paths use so a
      # nil-workspace delete in a multi-tenant install resolves to NOTHING
      # (Scope.scope_to_workspace/3 fail-closed) rather than resolving — and
      # deleting the edges of — a colliding-slug doc in another tenant.
      project_opts =
        [dataset: scope]
        |> maybe_put(:workspace_id, ws)
        |> maybe_put(:project_id, Map.get(args, "project_id"))
        |> maybe_put(:require_workspace, require_workspace?(ws))

      case projector_mod(args).delete_record(%{"doc_id" => id, "dataset" => scope}, project_opts) do
        {:ok, count} ->
          Logger.info(
            "EdgeProjector.ProjectorWorker: deleted #{count} edge(s) for _id=#{id} scope=#{scope}"
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "EdgeProjector.ProjectorWorker: delete of _id=#{id} failed for scope=#{scope}: " <>
              "#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.error(
        "EdgeProjector.ProjectorWorker: delete raised for scope=#{scope}, erroring " <>
          "(attempt consumed): " <> Exception.message(e)
      )

      {:error, e}
  end

  defp first_type([t | _]) when is_binary(t) and t != "", do: t
  defp first_type(_), do: nil

  # `types` participates in the Oban uniqueness key, so its serialised form
  # must be canonical: sort + dedup at enqueue, or ["a","b"] vs ["b","a"]
  # would defeat the dedup. Non-list input passes through untouched — the
  # perform-side guards (`run_rebuild_op`, `first_type`) already own that
  # rejection.
  defp normalize_types(types) when is_list(types), do: types |> Enum.uniq() |> Enum.sort()
  defp normalize_types(types), do: types

  # Hydrate task docs' payloads with their authoritative `task_edges` rows
  # BEFORE the pure projection runs (gap #1 fix — `content.dependencies` is a
  # DEAD KEY; `task_edges` is the only authoritative dependency store). This is
  # the DB-touching layer, so reading `task_edges` here keeps the plugin
  # `extract_edges/2` callback pure. The rebuild path hands the WHOLE corpus to
  # the batched `Tasks.hydrate_edges_batch/1` — ONE task_edges query over every
  # task PK plus ONE Document id map, instead of one query per doc + one
  # `Repo.get` per edge row. Non-task docs pass through unchanged. The upsert
  # path still hydrates its single doc via `Tasks.hydrate_edges/1`. The Tasks
  # plugin is first-party + always compiled; the fallback clause only protects
  # a doc payload that is not a map (never crashes the projection).
  defp hydrate_task_edges(docs) when is_list(docs) do
    Barkpark.Plugins.Tasks.hydrate_edges_batch(docs)
  end

  defp hydrate_task_edges(doc) when is_map(doc) do
    Barkpark.Plugins.Tasks.hydrate_edges(doc)
  end

  defp hydrate_task_edges(doc), do: doc

  # The projector module is `Projector` in production. Tests pass a
  # `"projector"` arg naming a fake module so the worker's op branching can be
  # exercised without the DB. Never set by the lifecycle enqueue paths.
  defp projector_mod(args) do
    case Map.get(args, "projector") do
      mod when is_binary(mod) -> String.to_existing_atom("Elixir." <> mod)
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Projector
    end
  end

  # Test-only override of the corpus WALK page size (mirrors `content_mod/1`
  # and `Indx.IndexerWorker`'s `list_limit/1`). Prod never sets it, so the walk
  # pages at the server's own 1000-row cap. Tests set a small page size to
  # exercise the multi-page walk — and its truncation arm — without seeding a
  # thousand documents.
  defp page_size(args) do
    case Map.get(args, "page_size") do
      n when is_integer(n) and n > 0 -> n
      _ -> 1000
    end
  end

  # Test-only override of the walk's page bound, so the `:cap` arm (the walk
  # stopped before the corpus ran out) is reachable without a million rows.
  # The default 50 pages = 50,000 docs: twelve times the largest corpus
  # `Projector.rebuild_scope/3`'s docs measure (~4k), fifty times the cap this
  # replaces, and still inside the 60s rebuild transaction budget. Past that a
  # `:cap` warning beats an opaque transaction timeout.
  defp max_pages(args) do
    case Map.get(args, "max_pages") do
      n when is_integer(n) and n > 0 -> n
      _ -> 50
    end
  end

  # The content module is `Content` in production. The corpus listing + the
  # upsert single-doc fetch resolve through this seam so the worker can be
  # exercised against a fake module. Never set by the lifecycle enqueue paths.
  defp content_mod(args) do
    case Map.get(args, "content") do
      mod when is_binary(mod) -> String.to_existing_atom("Elixir." <> mod)
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Content
    end
  end

  # FAIL-CLOSED decision (FIX 3). Returns `true` ONLY when the install is
  # multi-tenant AND no workspace could be resolved — the exact case where a
  # nil-workspace endpoint resolution would otherwise cross tenants. With a
  # workspace in hand the within-workspace scope already isolates the read, so
  # the strict flag is unnecessary (and `false` keeps the or-global back-compat
  # untouched on single-tenant installs).
  defp require_workspace?(nil), do: Tenancy.multi_tenant?()
  defp require_workspace?(ws) when is_binary(ws), do: false

  # The fetched doc's own workspace_id (struct atom key OR map string key), used
  # by the upsert path to recover the scope when the enqueue args omitted it.
  defp doc_workspace_id(%{workspace_id: ws}) when is_binary(ws), do: ws
  defp doc_workspace_id(%{"workspace_id" => ws}) when is_binary(ws), do: ws
  defp doc_workspace_id(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
