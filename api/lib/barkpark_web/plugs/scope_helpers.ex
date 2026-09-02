defmodule BarkparkWeb.ScopeHelpers do
  @moduledoc """
  The single, shared tenancy-scope extractor for the HTTP + LiveView surfaces.

  `scope_opts/1` reads the workspace/project assigns that the routing layer
  set — `current_workspace` / `current_project` — and turns them into the
  keyword opts the `Barkpark.Content` / `Barkpark.Media` query + write paths
  expect (`[workspace_id: ..., project_id: ...]`). It is the seam every
  controller and LiveView that must respect the hard tenant boundary calls,
  so the WHERE-clause scope is never hand-rolled (and silently forgotten) at a
  new call site.

  The assigns are set by:

    * `BarkparkWeb.Plugs.ResolveWorkspace` / `ResolveProject` on the scoped
      `/w/:workspace_slug/...` routes, OR
    * `BarkparkWeb.Plugs.AssignDefaultScope` on the flat back-compat routes,
      which carry the seeded Default workspace/project.

  When neither assign is set (a fresh DB before the Default backfill, or an
  internal caller), the opts are empty and the read/write runs unscoped —
  `Barkpark.Content.Scope` no-ops on a nil `workspace_id`, and the write-side
  `put_scope_attrs` never nulls an existing scope. This nil-safety is the
  contract the previous per-controller copies upheld and is preserved verbatim.

  Two arities cover the two assign carriers:

    * `scope_opts(%Plug.Conn{})` — reads `conn.assigns`. ALSO adds
      `memoize: true` to the opts: a Phoenix request is one process, so the
      per-request memoization in `Barkpark.Content.resolve_read_dataset_id`
      (barkpark-5znv) is safe — the Process dictionary dies with the request.
    * `scope_opts(%Phoenix.LiveView.Socket{})` — reads `socket.assigns`
      (the Studio desk twin). Does NOT set `memoize: true`: a LV process
      lives for the entire session, so a memoized `dataset_id` could outlive
      the underlying dataset row (e.g. workspace cascade-delete) and pin
      reads to a now-deleted id (barkpark-sknf). The fresh-every-call path
      is cheap and stays correct.
    * `scope_opts(%Phoenix.Socket{})` — the CHANNEL/transport socket (a
      DIFFERENT struct from `Phoenix.LiveView.Socket`), used by
      `BarkparkWeb.SearchChannel` for live per-keystroke search. Same
      reasoning as the LiveView socket: a channel process is long-lived, so
      no `memoize: true`.

  The same logic applies to Oban workers and mix tasks: they don't go through
  this helper, never opt in, and therefore stay on the fresh path. Only the
  HTTP request controllers that import `scope_opts: 1` flip the memo on.
  """

  alias Barkpark.Content.CallerContext
  alias Phoenix.LiveView.Socket
  alias Plug.Conn

  @doc """
  Build the tenancy `[workspace_id: ..., project_id: ...]` opts from a conn or
  a LiveView socket. Nil-safe: an absent assign drops the key entirely (never
  emits a `nil` value), so an unscoped caller yields `[]`.

  Conns ALSO get `memoize: true` so the per-request dataset_id resolver can
  collapse its 9-call fan-out; sockets do NOT (see module doc, barkpark-sknf).
  """
  @spec scope_opts(Conn.t() | Socket.t() | Phoenix.Socket.t()) :: keyword()
  def scope_opts(%Conn{assigns: assigns}),
    do: [memoize: true] ++ from_assigns(assigns, :sentinel)

  def scope_opts(%Socket{assigns: assigns}), do: scope_opts_from_assigns(assigns)
  # The channel/transport socket — a distinct struct from the LiveView Socket
  # aliased above; matched fully-qualified so it can't collide with that alias.
  def scope_opts(%Phoenix.Socket{assigns: assigns}), do: scope_opts_from_assigns(assigns)

  @doc """
  `scope_opts/1` for a caller that holds the ASSIGNS MAP but not the socket
  around it — a LiveView render/component function, which Phoenix hands
  `assigns` and nothing else.

  Same extraction, same keys, same socket-side nil handling as
  `scope_opts(%Phoenix.LiveView.Socket{})`; it is the clause that function now
  delegates to, so the two can never drift. It exists so a render function that
  must respect the tenant boundary has a seam to call instead of hand-rolling
  `[workspace_id: ..., project_id: ...]` from the assigns and quietly dropping
  `caller_context` / `grant_scoped` — the failure mode that puts a fenced read
  and an unfenced one in the same module.
  """
  @spec scope_opts_from_assigns(map()) :: keyword()
  def scope_opts_from_assigns(assigns) when is_map(assigns),
    do: from_assigns(assigns, :legacy)

  defp from_assigns(assigns, mode) do
    []
    |> put_workspace_scope(Map.get(assigns, :current_workspace), mode)
    |> put_scope(:project_id, Map.get(assigns, :current_project))
    |> Keyword.put(:caller_context, CallerContext.from_conn(%{assigns: assigns}))
    |> maybe_grant_scoped(assigns)
  end

  # Grant row-narrowing flag (airdrop-grants ag-enforcement, Layer 2). Set ONLY
  # when `ResolveWorkspace` admitted a GRANT-DERIVED caller (never for a member),
  # it tells `Content.Query` to restrict the read to the caller's grant scopes.
  # Absent → Content reads are byte-identical to today.
  defp maybe_grant_scoped(opts, %{grant_scoped_read: true}),
    do: Keyword.put(opts, :grant_scoped, true)

  defp maybe_grant_scoped(opts, _assigns), do: opts

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope(opts, _key, _other), do: opts

  # ── The empty-scope sentinel (task-3e2a70930c6df723) ────────────────────────
  #
  # A REQUEST that resolved no workspace now SAYS so, instead of omitting the
  # key. Omission was the defect: an absent `:workspace_id` conflated two
  # genuinely different intents, and the permissive one won for both —
  #
  #   1. a request arrived and the routing layer resolved no tenant
  #        -> must read the SHARED layer (workspace_id IS NULL) only
  #   2. an internal caller deliberately wants everything
  #        -> must keep reading everything
  #
  # `AssignDefaultScope` passes the conn through untouched when nothing is
  # seeded at slug "default" (its own moduledoc says so), so intent 1 arises in
  # normal operation — and `Content.Scope.scope_to_workspace_or_global/3`'s nil
  # arm then returned the query UNTOUCHED, i.e. every tenant's rows, to an
  # unresolved caller.
  #
  # The sentinel separates the two intents rather than narrowing either. Only a
  # REQUEST can produce `:shared_only` — every internal caller passes `nil` or
  # omits the key, so `Media.list_files/1` (plugins/media/assets.ex),
  # `Media.get_file_by_path/2` (preview.ex) and the deliberately-unscoped
  # assertions in media_test.exs keep today's explicit-global read, untouched.
  #
  # The rule this expresses already exists in the codebase, correctly, in
  # exactly one place: `query_controller.ex`'s counts read reaches for the
  # fail-CLOSED `Scope.scope_to_workspace/3` while every leaking surface reaches
  # for its permissive sibling. This is not a new idea — it is that idea,
  # applied at the one seam every tenant-facing request passes through.
  defp put_workspace_scope(opts, %{id: id}, _mode) when is_binary(id),
    do: Keyword.put(opts, :workspace_id, id)

  # HTTP requests get the sentinel; SOCKETS keep today's omission.
  #
  # Scoped deliberately, not universally. Every door this closes is an HTTP flat
  # route. A LiveView/channel socket resolves its scope by a different path
  # (`BarkparkWeb.Studio.ScopeResolver`) and is long-lived, so handing it the
  # sentinel changed behaviour well outside the leak — it cost 13 of 19
  # full-suite failures, chiefly Studio array-ops losing sight of the very
  # document being edited. Widening to sockets is its own change with its own
  # proof, not a free ride on this one.
  #
  # ── WHY THE SOCKET ARM IS EXCLUDED — the real reason (task-816bafcfbfc2f912) ─
  #
  # This arm is the FOURTH instance of the fail-open empty-scope class: an
  # unresolved tenant scope reaching `Content.Scope.scope_to_workspace_or_global/3`
  # as `nil`, whose nil arm is `scope_to_workspace_global/1` — "returns the query
  # untouched", i.e. every tenant's rows. Its three siblings were CLOSED:
  #
  #   * PR #12826 — 15 flat routes
  #   * PR #12827 — blob write
  #   * task-2e4a3692adf5c565 — flat media surface (anonymous cross-tenant read)
  #
  # The exclusion above is CORRECT. Two of the reasons the paragraph above gives
  # for it are NOT what makes it correct, and an unstated reason is how an
  # exclusion gets re-litigated — so, on the record:
  #
  #   * NOT because `ScopeResolver` makes a socket safe. All three of its arms
  #     terminate in `Tenancy.get_default_workspace()` (studio/scope_resolver.ex),
  #     the same nil this whole class is about, and it takes a CONN, so it does
  #     not cover live navigation at all.
  #   * NOT because a test asserts the omission. NOTHING in the suite asserts the
  #     socket omission in either direction. The canonical spec
  #     `test/barkpark_web/empty_scope_shared_layer_test.exs` has no socket arm,
  #     and the 13-of-19 reds cited above are FIXTURE artifacts:
  #     `test/barkpark_web/live/studio/studio_live_array_op_test.exs` builds its
  #     subject as a bare `%Phoenix.LiveView.Socket{assigns: %{…}}` literal — no
  #     mount, no LiveScope, no StudioChrome — a socket shape production cannot
  #     produce, over a fixture doc created with no `workspace_id`.
  #
  # THE ACTUAL REASON: widening buys nothing, because every socket that can reach
  # `scope_opts/1` unresolved today sits behind a gate whose holder ALREADY has
  # the access. Of the plugin `{:live, …}` routes, only
  # `Barkpark.Plugins.Tickets.InboxLive` imports this module, and it is
  # `auth: :admin` → `live_session :plugin_admin`, whose only reachable principal
  # in the leaking state is a GLOBAL-admin token (LiveAuth's account arm itself
  # requires `get_default_workspace()` to return a workspace, so it halts in
  # exactly that state). A global-admin token already reads instance-wide, so the
  # fall-through moves NO capability.
  #
  # That reason is a statement about who occupies the seat, not about the seat.
  # `live_session :plugin_public` / `:plugin_ops` mount StudioChrome with NO
  # tenant resolver, so a FUTURE plugin LiveView taking that seat would break it —
  # anonymously, on `:plugin_public`. The seat is now GUARDED STRUCTURALLY rather
  # than argued in prose:
  # `test/barkpark_web/plugin_live_session_scope_opts_guard_test.exs` reads the
  # router's live_sessions and each LiveView's BEAM imports chunk, and fails
  # naming any module in those two sessions that calls `scope_opts/1`.
  defp put_workspace_scope(opts, _unresolved, :sentinel),
    do: Keyword.put(opts, :workspace_id, :shared_only)

  defp put_workspace_scope(opts, _unresolved, :legacy), do: opts
end
