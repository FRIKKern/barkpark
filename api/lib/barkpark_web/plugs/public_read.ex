defmodule BarkparkWeb.Plugs.PublicRead do
  @moduledoc """
  Deny-by-default enforcement for the `public-read` permission.

  The plug inspects `conn.assigns[:api_token]` (the existing token pipeline
  assigns under that key — `RequireToken` / `RequireAdmin` both read it).
  Three outcomes:

    * no token → pass-through (anonymous handling applies downstream)
    * token whose permissions do NOT carry `"public-read"` → pass-through
      (read/write/admin unaffected)
    * token whose permissions CARRY `"public-read"` → strict enforcement:

        - allow `GET /v1/data/query/:dataset/:type`
        - allow `GET /v1/data/doc/:dataset/:type/:doc_id`
        - allow `GET /v1/graph` (the whole-dataset corpus graph)
        - reject `?perspective` not in `[nil, "", "published"]` with
          `403 forbidden` / "perspective not allowed"
        - reject types whose schema visibility is not `"public"` with
          `404 not_found`
        - reject every other route/method with `403 forbidden`

  Default posture is DENY on ambiguity.

  ## MEMBERSHIP, never list equality

  The gate is `"public-read" in permissions`, mirroring
  `BarkparkWeb.AnonPerspective.anon_pinned?/1` — NOT `== ["public-read"]`.
  `BarkparkWeb.TokenController` mints from the allowlist `~w(public-read read)`
  over a PUBLIC route, so a caller can ask for `["public-read", "read"]` and a
  list-equality gate would let that token walk straight past the clamp on every
  pipeline. Equality was the bypass; membership closes it.

  ## Error envelope

  Denials go through `BarkparkWeb.ErrorResponse.emit/3`, i.e. the canonical
  `%{"error" => %{"code", "message", "hint"?, "request_id"?}}` body every other
  auth plug emits. The plug used to hand-build a FLAT `%{"error" => "forbidden"}`
  string, which was survivable while it governed two read routes and is not now
  that it governs the whole `:require_token` surface — a client keying on
  `error.code` would have seen a shape change per route.

  ## Every pipeline a token can reach

  The clamp rides the flat read scope (`:api_grant_read`, paths like
  `/v1/data/query/:dataset/:type`), the tenancy-scoped mirror
  (`:shared_docs_api`, paths like `/w/:ws/p/:project/v1/data/query/...`) AND
  `:require_token` — the two-plug pipeline behind every bearer-gated route,
  flat (`[:api, :require_token]`) and scoped (`[:scoped_api, :require_token]`)
  alike. Mounting it there is what closed the live leak: a freshly minted
  public-read token read `GET /v1/data/export/production` (52,208,330 bytes,
  2,500 documents, 129 drafts), `analytics`, `history`, `revision/:dataset/:id`
  and held an open `text/event-stream` on `listen` — none of which is a
  PublicRead-allowed route, all of which rode `:require_token` where the plug
  was absent. Because `allowed_route?/1` whitelists only the two GET data
  routes, and because a non-public-read token no-ops out of `call/2` before any
  of this, the mount denies exactly the public-read tier and leaves every other
  principal byte-identical.

  The scoped prefix `["w", ws, "p", project]` is stripped before matching so a
  public-read token minted for a workspace (the site-spawner BUILD token) is
  clamped on the SCOPED route it fetches over — the scoped route already gates
  workspace membership (necessary) but does NOT pin published-vs-draft within
  the workspace (not sufficient); this plug is the missing clamp.

  ## Scope-accurate visibility

  Mounted at the TAIL of each read pipeline, after `ResolveWorkspace` /
  `ResolveProject` (scoped path) or `AssignDefaultScope` (flat path) have set
  `:current_workspace` / `:current_project`. The schema-visibility check threads
  that resolved scope into `schema_public?/3` so a private type in THIS
  workspace is denied even when a same-named public type exists in another
  workspace or the shared/global layer. Absent scope assigns (e.g. the unit
  test's hand-built conn) fall back to dataset-string resolution — nil-safe.

  ## `/v1/graph` — admitted BY NAME, and its visibility is the controller's

  The corpus graph is the ONE read a statically-built site needs beyond the two
  data routes: with it denied, `templates/search-starter` builds against
  guerrilla emitting `<meta name="bp-doc-id" content=""/>` — the 403 is swallowed
  and the site ships empty. It is admitted here as an exact two-segment path.

  Two consequences the route shape forces:

    * `/v1/graph` carries NO `:type` segment, so there is no schema for this plug
      to gate. `type_gate/1` returns `:none` for it and the plug hands the
      request to `TasksController.graph_corpus/2`, which restricts its OWN type
      list to public-visibility schemas per caller
      (`Content.Schema.public_type_names/1`). A bare allowlist entry WITHOUT that
      controller-side filter would have leaked every private type's titles; a
      bare allowlist entry without `type_gate/1` would have raised
      `FunctionClauseError` — a 500 — on the old two-clause `extract_ds_type/1`.
    * The siblings stay OUT: `/v1/graph/:id` (leaks a draft-only title at the
      default perspective), `/v1/graph/orphans` (an unpaginated full-corpus
      dump), `/v1/graph/dangling` and `/v1/graph/:id/tasks` all fall to the
      catch-all and are denied 403. Deny-by-default means admitting a route is a
      deliberate act, never a side effect of a prefix match.
  """

  import Plug.Conn
  alias Barkpark.Content
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.TasksController.Params

  def init(opts), do: opts

  def call(conn, _opts) do
    if public_read_token?(conn), do: enforce(conn), else: conn
  end

  # MEMBERSHIP, mirroring AnonPerspective.anon_pinned?/1 — a token minted
  # `["public-read", "read"]` by TokenController is still the public tier. The
  # map pattern requires the `:permissions` key and a list value: a token struct
  # without it is NOT clamped (absence of the key is not evidence of the tier).
  #
  # NOTE this predicate is a TIER test, not a visibility clamp, and it must
  # never again be the KEY of one: "is this the one restricted tier?" with an
  # open else-arm fails OPEN for every principal it does not recognise —
  # including a caller with no token at all, which is how the anonymous
  # /finder graph leak shipped (task-336d22b7722ea71e). The corpus
  # schema-visibility clamp now lives in `Content.Schema.visible_schemas/2`,
  # keyed default-narrow on `CallerContext`.
  def public_read_token?(conn) do
    case conn.assigns[:api_token] do
      %{permissions: perms} when is_list(perms) -> "public-read" in perms
      _ -> false
    end
  end

  defp enforce(conn) do
    conn = fetch_query_params(conn)

    cond do
      not allowed_route?(conn) ->
        deny(
          conn,
          {:error, :forbidden},
          "public-read tokens may only read published public documents"
        )

      not allowed_perspective?(conn) ->
        deny(conn, {:error, :forbidden}, "perspective not allowed")

      not schema_public?(conn) ->
        deny(conn, {:error, :not_found}, "not found")

      true ->
        conn
    end
  end

  defp allowed_route?(%{method: "GET", path_info: path}) do
    case data_path(path) do
      ["v1", "data", "query", _ds, _type] -> true
      ["v1", "data", "doc", _ds, _type, _id] -> true
      # The corpus graph ONLY — an EXACT two-segment match. `/v1/graph/:id`,
      # `/v1/graph/orphans`, `/v1/graph/dangling` and `/v1/graph/:id/tasks` are
      # longer paths and fall to the catch-all below (403).
      ["v1", "graph"] -> true
      _ -> false
    end
  end

  defp allowed_route?(_), do: false

  # TWO readers of "which perspective did the caller ask for?" live downstream of
  # this plug, and BOTH must be refused here — a gate that reads one param while
  # the controller reads two is a bypass by construction.
  #
  #   1. the RAW `perspective` string (`AnonPerspective.parse/1`) — the literal
  #      allowlist below, unchanged. It is load-bearing on its own: `raw` maps to
  #      `:published` under `parse_perspective/1`, so only the literal check
  #      refuses `?perspective=raw`.
  #   2. `TasksController.Params.parse_perspective/1` — the graph surface's
  #      parser, which ALSO honours the `?drafts=true|1` ALIAS. That alias is
  #      real and live (`internal/apiclient/client.go` sends
  #      `?drafts=true&direction=both&kinds=blocks`), so removing it would break
  #      a shipped caller; instead this gate now reads THE SAME parser, which is
  #      the only shape that cannot drift apart from what the controller honours.
  #
  # Both clauses are load-bearing and neither subsumes the other: drop (1) and
  # `?perspective=raw` walks through; drop (2) and `?drafts=true` does.
  defp allowed_perspective?(conn) do
    conn.params["perspective"] in [nil, "", "published"] and
      Params.parse_perspective(conn.params) == :published
  end

  # Route-shape aware, and TOTAL. The old shape destructured
  # `extract_ds_type/1`'s two-clause return unconditionally, so admitting any
  # route without a `:type` segment turned the clamp into a 500 (an unmatched
  # function clause is a crash, not a denial). Three outcomes now:
  #
  #   {:type, ds, type} → the schema gate runs (the two data routes)
  #   :none             → no schema to gate; the CONTROLLER owns visibility
  #                       (`/v1/graph`, see the moduledoc)
  #   :unknown          → deny. Unreachable while `allowed_route?/1` enumerates
  #                       exactly these shapes; it exists so the next route
  #                       added to the allowlist without a clause here fails
  #                       CLOSED (404) instead of crashing or leaking.
  defp schema_public?(%{path_info: path} = conn) do
    case type_gate(data_path(path)) do
      {:type, dataset, type} -> Content.schema_public?(type, dataset, scope_opts(conn))
      :none -> true
      :unknown -> false
    end
  end

  # Strip the tenancy-scoped `/w/:ws/p/:project` prefix so the flat and scoped
  # route shapes match the same clause. A flat path passes through untouched.
  defp data_path(["w", _ws, "p", _proj | rest]), do: rest
  defp data_path(path), do: path

  defp type_gate(["v1", "data", "query", ds, type]), do: {:type, ds, type}
  defp type_gate(["v1", "data", "doc", ds, type, _id]), do: {:type, ds, type}
  defp type_gate(["v1", "graph"]), do: :none
  defp type_gate(_), do: :unknown

  # Tenancy opts from the resolved scope assigns (nil-safe): a private type in
  # THIS workspace stays denied even if a same-named public type lives in
  # another workspace or the shared/global layer. Absent assigns → [] → the
  # dataset-string fallback (matches the isolated unit test's bare conn).
  defp scope_opts(%{assigns: assigns}) do
    []
    |> put_scope(:workspace_id, Map.get(assigns, :current_workspace))
    |> put_scope(:project_id, Map.get(assigns, :current_project))
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope(opts, _key, _other), do: opts

  # Delegates to the repo's ONE envelope emitter, `BarkparkWeb.ErrorResponse.emit/3`
  # — the owner of the "error-response-emit" capability (see its own canonical
  # marker at error_response.ex:34): canonical code/status from Content.Errors,
  # hint + request_id stamped, halt included. Never hand-build the body here.
  #
  # The capability slug is deliberately NOT written here in canonical-marker form.
  # A second marker for the same slug is a duplicate the docs-anchors gate rejects
  # by design, and the line below is a private `defp`, which that gate also rejects
  # — a pointer to an owner is not a claim to be one.
  defp deny(conn, reason, message), do: ErrorResponse.emit(conn, reason, message)
end
