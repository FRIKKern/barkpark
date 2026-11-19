defmodule Barkpark.Tenancy.AccessRequestRows do
  @moduledoc """
  The two shapes an access request is answered in (task-018e79d8734a1b08):
  the asker's own row and the admin's row. Shaping only: every decision about
  a request, the stale flag included, is made in `Barkpark.Tenancy.AccessRequests`.
  """

  alias Barkpark.Tenancy.AccessRequest

  @typedoc "A request as its asker sees it: the slug they sent and the outcome."
  @type own_row :: %{
          id: binary(),
          workspace: String.t(),
          status: String.t(),
          note: String.t() | nil,
          requested_role: String.t() | nil,
          inserted_at: DateTime.t(),
          decided_at: DateTime.t() | nil
        }

  @doc "The asker's row: nothing about the workspace beyond the slug they sent."
  @spec own_row(AccessRequest.t()) :: own_row()
  def own_row(%AccessRequest{} = r) do
    %{
      id: r.id,
      workspace: r.workspace_slug,
      status: r.status,
      note: r.note,
      requested_role: r.requested_role,
      inserted_at: r.inserted_at,
      decided_at: r.decided_at
    }
  end

  @doc """
  The admin's row. `kind` is `"role"` for a member's request to change their
  role and `"seat"` for a seatless user's. `current_role` is the seat's role
  now (nil without one); `stale` is passed in by the caller.
  """
  @spec admin_row(AccessRequest.t(), String.t() | nil, String.t() | nil, String.t() | nil, boolean()) ::
          map()
  def admin_row(%AccessRequest{} = r, email, display_name, current_role, stale)
      when is_boolean(stale) do
    %{
      id: r.id,
      user_id: r.user_id,
      email: email,
      display_name: display_name,
      note: r.note,
      status: r.status,
      kind: if(is_nil(r.from_role), do: "seat", else: "role"),
      stale: stale,
      requested_role: r.requested_role,
      current_role: current_role,
      role: r.role,
      inserted_at: r.inserted_at,
      decided_at: r.decided_at
    }
  end
end
