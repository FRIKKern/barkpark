defmodule BarkparkWeb.Plugs.TenantLogMetadata do
  @moduledoc """
  Stamp the resolved tenant scope (`workspace_id` / `workspace_slug` /
  `project_id` / `dataset`) onto the CURRENT process's `Logger.metadata`, so
  every log line a request or Studio session emits is tenant-attributable.

  ## Named failure mode this closes

  `request_id` is in `Logger.metadata` (Plug.RequestId + the config formatter),
  so request correlation works — but NO plug/hook wrote the tenant scope, so
  every prod log line was tenant-ANONYMOUS. In a multi-tenant CMS
  (`docs/contracts/tenancy.md`) that hides the answer to the production
  questions that matter: "which workspace is generating this 500 spike / this
  load?" and — critically — "during the field-visibility cross-tenant leak we
  just detected, WHICH tenants were touched?". Field-visibility leaks are a
  documented scar (seal every read path, fail closed); a leak fires, logs carry
  `request_id` but no tenant, and incident scoping degrades to hand-correlating
  request_ids against access logs. That blindness hides the blast radius of a
  SECURITY failure — hence P1.

  ## How it is wired (both surfaces)

  `Logger.metadata` is PER-PROCESS, so the stamp must run on the process that
  actually emits the logs:

    * **HTTP API** — this module is a Plug appended LAST in every scope-bearing
      pipeline (after `AssignDefaultScope` / `ResolveWorkspace` + `ResolveProject`
      have set the assigns). A Phoenix request is one process, so stamping in the
      pipeline covers every subsequent log line the controller emits.

    * **LiveView Studio** — `StudioLive.handle_params/3` calls `stamp/3` right
      after `Shared.ensure_tenancy_scope/1`, on the long-lived LiveView process.
      It re-runs on every navigation / scope switch (push_patch → handle_params),
      so a mid-session workspace switch re-stamps the new tenant.

  The config formatter's `:metadata` allowlist (`api/config/config.exs`) MUST
  list `keys/0` or the fields resolve but never render. Both are added together.

  ## Cheap + fail-open-safe

  No DB query — it reads scope already resolved on the conn/socket. An
  anonymous / global-scope request (no workspace resolved) stamps the explicit
  `workspace_id: "global"` sentinel rather than crashing or leaving the field
  absent, so a global log line is unambiguous in triage (not "missing" — an
  explicit, greppable marker). This is metadata for LOGS ONLY; it never touches
  the response.
  """

  @behaviour Plug

  require Logger

  # The sentinel for a request/session with no resolved workspace — an explicit,
  # greppable "this log line is global/anonymous scope" marker. Chosen over a
  # bare nil (which Logger.metadata deletes → the field silently vanishes) so
  # incident triage can positively distinguish "global" from "field dropped".
  @global_sentinel "global"

  @doc """
  The metadata keys this plug stamps. The `api/config/config.exs`
  `config :logger, :default_formatter, metadata: [...]` allowlist MUST include
  these or they resolve but never render.
  """
  @spec keys() :: [atom()]
  def keys, do: [:workspace_id, :workspace_slug, :project_id, :dataset]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    stamp(
      conn.assigns[:current_workspace],
      conn.assigns[:current_project],
      dataset_param(conn)
    )

    conn
  end

  # `dataset` is ALWAYS a path segment in this router (`/v1/data/.../:dataset/...`,
  # `/w/:ws/p/:proj/d/:dataset/...`), so `path_params` (a plain map once the route
  # has matched — never `Plug.Conn.Unfetched`) is the sole, safe source. Reading
  # `conn.params` here would raise on a request whose body params were never
  # fetched (e.g. a bare GET before Plug.Parsers).
  defp dataset_param(%{path_params: %{"dataset" => dataset}}) when is_binary(dataset), do: dataset
  defp dataset_param(_conn), do: nil

  @doc """
  Stamp the tenant scope onto the CURRENT process's `Logger.metadata`. Shared by
  the HTTP plug (`call/2`) and the Studio LiveView so the metadata keys +
  sentinel are defined in ONE place. `workspace`/`project` are the resolved
  structs/maps (anything with `.id` / `.slug`) or nil; `dataset` is the string
  segment or nil.
  """
  @spec stamp(map() | nil, map() | nil, binary() | nil) :: :ok
  def stamp(workspace, project, dataset) do
    Logger.metadata(
      workspace_id: id(workspace) || @global_sentinel,
      workspace_slug: slug(workspace),
      project_id: id(project),
      dataset: dataset
    )
  end

  defp id(%{id: id}) when is_binary(id), do: id
  defp id(_), do: nil

  defp slug(%{slug: slug}) when is_binary(slug), do: slug
  defp slug(_), do: nil
end
