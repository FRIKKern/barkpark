defmodule BarkparkWeb.OpsOperatorGate do
  @moduledoc """
  OWNER RULING 2026-10-03 #4 (task-6605a01e0b9f85a6): the cross-workspace ops
  LiveViews — the Tasks board (`/admin/projects`), Bokbasen
  (`/admin/onixedit/bokbasen`) and GitHub ops (`/admin/github`) — are
  OPERATOR-gated on their flat mounts and CLAMPED to the mounted workspace on
  their scoped (`/w/:ws/p/:proj/admin/...`) mounts.

  `LiveAuth :ops` admits any token holding `ops` or `admin`, with no look at
  which workspace that token belongs to, and these three views read and write
  every workspace's rows. So:

    * FLAT mount (no `:current_workspace` assigned by `PluginScopeSession`):
      the principal must pass `RequirePlatformOperator.permits?/1` (an armed
      allowlist names it; unset = single-tenant, every `:ops` principal) AND
      must not be a token BOUND to a workspace other than Default — a tenant's
      `ops` token never reaches the instance-wide view. Checked at mount and
      again on EVERY event (`attach/1` installs the event hook), so a socket
      mounted before the allowlist was armed cannot keep acting.
    * SCOPED mount: `ResolveWorkspace` already proved membership of the URL's
      workspace; `scoped_workspace_id/1` hands each view that id so every read
      and write is clamped to it.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2, attach_hook: 4]

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias BarkparkWeb.Plugs.RequirePlatformOperator

  @refusal "This screen spans every workspace and is reserved for the instance operator. " <>
             "Open it from inside your workspace instead."

  @doc """
  The mount gate, given the LiveView `session`. `{:ok, socket}` to continue
  (with the event hook attached on a flat mount), or `{:halt, socket}` carrying
  the flash + redirect.

  SCOPED is decided by the `PluginScopeSession` session key, which only the
  `/w/:ws/p/:proj` live_sessions set — never by `:current_workspace`, which
  `StudioChrome` also derives on a FLAT mount from the token's own workspace.
  """
  @spec mount(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def mount(socket, session) do
    scoped =
      case {session["scoped_workspace_id"], socket.assigns[:current_workspace]} do
        {id, %{id: id}} when is_binary(id) -> id
        _ -> nil
      end

    socket = Phoenix.Component.assign(socket, :ops_scoped_workspace_id, scoped)

    cond do
      is_binary(scoped) ->
        {:ok, socket}

      flat_operator?(socket) ->
        {:ok, attach_hook(socket, :ops_operator_gate, :handle_event, &event/3)}

      true ->
        {:halt, socket |> put_flash(:error, @refusal) |> redirect(to: "/studio")}
    end
  end

  @doc "The mounted workspace id on a scoped mount; nil on the flat mount."
  @spec scoped_workspace_id(Phoenix.LiveView.Socket.t() | map()) :: binary() | nil
  def scoped_workspace_id(%{assigns: assigns}), do: scoped_workspace_id(assigns)

  def scoped_workspace_id(assigns) when is_map(assigns) do
    case Map.get(assigns, :ops_scoped_workspace_id) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  @doc "True when the socket's principal may hold the instance-wide (flat) view."
  @spec flat_operator?(Phoenix.LiveView.Socket.t()) :: boolean()
  def flat_operator?(socket) do
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]
    RequirePlatformOperator.permits?(principal) and not foreign_bound?(principal)
  end

  defp foreign_bound?(%ApiToken{workspace_id: ws_id}) when is_binary(ws_id) do
    case Tenancy.get_default_workspace() do
      %{id: ^ws_id} -> false
      _ -> true
    end
  end

  defp foreign_bound?(_principal), do: false

  defp event(_event, _params, socket) do
    if flat_operator?(socket),
      do: {:cont, socket},
      else: {:halt, put_flash(socket, :error, @refusal)}
  end
end
