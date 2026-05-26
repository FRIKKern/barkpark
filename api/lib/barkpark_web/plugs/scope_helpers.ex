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

  The same logic applies to Oban workers and mix tasks: they don't go through
  this helper, never opt in, and therefore stay on the fresh path. Only the
  HTTP request controllers that import `scope_opts: 1` flip the memo on.
  """

  alias Phoenix.LiveView.Socket
  alias Plug.Conn

  @doc """
  Build the tenancy `[workspace_id: ..., project_id: ...]` opts from a conn or
  a LiveView socket. Nil-safe: an absent assign drops the key entirely (never
  emits a `nil` value), so an unscoped caller yields `[]`.

  Conns ALSO get `memoize: true` so the per-request dataset_id resolver can
  collapse its 9-call fan-out; sockets do NOT (see module doc, barkpark-sknf).
  """
  @spec scope_opts(Conn.t() | Socket.t()) :: keyword()
  def scope_opts(%Conn{assigns: assigns}), do: [memoize: true] ++ from_assigns(assigns)
  def scope_opts(%Socket{assigns: assigns}), do: from_assigns(assigns)

  defp from_assigns(assigns) do
    []
    |> put_scope(:workspace_id, Map.get(assigns, :current_workspace))
    |> put_scope(:project_id, Map.get(assigns, :current_project))
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope(opts, _key, _other), do: opts
end
