defmodule BarkparkWeb.Studio.BoundAdminWrite do
  @moduledoc """
  The dataset-bound admin write rule for Studio's LiveView admin actions: the
  same rule `BarkparkWeb.Plugs.DatasetBoundAdminWrites` applies to the HTTP
  admin writes, on the same predicate
  (`DatasetBoundAdminReads.bound_admin?/1`) and the same switch
  (`DatasetBoundAdminReads.mode/0`).

  A handler that changes members, access grants, shares, tokens (chat hosts,
  connector chat tokens, SCIM tokens) or organization policy asks
  `refused?/1` first, with the principal it acts as:

    * not a bound admin token (an unbound token, an account session): the
      handler runs as before and nothing is recorded.
    * `:enforce`: `refuse/1` puts the plug's refusal sentence in an error flash
      and the handler writes nothing.
    * `:observe`: the handler runs as before. After a write that succeeded it
      calls `observe/5`: one log line and one audit row, the same shape as the
      plug's (category `access`, action `DatasetBoundAdminWrites.action/0`, the
      token id, the surface, the route and the workspace the write touched).
      Never the token, its hash or its label. A refused or failed write
      records nothing.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Plugs.{DatasetBoundAdminReads, DatasetBoundAdminWrites}

  @doc "True when `principal` is a bound admin token and the rule is in `:enforce`."
  @spec refused?(term()) :: boolean()
  def refused?(principal), do: DatasetBoundAdminReads.refused?(principal)

  @doc "The refusal: an error flash, nothing else."
  @spec refuse(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refuse(socket), do: Phoenix.LiveView.put_flash(socket, :error, message())

  @doc "The refusal sentence (the plug's, `DatasetBoundAdminWrites.message/0`)."
  @spec message() :: String.t()
  def message,
    do:
      gettext(
        "this token is bound to one dataset and cannot change workspace members, access, tokens or secrets"
      )

  @doc """
  Record one write that succeeded, when `principal` is a bound admin token.
  `route` names the LiveView and event (`"live StudioLive.access-revoke"`).
  A no-op for every other principal. Never raises.
  """
  @spec observe(term(), String.t(), String.t(), binary() | nil, map()) :: :ok
  def observe(principal, surface, route, workspace_id, metadata \\ %{}) do
    if DatasetBoundAdminReads.bound_admin?(principal),
      do: DatasetBoundAdminWrites.record(principal.id, surface, route, workspace_id, metadata)

    :ok
  end
end
