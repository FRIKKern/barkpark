defmodule Barkpark.Tenancy.AccessRequestStaleness do
  @moduledoc """
  THE staleness rule for access requests (task-018e79d8734a1b08), the one
  place it is decided.

  A request records the seat its asker held when asking: `from_role`, nil for
  no seat. Once the seat is no longer that, by any door (removed, re-roled,
  or seated another way, e.g. an invitation accepted after a seat request),
  the request describes a situation that is gone. `Tenancy.AccessRequests`
  asks this module and then refuses it at approve (`:request_stale`), marks it
  `stale: true` in the admin list, and replaces it when the user asks again.

  A row for a missing workspace (`workspace_id: nil`) has no seat to compare
  and is never stale.
  """

  alias Barkpark.Tenancy.AccessRequest

  @doc "True when the asker's seat role NOW (`nil`: no seat) is not the one the request recorded."
  @spec stale?(AccessRequest.t(), String.t() | nil) :: boolean()
  def stale?(%AccessRequest{workspace_id: nil}, _current_role), do: false
  def stale?(%AccessRequest{from_role: from}, current_role), do: current_role != from
end
