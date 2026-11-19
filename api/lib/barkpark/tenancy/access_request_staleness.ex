defmodule Barkpark.Tenancy.AccessRequestStaleness do
  @moduledoc """
  THE staleness rule for access requests (task-018e79d8734a1b08), the one
  place it is decided: a request is stale when the asker's seat changed since
  the ask.

  A request records the seat its asker held when asking: `from_role`, nil for
  no seat. It is stale when, by any door:

    * a seat request's asker now has a seat (seated another way, e.g. an
      invitation accepted);
    * a role request's seat is gone, or holds another role;
    * the seat row was created or last changed AFTER the ask (`inserted_at` /
      `updated_at` later than the request's `inserted_at`), which catches a
      seat removed and re-made with the same role, and a role moved A -> B -> A.

  `Tenancy.AccessRequests` asks this module, then refuses a stale request at
  approve (`:request_stale`), marks it `stale: true` in the admin list, and
  replaces it when the user asks again.

  A row for a missing workspace (`workspace_id: nil`) has no seat to compare
  and is never stale.
  """

  alias Barkpark.Tenancy.AccessRequest
  alias Barkpark.Tenancy.Membership

  @doc "True when `seat` (the asker's seat now, or nil) is not the seat the request recorded."
  @spec stale?(AccessRequest.t(), Membership.t() | nil) :: boolean()
  def stale?(%AccessRequest{workspace_id: nil}, _seat), do: false
  def stale?(%AccessRequest{from_role: nil}, nil), do: false
  def stale?(%AccessRequest{from_role: nil}, %Membership{}), do: true
  def stale?(%AccessRequest{}, nil), do: true

  def stale?(%AccessRequest{from_role: from, inserted_at: asked}, %Membership{} = seat),
    do: seat.role != from or changed_after?(seat, asked)

  # `updated_at` is "when the role last changed": a membership row holds only
  # its principal, role and timestamps, and its only updates are role writes
  # through a changeset (`Members.update_role/4`, SCIM set-role), which Ecto
  # skips when the role is unchanged. `updated_at >= inserted_at`, so it also
  # covers a seat re-made after the ask. The one exception: the admin-run
  # workspace bundle import copies a source's rows with the SOURCE's timestamps
  # (seats and requests together), so it can only miss a change the source
  # itself never had.
  defp changed_after?(%Membership{updated_at: %DateTime{} = changed}, %DateTime{} = asked),
    do: DateTime.compare(changed, asked) == :gt

  defp changed_after?(_seat, _asked), do: false
end
