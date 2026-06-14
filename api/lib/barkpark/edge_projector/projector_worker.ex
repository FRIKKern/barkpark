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
  competes with `:indx`. Unique on `(op, scope, _id)` across
  `:available` / `:scheduled` / `:executing` for 30s:

    * rebuild jobs carry NO `_id` → dedup on `(rebuild, scope, nil)`, i.e. a
      burst of saves to one scope collapses into a single rebuild.
    * upsert/delete jobs carry an `_id` → dedup per `(op, scope, _id)`.

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
    * transient (DB connection blip surfaced as an exception) → `{:snooze, 60}`.
    * anything else (the projector returns `{:error, _}`) → `{:error, _}` so
      Oban applies its normal backoff.
  """

  use Oban.Worker,
    queue: :edge_projector,
    max_attempts: 5,
    unique: [
      keys: [:op, :scope, :_id],
      states: [:available, :scheduled, :executing],
      period: 30
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.EdgeProjector.Projector

  @debounce_seconds 5
  @snooze_seconds 60

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
      "types" => Keyword.get(opts, :types, []),
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
  is ON. Unique per `(scope, id)`.
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
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Build a debounced DELETE job removing every edge touching `id` in `scope`'s
  graph. Routed by `:after_unpublish` / `:after_delete`. Unique per
  `(scope, id)`.
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
  # transaction). A DB blip surfaces as an exception → snooze.
  defp run_rebuild(scope, types, args) do
    list_opts =
      [perspective: :published, limit: 1000]
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    project_opts =
      [dataset: scope]
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    docs =
      types
      |> Enum.flat_map(fn type ->
        content_mod(args).list_documents(type, scope, list_opts)
      end)
      |> Enum.map(&hydrate_task_edges/1)

    case projector_mod(args).rebuild_scope(scope, docs, project_opts) do
      {:ok, %{added: added, deleted: deleted}} ->
        Logger.info(
          "EdgeProjector.ProjectorWorker: rebuilt scope=#{scope} " <>
            "added=#{added} deleted=#{deleted}"
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
      Logger.warning(
        "EdgeProjector.ProjectorWorker: rebuild raised for scope=#{scope}, snoozing: " <>
          Exception.message(e)
      )

      {:snooze, @snooze_seconds}
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
      Logger.warning(
        "EdgeProjector.ProjectorWorker: upsert raised for scope=#{scope}, snoozing: " <>
          Exception.message(e)
      )

      {:snooze, @snooze_seconds}
  end

  defp do_upsert(scope, id, doc, args) do
    project_opts =
      [dataset: scope]
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

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
      project_opts =
        [dataset: scope]
        |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
        |> maybe_put(:project_id, Map.get(args, "project_id"))

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
      Logger.warning(
        "EdgeProjector.ProjectorWorker: delete raised for scope=#{scope}, snoozing: " <>
          Exception.message(e)
      )

      {:snooze, @snooze_seconds}
  end

  defp first_type([t | _]) when is_binary(t) and t != "", do: t
  defp first_type(_), do: nil

  # Hydrate a task doc's payload with its authoritative `task_edges` rows BEFORE
  # the pure projection runs (gap #1 fix — `content.dependencies` is a DEAD KEY;
  # `task_edges` is the only authoritative dependency store). This is the
  # DB-touching layer, so reading `task_edges` here keeps the plugin
  # `extract_edges/2` callback pure. `Tasks.hydrate_edges/1` is a no-op for any
  # non-task doc, so calling it on every corpus doc is safe. The Tasks plugin is
  # first-party + always compiled; the guard only protects a doc payload that is
  # not a map (never crashes the projection).
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
