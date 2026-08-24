defmodule BarkparkWeb.WorkspaceController do
  @moduledoc """
  Membership-scoped LIST surface for the web workspace/project switcher.

    * `GET /api/workspaces` — the Workspaces the bearer token is a MEMBER of
      (via `workspace_memberships`). A workspace the caller has no membership
      row in is NEVER returned — the hard tenant boundary, enforced in the
      `Tenancy.list_workspaces_for/1` query, not here.

    * `GET /api/workspaces/:workspace_slug/projects` — the Projects under that
      workspace, but ONLY when the caller is a member. An unknown slug is 404;
      a member-refused caller on a KNOWN workspace is 403 (see DENIAL SHAPE).
      `:require_token` already 401s an absent/invalid token.

    * `DELETE /api/workspaces/:workspace_slug` — permanently delete a workspace
      and everything scoped to it. Gated on BOTH halves: the `:require_admin`
      pipeline proves the global `admin` permission (the VERB), and the action
      proves `TenancyAuth.workspace_admin?/2` against the workspace the URL
      names (the TENANT). The global permission alone is not enough — it is
      workspace-blind by construction, so on its own it let any admin token
      destroy any tenant's workspace (task-a5636ad31304b23a).

    * `GET /api/workspaces/:workspace_slug/export` — stream that workspace's
      complete bundle. Same two-part gate, same reason: on the global
      permission alone it streamed any tenant's whole workspace to any admin
      token (task-f416f96ef0860f47).

  ## DENIAL SHAPE (charter D13 Tier A, gyldendal field report)

  `projects`, `datasets` and `create_project` used to fold BOTH "no such
  workspace" and "you are not a member of this one" into 404, on the argument
  that the endpoint must never confirm a workspace exists to a non-member.
  `Plugs.ResolveWorkspace` answers the SAME question 403 on the
  `/w/:workspace_slug/p/:project_slug` family — so one membership question got
  two opposite answers depending only on which route family the caller used,
  and the field report hit exactly that: a real refusal read as "your
  workspace does not exist".

  These three actions now agree with the plug. An UNKNOWN slug is still 404; a
  KNOWN workspace the caller is refused is 403. This accepts that
  workspace-slug existence is public, which is already the ratified posture on
  the scoped family. It is deliberately NOT extended to the enumeration-
  sensitive surfaces (query_controller, `Plugs.PublicRead`,
  `Plugs.RequireShareScope`, access/share/auth) — those keep their 404, and
  `PublicRead`'s own moduledoc names the export leak its 404 closed.

  Interior existence stays 404: an unknown PROJECT inside a workspace the
  caller was admitted to is `not_found`, because the caller is a member and
  could list those slugs anyway.

  Token is assigned to `conn.assigns[:api_token]` by the `:require_token`
  pipeline. The JSON envelope mirrors the flat `/v1` controllers — a plain map
  rendered with `json/2`, no separate view module.
  """
  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.Archive
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

  The creator binding is BOTH principals when there are two: the token gets its
  `api_token`-typed owner row, and — when the token names a real owner user —
  that human gets a `"user"`-typed owner row as well, so the person who made
  the workspace can actually reach it as themselves (`Tenancy`
  `create_workspace_with_owner/2`). A token with no owner user (CI/bootstrap)
  writes the token row only; no placeholder membership is ever inserted.
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

  An unknown slug is 404 and a refused caller on a known workspace is 403 —
  the same denial shape as the `projects` LIST action (see DENIAL SHAPE in the
  @moduledoc). 201 + the created project on success; 422 on an invalid /
  duplicate slug.
  """
  def create_project(conn, %{"workspace_slug" => slug} = params) do
    token = conn.assigns[:api_token]

    # D13 Tier A, same law as :projects — unknown slug 404, refused caller 403.
    #
    # `authorize(token, workspace.id, :write)` — NOT `member?/2`. This route's
    # pipeline is [:api, :require_token]: no :require_write, no
    # ResolveWorkspace, so nothing else on the way in checks the token's
    # permissions[]. `member?/2` alone only proves the caller is SOME member;
    # role_for_permissions/1 maps a read-only or a permissions:[] token to the
    # "member" ROLE, which role_permits?/3 grants :write — so a read-only
    # token minted through the very endpoint whose router comment promises
    # "this can never be a privilege-mint" could POST here and get a real
    # Project + production Dataset (arpss-w10-bl-readonly-member-creates-projects).
    # `authorize/3` composes member?/2 with permits?(token, :write) — the SAME
    # single membership load member?/2 already paid for, so this is not a new
    # query, just the conjunct this write was missing.
    case Tenancy.get_workspace_by_slug(slug) do
      %Tenancy.Workspace{} = workspace ->
        if TenancyAuth.authorize(token, workspace.id, :write) == :ok do
          # A changeset error flows to the FallbackController (422).
          with {:ok, project} <-
                 Tenancy.create_project_with_dataset(workspace, project_attrs(params)) do
            conn
            |> put_status(:created)
            |> json(%{project: render_project(project)})
          end
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  DELETE /api/workspaces/:workspace_slug — permanently delete a Workspace and
  everything scoped to it.

  Admin-gated by the router's `:require_admin` pipeline (RequireToken +
  RequireAdmin — a caller without the global `admin` permission is refused 403
  before this action runs) AND bound to the target workspace by this action —
  see TENANT BINDING below. This is the HTTP primitive the destructive keystone
  consumers (eject, backup, abuse-isolation) assume;
  `Tenancy.delete_workspace/1` already exists and is tested but was unreachable
  over HTTP until now.

  Delegates to `Tenancy.delete_workspace/1`, which cascades inside a single
  transaction — media blobs (File.rm + CDN purge via `Media.delete_file/2`),
  documents (both draft and published variants, with plugin hooks), and every
  `workspace_id`-scoped table — rolling the whole thing back on any failure.

  Unknown slug → 404 (`{:error, :not_found}` via the FallbackController). On
  success → 200 echoing the deleted workspace so the caller has immediate,
  concrete confirmation of exactly what was removed.

  ## TENANT BINDING (task-a5636ad31304b23a)

  `:require_admin` proves a GLOBAL permission and never reads a workspace —
  `Auth.has_permission?/2` is literally `permission in (token.permissions ||
  [])`. So the pipeline alone let ANY admin-permissioned token destroy ANY
  workspace on the instance by slug, cascading to media blobs and a CDN purge,
  irreversibly. The verb gate stays where it is; what was missing is the
  binding of that verb to the workspace the URL names, so the action now runs
  `TenancyAuth.workspace_admin?/2` against the RESOLVED target.

  `workspace_admin?/2`, not `member?/2`: deleting a whole workspace is a
  scoped-ADMIN act, and this is the predicate `RequireWorkspaceRole` already
  enforces on every other scoped-admin surface and the one #12701 landed on
  `/v1/shares`. One corridor, one tenancy rule. Nor `authorize/3` — its
  api_token arm ORs membership with the token's GLOBAL `permissions[]`, so a
  global-admin holding a plain `member` row in B would pass it.

  Denial shape follows the shipped path-addressed law (`ResolveWorkspace` 404
  unknown / `RequireWorkspaceRole` 403 unauthorized): an unknown slug is 404,
  a real workspace the caller does not administer is 403.
  """
  def delete(conn, %{"workspace_slug" => slug}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.workspace_admin?(token, workspace.id),
         {:ok, deleted} <- Tenancy.delete_workspace(workspace) do
      json(conn, %{workspace: render_workspace(deleted), deleted: true})
    else
      # Unknown slug (get returns nil) OR delete_workspace resolving :not_found
      # both collapse to 404. A rollback term ({:error, reason}) flows to the
      # FallbackController, which maps it to the structured error envelope.
      nil -> {:error, :not_found}
      # The tenant boundary. Ordered ABOVE the `{:error, _}` catch-all because
      # `false` matches none of the tuple clauses — without its own arm this is
      # a WithClauseError (500), not a denial.
      false -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  GET /api/workspaces/:workspace_slug/export — stream the complete bp-export-v1
  bundle for a workspace as an `application/x-tar` attachment.

  ## TENANT BINDING (task-f416f96ef0860f47)

  Two-part gate, identical to `delete/2`'s and for the identical reason: the
  `:require_admin` pipeline proves the global `admin` permission and never
  reads a workspace, so on its own it streamed ANY tenant's complete bundle to
  ANY admin-permissioned token. The action therefore runs
  `TenancyAuth.workspace_admin?/2` against the resolved target BEFORE any
  bundle is materialized — a denial never spends a COPY, never writes a temp
  tar, and never opens a socket to the caller.

  `workspace_admin?/2` rather than `member?/2` bites harder here than on
  delete: a `profile=full` bundle is the whole workspace INCLUDING the
  secret / credential / PII classes that `profile=dev` exists to scrub, so a
  read-only `member` must not be able to walk out with it. And unlike a
  destructive act there is no undo for a read — remediation cannot take the
  bytes back.

  Denial shape matches `delete/2` and the shipped path-addressed law: unknown
  slug 404, real-but-not-administered 403. The pair is distinguishable to an
  admin caller — the same ACCEPTED signal #12701 recorded on `/v1/shares`,
  and the narrower of the two exposures by a wide margin (the existence of a
  slug, versus the workspace's entire contents).

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

  A COPY that dies mid-dump answers 503 `export_transport_failed` + a retry hint (PDS-D43),
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
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.workspace_admin?(token, workspace.id),
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

      # The tenant boundary (task-f416f96ef0860f47). Needs its own arm: `false`
      # matches none of the tuple clauses below, so without it a denial is a
      # WithClauseError (500) rather than a 403. Ordered before every
      # `{:error, _}` arm for the same reason.
      false ->
        {:error, :forbidden}

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
            code: "export_transport_failed",
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
  POST /api/workspaces/:workspace_slug/import — SPILL the raw tar request body to
  disk and re-import it via `WorkspaceBundle.import_bundle_file/2` (admin-gated).

  BOUNDED (PDS wave 23). The body is streamed to a scratch file in 8 MB chunks
  and refused past a derived ceiling with 413 `import_body_too_large`; the
  engine then extracts to disk and streams each member into COPY. Nothing on
  this path is ever the whole bundle as a binary. Peak is 1x the largest single
  member — NOT constant memory. Before this, `length: 100_000_000` read like a
  limit and was a per-call chunk hint with nothing summing the chunks, so a
  ~2.6 GB bundle materialised whole and `clean` mode had no gate at all.

  Disk is the risk that trade INTRODUCES, so a free-space precondition runs
  BEFORE the spill opens and refuses with 507 `insufficient_disk_space`. When
  the requirement cannot be derived (no Content-Length) or `df` cannot be read,
  the success receipt carries `disk_precondition: %{checked: false, reason: …}`
  rather than implying a check that never ran.

  The bundle is SELF-DESCRIBING (its manifest carries the workspace identity and
  per-table import strategy). Two modes, selected via the `mode` query param:

    * absent / `mode=clean` (default) — restore into an EMPTY scope. The
      string-keyed members (E3/allowlist) re-import idempotently via INSERT ON
      CONFLICT DO NOTHING, but the copy-strategy members (root/E1/E2) assume a
      CLEAN target: a second import over a still-populated workspace
      PK-conflicts. Unchanged behavior.

      RULED, on the record (pds-bl-clean-import-ungated-500): `mode=clean`
      stays UNGATED by `:allow_bundle_import`, deliberately. The gate exists
      to protect a LIVE, populated workspace from convergent writes (PDS-D10)
      — a risk `clean` does not carry: its copy members PK-conflict on any
      populated target and the whole import rolls back atomically, so the
      only workspace `clean` can actually fill is an empty one, which is the
      full-fidelity restore path the Cloud consumers (backup restore, eject,
      rebalance, graduation, migration) depend on. Gating `clean` would break
      every one of them for zero added protection; what the populated-target
      collision NEEDED was honesty, not a gate — it answers the typed 409
      below (the 25P02 blindfold that made it a bare `internal_error` 500 is
      gone, task-63a199c0a0ce2a06), and that refusal is pinned by an
      HTTP-level test.
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
        with_spilled_body(conn, &clean_import/3)

      "merge" ->
        if Application.get_env(:barkpark, :allow_bundle_import, false) do
          with_spilled_body(conn, &merge_import/3)
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
            code: "invalid_import_mode",
            message: "unknown import mode #{inspect(other)} (expected clean or merge)"
          }
        })
    end
  end

  defp clean_import(conn, path, receipt) do
    case WorkspaceBundle.import_bundle_file(path, grant_admin_to: operator_grant(conn)) do
      {:ok, stats} ->
        json(
          conn,
          Map.merge(receipt, %{
            tables: stats.tables,
            total_rows: stats.total_rows,
            provenance: stamp_provenance(stats.manifest)
          })
        )

      {:error, {:blob_path_conflict, info}} ->
        blob_path_conflict(conn, info)

      {:error, other} ->
        import_failed(conn, :clean, other)
    end
  rescue
    e in InvalidBundleError -> invalid_bundle(conn, e)
    e in Postgrex.Error -> constraint_conflict_or_reraise(conn, e, __STACKTRACE__)
    e -> log_import_crash_and_reraise(:clean, e, __STACKTRACE__)
  end

  defp merge_import(conn, path, receipt) do
    case WorkspaceBundle.import_bundle_file(path,
           mode: :merge,
           grant_admin_to: operator_grant(conn)
         ) do
      {:ok, stats} ->
        json(
          conn,
          Map.merge(receipt, %{
            tables: stats.tables,
            total_rows: stats.total_rows,
            mode: "merge",
            provenance: stamp_provenance(stats.manifest)
          })
        )

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

      {:error, {:blob_path_conflict, info}} ->
        blob_path_conflict(conn, info)

      {:error, other} ->
        import_failed(conn, :merge, other)
    end
  rescue
    e in InvalidBundleError -> invalid_bundle(conn, e)
    e in Postgrex.Error -> constraint_conflict_or_reraise(conn, e, __STACKTRACE__)
    e -> log_import_crash_and_reraise(:merge, e, __STACKTRACE__)
  end

  # task-96d8ab2b582818a4 — THE SILENT 500. Round-3 live fire: the on-box merge
  # import answered `internal_error` in 251ms and the captured box journal held
  # NO error line for the request. Two mechanisms can produce exactly that
  # silence, and both are closed here:
  #
  #   1. An `{:error, term}` shape this controller did not pattern-match either
  #      raised CaseClauseError (merge) / MatchError (clean) or fell through to
  #      the FallbackController — whose catch-all renders `internal_error`
  #      WITHOUT logging (Ecto's `Repo.transaction` can legitimately return
  #      `{:error, :rollback}` when a nested transaction rolled back, so this is
  #      a reachable class, not paranoia). `import_failed/3` now LOGS the term
  #      at error level (Plug.RequestId's request_id is already on
  #      Logger.metadata) and answers a NAMED 500 `import_failed` whose message
  #      carries the term — this surface is admin-gated, so naming the cause
  #      leaks nothing.
  #   2. A raise on the import path IS logged — but by Bandit, AFTER the
  #      response is sent, and the support chain's evidence capture snapshots
  #      the journal milliseconds after `bp` exits, so the crash log loses that
  #      race (and a `Bandit.TransportError{error: :closed}` is never logged at
  #      all under the default `log_client_closures: false`). The rescue-all
  #      below logs the exception BEFORE the 500 is rendered, so the box-side
  #      journal tail always carries the true cause — then reraises, keeping
  #      crash semantics (a wide rescue that answered politely would hide
  #      engine bugs behind a retry hint).
  defp import_failed(conn, mode, term) do
    detail = inspect(term, limit: 25, printable_limit: 500)

    Logger.error(
      "WorkspaceController.import(#{mode}): import_bundle returned an unhandled error " <>
        "term — answering a named 500 import_failed instead of a silent internal_error. " <>
        "term=#{detail}"
    )

    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      :internal_server_error,
      "import_failed",
      "workspace bundle import failed: #{detail}"
    )
  end

  # 409 for the cross-tenant blob-path refusal (task-918106d49c62563e). The
  # engine rolled the whole import back at ROW-COPY time because the bundle's
  # media paths are already owned by a resident workspace — and the flat blob
  # keyspace means two owners at one path make the loser's own scoped read serve
  # the winner's bytes. Named + actionable (the colliding paths ride in
  # `details`) rather than the 500 `import_failed` an unmatched term would emit.
  # Emitted from BOTH import arms — clean and merge — because this repo's error
  # emitters are duplicated per arm and a one-arm fix is a half fix.
  defp blob_path_conflict(conn, info) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      :conflict,
      "blob_path_conflict",
      "refusing the import: #{info.count} media blob path(s) in this bundle are already " <>
        "owned by another workspace on this instance. Importing them would make one " <>
        "workspace serve the other's bytes on its own media route. Re-path the colliding " <>
        "rows and retry.",
      %{workspace_id: info.workspace_id, count: info.count, sample: info.sample}
    )
  end

  defp log_import_crash_and_reraise(mode, e, stacktrace) do
    Logger.error(
      "WorkspaceController.import(#{mode}) raised — logged pre-response so the box-side " <>
        "journal capture cannot race it away: " <> Exception.format(:error, e, stacktrace)
    )

    reraise(e, stacktrace)
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
  # (and any check/not-null — the import's FK-drop + DISABLE TRIGGER USER
  # window, task-7889645a51769a36, suppresses neither of those) raises straight
  # through the engine.
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
    # Non-constraint Postgres raise (bad SQL, privilege failure, transport…):
    # still a loud 500 — but log it HERE, before the response, for the same
    # journal-race reason as log_import_crash_and_reraise/3.
    Logger.error(
      "WorkspaceController.import: non-constraint Postgres raise on the import path: " <>
        Exception.format(:error, e, stacktrace)
    )

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

  # ── The bounded import body (PDS wave 23) ────────────────────────────────────
  #
  # What was here before: `read_full_body/2` looped on `:more` accumulating an
  # iolist and ended in `IO.iodata_to_binary/1`. Its `length: 100_000_000` reads
  # as a 100 MB limit and is NOT one — `:length` is a per-CALL chunk hint, and
  # nothing summed the chunks, so there was no ceiling of any kind. The whole
  # ~2.6 GB bundle materialised as one binary BEFORE the engine was reached, and
  # in `clean` mode it was drained with no gate at all.
  #
  # THE CEILING, DERIVED — not rounded, and not a comfortable round number:
  #
  #   * measured on guerrilla 2026-07-27, the four largest tenant tables carry
  #     2,605.5 MiB of COPY text (`mutation_events` 1,310,211,957 B +
  #     `revisions` 1,100,800,292 B + the next two), so today's full-fidelity
  #     bundle is 2,605.5 MiB = 2_732_101_632 B;
  #   * headroom is ONE MORE DOUBLING, which is exactly what this epic OBSERVED
  #     rather than a margin somebody liked: `pg_database_size` went 942 MB
  #     (PDS-D41's measurement) to 2,012,650,519 B over the epic's life.
  #
  # 2 x 2_732_101_632 = 5_464_203_264. The route is admin-gated, so this is a
  # self-foot-gun ceiling, not a DoS control — and it is NOT the disk control
  # either: `Archive.check_free_space/2` below is, because a box can be short of
  # room for a body far under this limit.
  @max_import_body_bytes 5_464_203_264

  # A ceiling nothing can exercise is a ceiling nobody can trust — and no test
  # is going to POST 5.46 GB. `:max_import_body_bytes` overrides the derived
  # default so the refusal is provable at 1 KB (and so an operator on a smaller
  # box can lower it). The DERIVATION above stays the default; this key never
  # changes it silently.
  defp max_import_body_bytes do
    Application.get_env(:barkpark, :max_import_body_bytes, @max_import_body_bytes)
  end

  # Per read_body/2 call. Bounded on purpose: this is the largest single binary
  # the import path ever holds.
  @body_chunk_bytes 8_000_000

  # Spill + extracted members are held together (the body file cannot be deleted
  # until extraction completes), so the requirement is 2x the declared body. The
  # margin covers tar headers and rounding — it does NOT cover the import's
  # `CREATE TEMP TABLE` + COPY, which holds another ~1x the largest member
  # inside Postgres, on the SAME filesystem when the DB is local (guerrilla
  # carries `/`, `/tmp` and `/opt/barkpark` on one). Stated, not hidden.
  @disk_margin_bytes 268_435_456

  # THE OPERATOR GRANT (task-ed7ae8110c7c8b41). An imported workspace arrives on
  # this instance with ZERO valid administrators: the bundle carries only the
  # SOURCE instance's `workspace_memberships` rows, naming principals that do
  # not exist here. Nothing else on the import path writes one, so absent this
  # the operator that just landed the workspace cannot push its blobs
  # (`TenancyAuth.member?/2` -> 404 on PUT /media/blob/*path), re-export it or
  # delete it (`TenancyAuth.workspace_admin?/2` on the two sibling routes) —
  # `bp cloud workspace import --with-blobs` reports the import and then a wall
  # of 404s.
  #
  # The gap PREDATES the tenancy binding (PRs #12824/#12826/#12827); the old
  # workspace-blind `require_admin` was papering over it. NOT fixed with a
  # global-admin bypass in `member?/2`, which would reinstate exactly the
  # workspace-blind hole those PRs closed — this grants ONE principal ONE
  # membership on ONE workspace, at the single moment that workspace enters the
  # instance, and the engine writes it inside the import transaction so a failed
  # import grants nothing.
  #
  # `:require_admin` runs `RequireToken`, so `:api_token` is always assigned on
  # this route and the principal kind is always `"api_token"`; it is threaded
  # explicitly anyway because the type is a discriminator column with an
  # implicit default (see `TenancyAuth.create_membership/4`). The `nil` arm is
  # unreachable through the router and exists so the grant fails CLOSED —
  # granting nothing — rather than raising, if this action is ever mounted on a
  # pipeline that does not resolve a token.
  #
  # DELIBERATELY ABOVE the spill block below, not between it and its `def`.
  # A Sobelow skip annotation binds to the NEXT definition, so defining this
  # function underneath one both STOLE `with_spilled_body`'s waiver (Sobelow
  # then correctly flagged its `File.rm_rf`) and silently handed THIS function
  # a Traversal.FileModule waiver it never needed and nobody had reasoned
  # about. The second half is the dangerous one: an annotation migrating onto
  # unrelated code is how a waiver ends up covering something no one weighed.
  # Inserting a definition between a comment block and its `def` reassigns any
  # annotation in that block — true for skip annotations, `@canonical
  # capability:` markers and credo disable-for-next-line alike. This paragraph
  # deliberately does not spell the annotation token literally, so it cannot be
  # mistaken for one by a scanner or miscounted by a census grep.
  defp operator_grant(conn) do
    case conn.assigns[:api_token] do
      %ApiToken{id: id} when is_binary(id) -> {id, "api_token"}
      _ -> nil
    end
  end

  # Spill the raw tar body to a scratch directory, run `fun`, then always remove
  # the scratch. `fun` is `(conn, bundle_path, receipt_map) -> conn`.
  #
  # File.rm_rf removes exactly the directory `Archive.open_scratch_dir!/0` just
  # created — `spill_dir/0` (operator config) plus System.unique_integer/1. No
  # request input reaches the path, same basis as archive.ex:229-231.
  # sobelow_skip ["Traversal.FileModule"]
  defp with_spilled_body(conn, fun) do
    scratch = Archive.open_scratch_dir!()

    try do
      case disk_precondition(scratch, conn) do
        {:error, {:insufficient_disk_space, info}} ->
          insufficient_disk_space(conn, info)

        {:ok, verdict} ->
          case spill_body(conn, Path.join(scratch, "body.tar")) do
            {:error, :body_too_large, conn, read} ->
              body_too_large(conn, read)

            {:error, {:body_read_failed, reason}, conn, read} ->
              body_read_failed(conn, reason, read)

            {:error, {:spill_write_failed, reason}, conn, read} ->
              spill_write_failed(conn, scratch, reason, read)

            {:ok, path, bytes, conn} ->
              fun.(conn, path, %{
                body_bytes: bytes,
                disk_precondition: describe_disk_verdict(verdict)
              })
          end
      end
    after
      File.rm_rf(scratch)
    end
  end

  # The precondition is derived from Content-Length. When the client sent none
  # (chunked upload) the requirement is underivable, and the honest answer is to
  # SAY the check did not run — in the receipt, in the same breath as the
  # success — never to print a checkmark for a check that never happened.
  defp disk_precondition(dir, conn) do
    case content_length(conn) do
      {:ok, len} ->
        Archive.check_free_space(dir, 2 * len + @disk_margin_bytes)

      :error ->
        {:ok, {:unverified, :no_content_length}}
    end
  end

  defp content_length(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "content-length"),
         {len, ""} <- Integer.parse(String.trim(value)) do
      {:ok, len}
    else
      _ -> :error
    end
  end

  defp describe_disk_verdict({:verified, free}),
    do: %{checked: true, free_bytes: free}

  defp describe_disk_verdict({:unverified, reason}),
    do: %{checked: false, reason: to_string(reason)}

  # Stream the body to `path`, refusing past the derived ceiling. A POST body
  # arrives in multiple chunks, so loop on `:more` — but SUM them, which is the
  # bug this replaces.
  #
  # File.open's `path` is Path.join(scratch, "body.tar"), and `scratch` comes
  # from `Archive.open_scratch_dir!/0` — `spill_dir/0` (operator config) plus
  # System.unique_integer/1. No request input reaches the path, same basis as
  # archive.ex:229-231.
  # sobelow_skip ["Traversal.FileModule"]
  defp spill_body(conn, path) do
    case File.open(path, [:write, :raw, :binary]) do
      {:ok, io} ->
        try do
          stream_body(conn, io, path, 0)
        after
          File.close(io)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open", path: path
    end
  end

  # Three ways this loop can end, and every one of them is NAMED. A multi-GB
  # upload spends minutes on the wire, so the two failure shapes below are not
  # theoretical: `read_body` answers `{:error, reason}` on a client disconnect or
  # a read timeout, and `IO.binwrite/2` answers `{:error, :enospc}` when the
  # filesystem fills mid-spill — the exact hazard extraction-to-disk introduces.
  # Neither may reach the caller as a FunctionClauseError/MatchError 500: an
  # opaque 500 is a failure claim as uninformative as a false success.
  defp stream_body(conn, io, path, written) do
    case Plug.Conn.read_body(conn, length: @body_chunk_bytes) do
      {:ok, chunk, conn} ->
        case write_chunk(io, chunk, written) do
          {:ok, written} -> {:ok, path, written, conn}
          :too_large -> {:error, :body_too_large, conn, written + byte_size(chunk)}
          {:write_failed, reason} -> {:error, {:spill_write_failed, reason}, conn, written}
        end

      {:more, chunk, conn} ->
        case write_chunk(io, chunk, written) do
          {:ok, written} -> stream_body(conn, io, path, written)
          :too_large -> {:error, :body_too_large, conn, written + byte_size(chunk)}
          {:write_failed, reason} -> {:error, {:spill_write_failed, reason}, conn, written}
        end

      {:error, reason} ->
        {:error, {:body_read_failed, reason}, conn, written}
    end
  end

  defp write_chunk(io, chunk, written) do
    total = written + byte_size(chunk)

    if total > max_import_body_bytes() do
      :too_large
    else
      case IO.binwrite(io, chunk) do
        :ok -> {:ok, total}
        {:error, reason} -> {:write_failed, reason}
      end
    end
  end

  defp body_too_large(conn, read) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{
      error: %{
        code: "import_body_too_large",
        message:
          "import body exceeds the #{max_import_body_bytes()}-byte ceiling " <>
            "(read #{read} bytes before refusing). The limit is 2x the measured " <>
            "2,605.5 MiB full-fidelity bundle — one more doubling of the growth this " <>
            "epic observed (942 MB -> 2,012,650,519 B of database).",
        details: %{limit_bytes: max_import_body_bytes(), read_bytes: read}
      }
    })
  end

  # The upload died on the wire. 400 and not 500: nothing on this side failed,
  # and the byte count says exactly how far it got, so an operator can tell a
  # 3-byte handshake failure from a 2 GB upload that timed out at the last mile.
  defp body_read_failed(conn, reason, read) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: "import_body_read_failed",
        message:
          "the import body could not be read to completion (#{inspect(reason)}) after " <>
            "#{read} bytes — the upload was interrupted; nothing was imported. Re-run it.",
        details: %{reason: inspect(reason), read_bytes: read}
      }
    })
  end

  # ENOSPC (or any other write fault) mid-spill. This is the failure mode
  # extraction-to-disk INTRODUCES, so it is answered by name with the free space
  # actually measured at the moment of the failure — never as an opaque 500 that
  # sends an operator looking for a bug in the bundle.
  defp spill_write_failed(conn, scratch, reason, read) do
    free =
      case Archive.free_space(scratch) do
        {:ok, bytes} -> bytes
        {:error, why} -> "unmeasured (#{why})"
      end

    conn
    |> put_status(507)
    |> json(%{
      error: %{
        code: "import_spill_write_failed",
        message:
          "writing the import body to #{scratch} failed (#{inspect(reason)}) after " <>
            "#{read} bytes; free space now reads #{free}. Nothing was imported, and the " <>
            "scratch is removed by this request's `after` clause on the way out. Free " <>
            "space or point BARKPARK_BUNDLE_SPILL_DIR at a larger filesystem.",
        details: %{reason: inspect(reason), written_bytes: read, free_bytes: free}
      }
    })
  end

  defp insufficient_disk_space(conn, info) do
    conn
    |> put_status(507)
    |> json(%{
      error: %{
        code: "insufficient_disk_space",
        message:
          "refusing the import before spilling: #{info.dir} has #{info.free_bytes} bytes " <>
            "free and this import needs #{info.required_bytes} (the body spill and the " <>
            "extracted members are held together). Free space or point " <>
            "BARKPARK_BUNDLE_SPILL_DIR at a larger filesystem.",
        details: info
      }
    })
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

    # Denial shape (charter D13 Tier A): an UNKNOWN slug is 404, a KNOWN
    # workspace the caller is refused is 403 — the same answer
    # `Plugs.ResolveWorkspace` already gives on the /w/:ws/p/:project family.
    # See DENIAL SHAPE in the @moduledoc for why these two must agree.
    #
    # DISPOSITIONED member?-sufficient (arpss-w10-bl-readonly-member-creates-projects
    # criterion 3), deliberately NOT authorize(:read): `permits?(token, :read)`
    # requires "read"/"admin"/"public-read" in permissions[], so a token minted
    # with permissions: [] — no permissions at all — would lose LIST access it
    # holds today under member?/2 alone. That is a narrower, pre-existing
    # question (can a permissionless member enumerate slugs it is already a
    # member of?), not the write-escalation this task proves and fixes at
    # create_project/2 above. Flipping this read gate is a separate, own-merits
    # change — it needs its own caller sweep for who mints permissions: []
    # member tokens today and would be denied a list they can currently see.
    case Tenancy.get_workspace_by_slug(slug) do
      %Tenancy.Workspace{} = workspace ->
        if TenancyAuth.member?(token, workspace.id) do
          projects = Tenancy.list_projects(workspace)

          json(conn, %{
            workspace: render_workspace(workspace),
            projects: Enum.map(projects, &render_project/1)
          })
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def datasets(conn, %{"workspace_slug" => ws_slug, "project_slug" => proj_slug}) do
    token = conn.assigns[:api_token]

    # D13 Tier A on the WORKSPACE only. An unknown PROJECT inside a workspace
    # the caller was admitted to stays 404 (Tier B): project-slug existence is
    # tenant-interior, and the caller who reaches that clause is already a
    # member, so 404 there confirms nothing it could not list anyway.
    #
    # DISPOSITIONED member?-sufficient — same reasoning and same task as
    # `projects/2` above (arpss-w10-bl-readonly-member-creates-projects
    # criterion 3): authorize(:read) would deny a permissions: [] member a
    # list it can see today; that is a separate change from this task's
    # write-escalation fix at create_project/2.
    case Tenancy.get_workspace_by_slug(ws_slug) do
      %Tenancy.Workspace{} = workspace ->
        if TenancyAuth.member?(token, workspace.id) do
          case Tenancy.get_project(ws_slug, proj_slug) do
            %Tenancy.Project{} = project ->
              datasets = Tenancy.list_datasets(project)

              json(conn, %{
                workspace: render_workspace(workspace),
                project: render_project(project),
                datasets: Enum.map(datasets, &render_dataset/1)
              })

            _ ->
              {:error, :not_found}
          end
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :not_found}
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
