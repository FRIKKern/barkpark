defmodule Barkpark.Tenancy.AccessRequestStaleness do
  @moduledoc """
  THE staleness rule for access requests (task-018e79d8734a1b08), the one
  place it is decided: a request is fresh only while the asker's seat is the
  seat they held when asking.

  Every write to a seat row, by any writer, gives it a new `seat_change`
  stamp, a random uuid set by the database (trigger
  `workspace_memberships_seat_change`). A request stores the asker's seat
  stamp at ask time, nil for no seat. It is fresh only while:

    * a seat request's asker still has no seat, or
    * a role request's asker holds a seat whose stamp is the stored one.

  Anything else is stale: a seat removed, re-made, re-roled (also A -> B -> A),
  or written back by a workspace import. An import does not carry access
  requests; people ask again.

  A row for a missing workspace (`workspace_id: nil`) is fresh while its asker
  has no seat there, and stale once a member asks, so the member's ask
  replaces it.

  `Tenancy.AccessRequests` asks this module, then refuses a stale request at
  approve (`:request_stale`), marks it `stale: true` in the admin list, and
  replaces it when the user asks again.
  """

  alias Barkpark.Tenancy.AccessRequest
  alias Barkpark.Tenancy.Membership

  @doc "True when `seat` (the asker's seat now, or nil) is not the seat the request recorded."
  @spec stale?(AccessRequest.t(), Membership.t() | nil) :: boolean()
  def stale?(%AccessRequest{seat_change: nil}, nil), do: false

  def stale?(%AccessRequest{seat_change: s}, %Membership{seat_change: s}) when is_binary(s),
    do: false

  def stale?(%AccessRequest{}, _seat), do: true
end
