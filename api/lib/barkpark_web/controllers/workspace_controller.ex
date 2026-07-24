defmodule BarkparkWeb.WorkspaceController do
  @moduledoc """
  Membership-scoped LIST surface for the web workspace/project switcher.

    * `GET /api/workspaces` — the Workspaces the bearer token is a MEMBER of
      (via `workspace_memberships`). A workspace the caller has no membership
      row in is NEVER returned — the hard tenant boundary, enforced in the
      `Tenancy.list_workspaces_for/1` query, not here.

    * `GET /api/workspaces/:workspace_slug/projects` — the Projects under that
      workspace, but ONLY when the caller is a member. A non-member (and an
      unknown slug) both return 404 so the endpoint never leaks whether a
      workspace exists. `:require_token` already 401s an absent/invalid token.

    * `DELETE /api/workspaces/:workspace_slug` — permanently delete a workspace
      and everything scoped to it. This one is ADMIN-gated (the `:require_admin`
      pipeline), NOT membership-scoped — it is the destructive primitive eject /
      backup / abuse-isolation build on, so it needs the global `admin`
      permission, not mere membership.

  Token is assigned to `conn.assigns[:api_token]` by the `:require_token`
  pipeline. The JSON envelope mirrors the flat `/v1` controllers — a plain map
  rendered with `json/2`, no separate view module.
  """
  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError

  action_fallback BarkparkWeb.FallbackController

  def index(conn, _params) do
    token = conn.assigns[:api_token]
    workspaces = Tenancy.list_workspaces_for(token)
    json(conn, %{workspaces: Enum.map(workspaces, &render_workspace/1)})
  end

  @doc """
  POST /api/workspaces — create a Workspace owned by the bearer token.

  Any authenticated token may create a workspace; the creator is bound as an
  `"owner"` Membership in the same transaction, and a Default Project +
  "production" Dataset are bootstrapped so the workspace is immediately usable.
  201 + the created workspace; 422 (via FallbackController) on an invalid /
  duplicate slug.
  """
  def create(conn, params) do
    token = conn.assigns[:api_token]
    attrs = workspace_attrs(params)

    with {:ok, workspace} <- Tenancy.create_workspace_with_owner(attrs, token) do
      conn
      |> put_status(:created)
      |> json(%{workspace: render_workspace(workspace)})
    end
  end

  @doc """
  POST /api/workspaces/:workspace_slug/projects — create a Project (+ its
  "production" Dataset) under a workspace the caller is a MEMBER of.

  A non-member (and an unknown slug) both collapse to 404 — the same no-leak
  convention as the `projects` LIST action. 201 + the created project on
  success; 422 on an invalid / duplicate slug.
  """
  def create_project(conn, %{"workspace_slug" => slug} = params) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id),
         {:ok, project} <-
           Tenancy.create_project_with_dataset(workspace, project_attrs(params)) do
      conn
      |> put_status(:created)
      |> json(%{project: render_project(project)})
    else
      # A changeset error flows to the FallbackController (422). Anything else
      # (unknown slug / non-member) collapses to 404 — no existence leak.
      {:error, %Ecto.Changeset{}} = err -> err
      _ -> {:error, :not_found}
    end
  end

  @doc """
  DELETE /api/workspaces/:workspace_slug — permanently delete a Workspace and
  everything scoped to it.

  Admin-gated by the router's `:require_admin` pipeline (RequireToken +
  RequireAdmin — a caller without the global `admin` permission is refused 403
  before this action runs; NOT membership-scoped like the LIST/create surface).
  This is the HTTP primitive the destructive keystone consumers (eject, backup,
  abuse-isolation) assume; `Tenancy.delete_workspace/1` already exists and is
  tested but was unreachable over HTTP until now.

  Delegates to `Tenancy.delete_workspace/1`, which cascades inside a single
  transaction — media blobs (File.rm + CDN purge via `Media.delete_file/2`),
  documents (both draft and published variants, with plugin hooks), and every
  `workspace_id`-scoped table — rolling the whole thing back on any failure.

  Unknown slug → 404 (`{:error, :not_found}` via the FallbackController). On
  success → 200 echoing the deleted workspace so the caller has immediate,
  concrete confirmation of exactly what was removed.
  """
  def delete(conn, %{"workspace_slug" => slug}) do
    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         {:ok, deleted} <- Tenancy.delete_workspace(workspace) do
      json(conn, %{workspace: render_workspace(deleted), deleted: true})
    else
      # Unknown slug (get returns nil) OR delete_workspace resolving :not_found
      # both collapse to 404. A rollback term ({:error, reason}) flows to the
      # FallbackController, which maps it to the structured error envelope.
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  GET /api/workspaces/:workspace_slug/export — stream the complete bp-export-v1
  bundle for a workspace as an `application/x-tar` attachment (admin-gated).

  SYNC, but CONSTANT-MEMORY: `WorkspaceBundle.export_to_file/2` streams the
  bundle to a per-request temp tar and this action `send_file/3`s it, so a
  941 MB bundle never becomes a 941 MB binary in the request process (PDS-D204;
  this is the ONLY caller of `export_to_file/2` — `export/2` keeps its
  `{:ok, binary()}` contract for the fidelity suite). `send_file/3` uses the
  same queued response headers and computes Content-Length from `File.stat!`,
  so the wire shape is unchanged: 200, `application/x-tar`, no chunked
  transfer-encoding. An unknown slug collapses to 404 (no existence leak beyond
  the admin gate); the resolved workspace always carries a valid UUID, so the
  engine's fail-closed `:workspace_id_required` guard is never reached here.

  ## Scope query params (PDS W1 — additive, both optional)

    * `profile=dev` — the scrubbed dev bundle (secret/credential/PII/size
      classes are never queried, per `Catalog.dev_partition/0`). Absent or
      `profile=full` is the unchanged full-fidelity backup.
    * `dataset=<slug>` — narrow the bundle to one dataset.
    * `source_server=<url>` — provenance passthrough stamped into the manifest.

  A bad profile / unknown / ambiguous dataset slug answers 422 `unprocessable`
  with an additive `reason` naming which one (`invalid_profile`,
  `dataset_not_found`, `ambiguous_dataset_slug`) — an honest refusal, never a
  silently wrong bundle. The response content type is set UNCONDITIONALLY to
  `application/x-tar`; there is no Accept negotiation on this route.

  A COPY that dies mid-dump answers 503 `export_failed` + a retry hint (PDS-D43),
  never the old bare 500 `internal_error / unknown error`.
  """
  # @sobelow_skip — Traversal.SendFile is an accepted false positive here, on a
  # stronger argument than the three media_controller sites: `path` is a
  # freshly-created per-request temp tar whose name the ENGINE chose
  # (`bp-ws-bundle-<unique_integer>.tar` under the configured spill dir). No
  # request input reaches it at all — not the slug, not a query param — so
  # there is no traversal surface to defend.
  # The `after File.rm(path)` deletes that same engine-chosen temp tar; no
  # request input reaches the path, so it shares the SendFile argument above.
  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  def export(conn, %{"workspace_slug" => slug} = params) do
    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         {:ok, path} <- export_bundle(workspace, params) do
      # The engine hands ownership of the tar to us. `send_file/3` has finished
      # writing to the socket by the time it returns, so deleting here is safe —
      # and a socket killed mid-send raises a CATCHABLE Bandit.TransportError,
      # which this `after` clause still fires on. (SIGKILL is out of reach by
      # construction; sweeping orphans is pds-w11-spill-janitor's job.)
      try do
        conn
        |> put_resp_content_type("application/x-tar", nil)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=#{export_filename(params, workspace)}"
        )
        |> send_file(200, path)
      after
        File.rm(path)
      end
    else
      nil ->
        {:error, :not_found}

      {:error, {:export_scope, reason, message}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "unprocessable", reason: reason, message: message}})

      # PDS-D43: a transport-class failure used to escape as a bare 500
      # `internal_error / unknown error` — the caller learned nothing and could
      # not tell "your request was wrong" from "the dump did not finish". 503,
      # not 500: nothing about the REQUEST was wrong, the export is legitimately
      # retryable, and 503 is the status every client/proxy already reads as
      # "try me again". The hint names retry explicitly AND names the narrower
      # grain, because on a memory-tight box a smaller bundle is the retry that
      # actually succeeds (PDS-D44: an attempt costs the same as a success).
      {:error, {:export_failed, reason, message}} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "export_failed",
            reason: reason,
            message: message,
            hint:
              "the export did not finish (database transport failure). Retry; " <>
                "if it fails again, narrow the bundle with ?profile=dev and/or ?dataset=<slug>."
          }
        })

      # export/2 only errors on a nil/non-UUID id or a missing workspace — both
      # unreachable once get_workspace_by_slug returns a real %Workspace{} — but
      # fold any error into 404 rather than leak an engine tuple.
      {:error, _} ->
        {:error, :not_found}
    end
  end

  # The engine RAISES on an unresolvable scope opt (a scope mistake must never
  # resolve silently into a wrong bundle); the HTTP edge turns that into an
  # honest 422 envelope instead of a 500.
  defp export_bundle(workspace, params) do
    opts =
      [
        profile: params["profile"],
        dataset: params["dataset"],
        source_server: params["source_server"]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    WorkspaceBundle.export_to_file(workspace.id, opts)
  rescue
    e in WorkspaceBundle.ExportScopeError ->
      {:error, {:export_scope, e.code, Exception.message(e)}}

    # Transport class ONLY — the connection died / the COPY did not finish.
    # Deliberately narrow: everything else still crashes loudly into the 500
    # path with its stacktrace, because a rescue wide enough to swallow a real
    # engine bug would turn every future export defect into a polite "retry".
    e in DBConnection.ConnectionError ->
      {:error, {:export_failed, "database_unavailable", Exception.message(e)}}
  end

  # The filename names the grain the caller actually asked for, so two pulls of
  # the same workspace never land on top of each other on disk.
  defp export_filename(params, workspace) do
    [workspace.slug, params["dataset"], params["profile"]]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("-")
    |> Kernel.<>(".tar")
  end

  @doc """
  POST /api/workspaces/:workspace_slug/import — read the raw tar request body and
  re-import it via `WorkspaceBundle.import_bundle/2` (admin-gated).

  The bundle is SELF-DESCRIBING (its manifest carries the workspace identity and
  per-table import strategy). Two modes, selected via the `mode` query param:

    * absent / `mode=clean` (default) — restore into an EMPTY scope. The
      string-keyed members (E3/allowlist) re-import idempotently via INSERT ON
      CONFLICT DO NOTHING, but the copy-strategy members (root/E1/E2) assume a
      CLEAN target: a second import over a still-populated workspace
      PK-conflicts. Unchanged behavior.
    * `mode=merge` (PDS-D8/D10) — convergent upsert over a possibly-populated
      workspace. FAIL-CLOSED OPT-IN: refused with 403 `bundle_import_disabled`
      unless `Application.get_env(:barkpark, :allow_bundle_import, false)` is
      true (the env plumb ships separately; the default here is always false).
      A same-slug/different-id root collision on a NON-empty workspace returns
      409 `workspace_slug_conflict` (PDS-D9) instead of an opaque 25P02.

  Returns the import stats — `{tables, total_rows}` — as JSON (plus
  `mode: "merge"` on the merge path), and a `provenance` receipt: pulled data
  says WHERE it came from, both in the response and, durably, in the target
  workspace's `settings["pull_provenance"]` (PDS-D15/D16).

  An empty or truncated body answers 422 `invalid_bundle` — an honest refusal
  rather than the MatchError-driven 500 it used to raise (PDS-D50).

  A bundle row that collides with RESIDENT target content on a constraint the
  merge arbiter does not cover (any non-primary-key unique index, e.g. the
  `(name, dataset) WHERE dataset_id IS NULL` schema partial) answers 409
  `import_constraint_violation` naming the violated constraint + table — never
  the opaque `internal_error` 500 the live support chain died blind on
  (task-63a199c0a0ce2a06). Non-constraint Postgres raises still 500 loudly.
  """
  def import(conn, %{"workspace_slug" => _slug} = params) do
    case params["mode"] || "clean" do
      "clean" ->
        {bundle, conn} = read_full_body(conn)
        clean_import(conn, bundle)

      "merge" ->
        if Application.get_env(:barkpark, :allow_bundle_import, false) do
          {bundle, conn} = read_full_body(conn)
          merge_import(conn, bundle)
        else
          # Fail-closed opt-in (PDS-D10): merge writes into a live workspace, so
          # the server operator must explicitly allow it — refused BEFORE the
          # body is drained or the engine is touched.
          conn
          |> put_status(:forbidden)
          |> json(%{
            error: %{
              code: "bundle_import_disabled",
              message:
                "mode=merge requires the server to opt in via the " <>
                  ":allow_bundle_import config (BARKPARK_ALLOW_BUNDLE_IMPORT)"
            }
          })
        end

      other ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "invalid_mode",
            message: "unknown import mode #{inspect(other)} (expected clean or merge)"
          }
        })
    end
  end

  defp clean_import(conn, bundle) do
    {:ok, stats} = WorkspaceBundle.import_bundle(bundle)

    json(conn, %{
      tables: stats.tables,
      total_rows: stats.total_rows,
      provenance: stamp_provenance(stats.manifest)
    })
  rescue
    e in InvalidBundleError -> invalid_bundle(conn, e)
    e in Postgrex.Error -> constraint_conflict_or_reraise(conn, e, __STACKTRACE__)
  end

  defp merge_import(conn, bundle) do
    case WorkspaceBundle.import_bundle(bundle, mode: :merge) do
      {:ok, stats} ->
        json(conn, %{
          tables: stats.tables,
          total_rows: stats.total_rows,
          mode: "merge",
          provenance: stamp_provenance(stats.manifest)
        })

      {:error, {:workspace_slug_conflict, info}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            code: "workspace_slug_conflict",
            message:
              "workspace slug #{inspect(info.slug)} exists under a different id and is " <>
                "not an empty shell — refuse to merge over it",
            details: %{
              slug: info.slug,
              existing_id: info.existing_id,
              bundle_id: info.bundle_id
            }
          }
        })
    end
  rescue
    e in InvalidBundleError -> invalid_bundle(conn, e)
    e in Postgrex.Error -> constraint_conflict_or_reraise(conn, e, __STACKTRACE__)
  end

  # PDS-D50 — the engine RAISES on bytes that cannot be a bundle (empty,
  # truncated, not a tar, no manifest). The HTTP edge answers an honest,
  # machine-branchable 422 rather than an opaque 500 the caller cannot act on.
  defp invalid_bundle(conn, %InvalidBundleError{} = e) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: e.code, message: e.message}})
  end

  # The Postgres error classes an import can hit against RESIDENT target
  # content: the merge arbiter is each member's primary key ONLY, so a bundle
  # row colliding with a different-id resident row on any OTHER unique index
  # (and, under `session_replication_role = replica`, any check/not-null the
  # replica role does NOT disable) raises straight through the engine.
  @import_constraint_pg_codes ~w(
    unique_violation exclusion_violation check_violation
    not_null_violation foreign_key_violation
  )a

  # task-63a199c0a0ce2a06 — the on-box support-chain import 500'd LIVE and the
  # caller learned only "exit status 8": a constraint-class Postgrex raise
  # escaped as an opaque `internal_error` whose body names nothing. Surface the
  # constraint honestly instead: 409, machine-branchable code, the violated
  # constraint + table + Postgres code in `details`, the full Postgres message
  # (which names the colliding key values) as `message`. DELIBERATELY NARROW —
  # only the constraint classes above are caught; any other Postgrex raise (a
  # genuine engine bug: bad SQL, missing column, privilege failure) still
  # crashes loudly into the 500 path with its stacktrace, mirroring the export
  # rescue's posture. The data-loss refuse guard (PDS-D9 workspace_slug_conflict)
  # is untouched — it returns an error tuple, never a raise.
  defp constraint_conflict_or_reraise(
         conn,
         %Postgrex.Error{postgres: %{code: code} = pg} = e,
         _stacktrace
       )
       when code in @import_constraint_pg_codes do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "import_constraint_violation",
        message: Exception.message(e),
        details: %{
          pg_code: Atom.to_string(code),
          constraint: pg[:constraint],
          table: pg[:table]
        }
      }
    })
  end

  defp constraint_conflict_or_reraise(_conn, %Postgrex.Error{} = e, stacktrace) do
    reraise(e, stacktrace)
  end

  # PDS-D15/D16 — stamp WHERE the imported data came from into the target
  # workspace's `settings["pull_provenance"]`, keyed by dataset slug, and echo
  # the same receipt in the response.
  #
  # A dataset-narrowed bundle stamps exactly its one dataset; a whole-workspace
  # bundle stamps every dataset it carries (all of them were pulled). The stamp
  # is also what `Plugins.Bootstrap`'s guard reads, so a miss here is reported
  # honestly (`stamped: false` + a reason) instead of being swallowed — an
  # unstamped dataset is one boot away from a plugin clobber.
  defp stamp_provenance(manifest) when is_map(manifest) do
    stamp = %{
      "source_server" => manifest["source_server"],
      "source_workspace" => manifest["source_workspace"] || manifest["workspace_slug"],
      "source_dataset" => manifest["source_dataset"] || manifest["dataset"],
      "exported_at" => manifest["exported_at"],
      "profile" => manifest["profile"] || "full",
      "pulled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    slugs = provenance_slugs(manifest)
    workspace_slug = manifest["workspace_slug"]

    case Tenancy.get_workspace_by_slug(workspace_slug) do
      %Tenancy.Workspace{} = workspace when slugs != [] ->
        stamped =
          Enum.filter(slugs, fn slug ->
            # Re-read per slug: each write returns the updated workspace and the
            # next stamp must merge into it, not into a stale settings map.
            case Tenancy.set_pull_provenance(workspace.id, slug, stamp) do
              {:ok, _ws} ->
                true

              {:error, reason} ->
                Logger.warning(
                  "WorkspaceController.import: could not stamp pull provenance for " <>
                    "#{inspect(workspace_slug)}/#{inspect(slug)}: #{inspect(reason)}"
                )

                false
            end
          end)

        %{
          workspace: workspace_slug,
          datasets: stamped,
          stamped: stamped != [],
          stamp: stamp
        }

      %Tenancy.Workspace{} ->
        unstamped(workspace_slug, stamp, "no_dataset_in_manifest")

      nil ->
        unstamped(workspace_slug, stamp, "workspace_not_found")
    end
  end

  defp unstamped(workspace_slug, stamp, reason) do
    Logger.warning(
      "WorkspaceController.import: imported bundle for #{inspect(workspace_slug)} was " <>
        "NOT provenance-stamped (#{reason})"
    )

    %{workspace: workspace_slug, datasets: [], stamped: false, reason: reason, stamp: stamp}
  end

  # Which dataset slots this bundle covers: the narrowed one when the export was
  # dataset-scoped, else every dataset the manifest carries.
  #
  # KNOWN GAP, stated rather than hidden (PDS-D45/D46). `dataset_slugs` is the
  # workspace-EXCLUSIVE attribution set, NOT "the datasets in this bundle": a
  # slug also owned by a sibling workspace is dropped by `dataset_slugs_for/1`
  # under the D21 exclusivity rule. So a WHOLE-WORKSPACE pull whose source slug
  # is shared cross-tenant (guerrilla's `production` is owned by two workspaces)
  # can land with that dataset UNSTAMPED — and an unstamped dataset is one boot
  # away from the Bootstrap clobber this stamp exists to guard. A
  # dataset-narrowed pull (`?dataset=<slug>`, the PDS front door) is unaffected:
  # it reads `manifest["dataset"]`, which is always the slug that was asked for.
  # Tracked as `pds-bl-whole-workspace-shared-slug-stamp`.
  defp provenance_slugs(manifest) do
    case manifest["dataset"] || manifest["source_dataset"] do
      slug when is_binary(slug) ->
        [slug]

      _ ->
        manifest["dataset_slugs"]
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
    end
  end

  # Drain the entire raw request body (the tar bundle) — a POST body can arrive in
  # multiple chunks, so loop on `:more`. The `application/x-tar` content-type
  # matches no configured Plug.Parser (parsers pass `*/*` through unread), so the
  # bytes are still here to read. iolist accumulation avoids O(n^2) concatenation.
  defp read_full_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn, length: 100_000_000) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc, chunk])
    end
  end

  # Build the workspace create-attrs from the request body — only :name and an
  # optional :slug are honoured (slug derived from name when absent in the
  # context). Other body keys are ignored.
  defp workspace_attrs(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:slug, params["slug"])
  end

  defp project_attrs(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:slug, params["slug"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def projects(conn, %{"workspace_slug" => slug}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id) do
      projects = Tenancy.list_projects(workspace)

      json(conn, %{
        workspace: render_workspace(workspace),
        projects: Enum.map(projects, &render_project/1)
      })
    else
      # Unknown slug OR a real workspace the caller is not a member of both
      # collapse to 404 — never confirm a workspace exists to a non-member.
      _ -> {:error, :not_found}
    end
  end

  def datasets(conn, %{"workspace_slug" => ws_slug, "project_slug" => proj_slug}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws_slug),
         true <- TenancyAuth.member?(token, workspace.id),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, proj_slug) do
      datasets = Tenancy.list_datasets(project)

      json(conn, %{
        workspace: render_workspace(workspace),
        project: render_project(project),
        datasets: Enum.map(datasets, &render_dataset/1)
      })
    else
      # Unknown workspace/project, or a non-member — collapse to 404, never
      # confirming existence to a caller who cannot see it.
      _ -> {:error, :not_found}
    end
  end

  defp render_workspace(%Tenancy.Workspace{} = ws) do
    %{id: ws.id, slug: ws.slug, name: ws.name}
  end

  defp render_project(%Tenancy.Project{} = project) do
    %{id: project.id, slug: project.slug, name: project.name}
  end

  defp render_dataset(%Tenancy.Dataset{} = dataset) do
    %{id: dataset.id, slug: dataset.slug, name: dataset.name}
  end
end
