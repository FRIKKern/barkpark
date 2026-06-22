defmodule Barkpark.Content.WriteScope do
  @moduledoc """
  Tenancy scope resolution for content writes + reads (concern K).

  This is the security-sensitive half of content scoping — the write-side
  scope stamping (`put_scope_attrs/2`), the read-side dataset_id resolution
  (`resolve_read_dataset_id/2`, `scope_to_dataset/3`), the seeded-Default
  fallback, and the per-request memoization gate. It is intentionally distinct
  from `Barkpark.Content.Scope` (the read-only `scope_to_workspace_*` query
  helpers): that module owns the workspace/project WHERE-clause semantics and
  the fail-closed-on-nil guard, while this module owns *how the scope is
  resolved* before it is applied or stamped.

  The B3/workspace-leak fixes (barkpark-wykb / sknf / y9ee / s6t1) live in the
  resolution logic here. The regression suite — `content_mutate_scope_leak_test`,
  `content_cross_project_dataset_scope_test`, `content_workspace_write_scope_test`,
  `content_dataset_id_authoritative_test`, `tenancy_fixtures_test` — exercises
  this module.

  Also hosts the two lifecycle-hook helpers (`build_ctx/1`, `fire_after/3`) and
  the scope-attr inheritance (`inherit_scope_attrs/2`) that the write/publish
  paths thread through, since they compose with scope stamping on every write.
  """

  import Ecto.Query

  alias Barkpark.Content.Document

  # ── Lifecycle-hook helpers ────────────────────────────────────────────────
  #
  # `build_ctx/1` constructs the `ctx` map every hook payload carries. The
  # `:source` field is the recursion guard — plugins inspect it (e.g.
  # `ctx.source == :worker`) to short-circuit hooks they themselves fired.
  # `fire_after/3` only fires after_* on a successful write; errors flow
  # through untouched so existing `{:error, changeset}` paths keep working.

  def build_ctx(opts) do
    %{
      source: Keyword.get(opts, :source, :api),
      user_id: Keyword.get(opts, :user_id)
    }
  end

  # Stamp the tenancy scope onto write attrs when the caller supplied it via
  # opts (`:workspace_id` / `:project_id`). Only non-nil scope keys are added,
  # so a write WITHOUT scope opts leaves attrs untouched — the Document
  # changeset only casts these keys when present, so an existing row's
  # workspace_id/project_id is never nulled by an unscoped update. New rows
  # created under a resolved scope are stamped on insert from that scope.
  #
  # W2 dual-write: alongside the workspace/project scope, resolve the row's
  # `dataset` STRING → its `dataset_id` (within the resolved project) and stamp
  # BOTH. The string stays the safety-net mirror; `dataset_id` is the new
  # authoritative scoping key. Degrades to no `dataset_id` key (string-only)
  # when the project or dataset string can't be resolved — never crashes a
  # write, and the changeset leaves an existing row's dataset_id untouched.
  def put_scope_attrs(attrs, opts) do
    {ws_id, project_id} = resolve_write_scope(attrs, opts)
    dataset_id = resolve_dataset_id_for_write(attrs, project_id)

    attrs
    |> maybe_put_scope_attr("workspace_id", ws_id)
    |> maybe_put_scope_attr("project_id", project_id)
    |> maybe_put_scope_attr("dataset_id", dataset_id)
  end

  # Resolve the `dataset_id` to stamp on a write from the row's `dataset` STRING
  # + the resolved `project_id`. Returns the id, or nil when either is missing
  # (the caller then stamps nothing — keeping the string-only mirror). Uses
  # get_or_create_dataset so a brand-new dataset string lands a row on first
  # write rather than silently dropping the id.
  defp resolve_dataset_id_for_write(attrs, project_id) do
    dataset = Map.get(attrs, "dataset") || Map.get(attrs, :dataset)

    cond do
      is_nil(project_id) or not is_binary(dataset) ->
        nil

      true ->
        case Barkpark.Tenancy.get_or_create_dataset(project_id, dataset) do
          {:ok, %Barkpark.Tenancy.Dataset{id: id}} -> id
          _ -> nil
        end
    end
  end

  # Resolve the {workspace_id, project_id} to stamp on a write. Explicit scope
  # (opts, or an existing scope key already in attrs) ALWAYS wins. When the
  # caller supplied no scope at all, fall back to the seeded Default Workspace /
  # Default Project so unscoped (nil) fixtures land in Default and stay visible
  # to Default-scoped flat-route reads. Degrades to nil when the backfill hasn't
  # run yet (fresh test sandbox before seed) — never crashes.
  #
  # Workspace-only scope (barkpark-wykb): the `scope_to_workspace(q, ws, nil)`
  # contract lets a caller pass workspace_id WITHOUT a project_id. Without
  # resolution that write got workspace_id stamped but dataset_id=NULL (the
  # dataset_id resolver below short-circuits on a nil project) — invisible to a
  # strict dataset_id reader in its own scope. So when we hold a workspace but
  # no project, resolve the WORKSPACE'S OWN default project (prefer the
  # "default"-slug project, else the first project of that workspace) and stamp
  # it, which lets the dataset_id resolve too. NEVER-WORSE: if the workspace has
  # no projects, project_id stays nil (and dataset_id stays NULL) — the
  # yx7f NULL-tolerant read still finds the row.
  defp resolve_write_scope(attrs, opts) do
    opt_ws = Keyword.get(opts, :workspace_id)
    opt_proj = Keyword.get(opts, :project_id)

    cond do
      not is_nil(opt_ws) and is_nil(opt_proj) ->
        {opt_ws, default_project_id_for_workspace(opt_ws)}

      not is_nil(opt_ws) ->
        {opt_ws, opt_proj}

      scope_key_present?(attrs) ->
        {opt_ws, opt_proj}

      true ->
        ws = Barkpark.Tenancy.get_default_workspace()
        proj = Barkpark.Tenancy.get_default_project()
        {ws && ws.id, proj && proj.id}
    end
  end

  # Resolve a workspace's OWN default project id for a workspace-only write.
  # Prefers the project whose slug is "default", else the first project (the
  # list is slug-ordered). Returns nil when the workspace has no projects —
  # the caller then keeps the nil project_id (and the dataset_id resolver
  # keeps dataset_id NULL), never crashing.
  defp default_project_id_for_workspace(ws_id) when is_binary(ws_id) do
    case Barkpark.Tenancy.list_projects(ws_id) do
      [] ->
        nil

      projects ->
        project = Enum.find(projects, &(&1.slug == "default")) || hd(projects)
        project.id
    end
  end

  defp default_project_id_for_workspace(_), do: nil

  defp scope_key_present?(attrs) do
    Map.has_key?(attrs, "workspace_id") or Map.has_key?(attrs, :workspace_id)
  end

  # W2 read-scope: resolve the incoming `dataset` STRING → its `dataset_id`
  # within the read's project scope (opts `:project_id`, else the seeded Default
  # project). Returns the id, or nil when no matching dataset row exists — in
  # which case the caller keeps the legacy `dataset` STRING filter (back-compat:
  # a read against a never-written dataset string returns no rows either way).
  # Read-only (Repo.get_by) — never creates a dataset on a read path.
  #
  # Public so search read paths (DocumentsRetriever) can resolve the same
  # dataset_id and filter authoritatively instead of on the bare `dataset`
  # STRING, which conflates same-name datasets within a workspace (barkpark-y9ee).
  def resolve_read_dataset_id(dataset, opts) when is_binary(dataset) do
    # Project resolution — only fall back to the seeded Default project when
    # the caller passed NO scope at all (flat back-compat read). When the
    # caller pinned a workspace but no project, falling back to Default's
    # project crosses tenants: get_dataset(default_proj, dataset) can match a
    # same-named dataset row under Default and the resolver returns Default's
    # dataset_id, which scope_to_dataset then applies as a strict
    # `dataset_id == default_ds_id` filter that excludes the workspace's own
    # rows (barkpark-sknf, surfaced when 5znv memo no longer hides it). With
    # `workspace_id` present and `project_id` absent the resolver returns nil
    # → scope_to_dataset uses the legacy STRING path, and the subsequent
    # `scope_to_workspace_or_global` filter keeps the read tenant-correct.
    project_id =
      cond do
        pid = Keyword.get(opts, :project_id) -> pid
        Keyword.has_key?(opts, :workspace_id) -> nil
        true -> read_default_project_id(opts)
      end

    # Per-request memoization (barkpark-5znv, gated barkpark-sknf): a single
    # public HTTP read fans this resolve across schema_public? + list_documents
    # + schema_hash_for_dataset (~9 calls), all for the immutable {project_id,
    # dataset} pair. The result (id OR nil) is keyed in the Process dictionary.
    #
    # The memo is GATED on an explicit `memoize: true` opt that ONLY HTTP
    # request controllers set via `ScopeHelpers.scope_opts(conn)`. LiveView
    # callers, Oban workers, mix tasks, and search retrievers DON'T pass the
    # opt → no memo → no staleness. The original 5znv goal (collapse the 9
    # redundant get_dataset reads on a single HTTP request) is preserved; the
    # staleness foot-gun in long-lived processes (LV session lifetime, reused
    # Oban worker pids, sandbox-reused test pids) is closed.
    #
    # The resolved id is identical to the uncached path — only the redundant
    # get_dataset roundtrips are skipped on the request path.
    memoize?(opts, {:resolve_read_dataset_id, project_id, dataset}, fn ->
      case project_id && Barkpark.Tenancy.get_dataset(project_id, dataset) do
        %Barkpark.Tenancy.Dataset{id: id} -> id
        _ -> nil
      end
    end)
  end

  def resolve_read_dataset_id(_dataset, _opts), do: nil

  # The Default project id is immutable within a request; memoize it so the
  # no-`:project_id` (flat/back-compat) route resolves get_default_project once
  # — collapsing get_default_workspace + get_default_project (2 reads) that
  # otherwise repeated on every resolve call within the same request.
  #
  # Same gating as resolve_read_dataset_id (barkpark-sknf): memoization only
  # fires when the caller opted in via `memoize: true`. LV/worker callers see
  # the fresh-every-call path.
  def read_default_project_id(opts \\ []) do
    memoize?(opts, :read_default_project_id, fn ->
      case Barkpark.Tenancy.get_default_project() do
        %{id: id} -> id
        _ -> nil
      end
    end)
  end

  # Per-request memo helper, gated on an explicit `memoize: true` opt
  # (barkpark-sknf). When the opt is absent the fun is invoked fresh and
  # nothing is written to the Process dictionary — long-lived LV/Oban/test
  # processes never accumulate stale memos. When the opt is present the
  # result is cached under `key` in the Process dictionary, distinguishing
  # "cached nil" from "not yet computed" via a private sentinel so a
  # legitimately-nil resolution is not recomputed.
  @memo_miss :"$barkpark_memo_miss"
  defp memoize?(opts, key, fun) do
    if Keyword.get(opts, :memoize, false) do
      case Process.get({:barkpark_request_memo, key}, @memo_miss) do
        @memo_miss ->
          value = fun.()
          Process.put({:barkpark_request_memo, key}, value)
          value

        value ->
          value
      end
    else
      fun.()
    end
  end

  # Apply the W2 dataset scope to a read query. When the dataset string resolves
  # to a `dataset_id`, filter authoritatively by `x.dataset_id` BUT also match
  # rows whose `dataset_id` is NULL and whose `dataset` STRING equals the
  # requested one — legacy/unstamped rows the strict filter would drop (asset
  # docs, non-Default-project rows the 132000 backfill skipped, workspace-only
  # writes). This mirrors scope_schema_to_dataset/3. The dataset STRING and
  # dataset_id are 1:1 within a project, so the OR never crosses datasets.
  # Never-worse: stamped rows still match strictly by dataset_id; NULL rows
  # recover the legacy string match. Otherwise fall back to the legacy
  # `x.dataset` STRING filter (the mirror still works for datasets that predate
  # a row or live outside the resolved project).
  def scope_to_dataset(query, dataset, opts) do
    case resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end

  defp maybe_put_scope_attr(attrs, _key, nil), do: attrs
  defp maybe_put_scope_attr(attrs, key, value), do: Map.put(attrs, key, value)

  # Copy the tenancy scope (workspace_id/project_id) from a source document
  # onto write attrs — used by the draft↔published transitions (publish /
  # unpublish) so the moved row keeps the scope of the row it was derived from.
  # A nil source field is skipped, leaving the destination as-is.
  def inherit_scope_attrs(attrs, %Document{
        workspace_id: ws_id,
        project_id: project_id,
        dataset_id: dataset_id
      }) do
    attrs
    |> maybe_put_scope_attr("workspace_id", ws_id)
    |> maybe_put_scope_attr("project_id", project_id)
    |> maybe_put_scope_attr("dataset_id", dataset_id)
  end

  def inherit_scope_attrs(attrs, _), do: attrs

  def fire_after({:ok, doc}, event, payload) do
    after_payload = %{payload | event: event, doc: doc}
    _ = Barkpark.Plugins.Hooks.fire(event, after_payload)

    # CORE fresh-install wiring (Goal ges/graph-edge-seam Phase 3, gap #1).
    # `Hooks.fire/2` dispatches ONLY to plugins' `lifecycle_hooks/0` — core is
    # not a plugin, so on a plugins-[] install ZERO edge projection would fire
    # and the content graph would be empty. This DIRECT enqueue fires the
    # projector for CORE docs on every save/publish/unpublish/delete regardless
    # of plugins — the load-bearing fresh-install hook. The Lifecycle module
    # branches event→op (save/publish→rebuild|upsert, unpublish/delete→delete),
    # so one call covers all four events.
    #
    # RECURSION GUARD: gated on `ctx.source != :worker`. The projector writes
    # the `content_edges` table, not documents through `Content.*`, so it cannot
    # re-fire this today. INVARIANT: if any FUTURE projector path EVER re-saves a
    # doc, it MUST stamp `ctx.source == :worker` or this will re-enqueue
    # indefinitely. A payload with no `:ctx` is treated as source nil → enqueue.
    if get_in(after_payload, [:ctx, :source]) != :worker do
      _ = Barkpark.EdgeProjector.Lifecycle.enqueue_rebuild(after_payload)
    end

    {:ok, doc}
  end

  def fire_after(other, _event, _payload), do: other
end
