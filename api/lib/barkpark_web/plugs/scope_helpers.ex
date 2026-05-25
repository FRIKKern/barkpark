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

    * `scope_opts(%Plug.Conn{})` — reads `conn.assigns`.
    * `scope_opts(%Phoenix.LiveView.Socket{})` — reads `socket.assigns`
      (the Studio desk twin).
  """

  alias Phoenix.LiveView.Socket
  alias Plug.Conn

  @doc """
  Build the tenancy `[workspace_id: ..., project_id: ...]` opts from a conn or
  a LiveView socket. Nil-safe: an absent assign drops the key entirely (never
  emits a `nil` value), so an unscoped caller yields `[]`.
  """
  @spec scope_opts(Conn.t() | Socket.t()) :: keyword()
  def scope_opts(%Conn{assigns: assigns}), do: from_assigns(assigns)
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
