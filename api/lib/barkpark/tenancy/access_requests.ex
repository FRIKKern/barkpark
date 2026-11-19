defmodule Barkpark.Tenancy.AccessRequests do
  @moduledoc """
  Access requests (task-1b99ba8512bb758e): a signed-in user with no seat in a
  workspace asks for one; an owner or admin of that workspace approves it with
  a role or denies it.

  ## What the asker learns

  Nothing about the workspace beyond the slug they sent. `request/3` answers
  the same row shape whether the slug names a workspace or not, and a second
  ask while one is pending answers the pending row. The row for a missing
  workspace is stored with `workspace_id: nil`, so the asker's own list looks
  the same either way and no admin ever sees it. The one different answer is
  `{:error, :already_member}`, and only a member gets it: a member already
  knows the workspace exists.

  ## A member asks for a higher role (task-018e79d8734a1b08)

  A member may name a `role` that ranks above the one they hold
  (`Tenancy.Auth.role_rank/2`). The row records the role they held as
  `from_role`, which marks it a role change. A same-or-lower role answers
  `{:error, :role_not_higher}`, a name the workspace does not have
  `{:error, :unknown_role}`, and no role at all `{:error, :already_member}`
  as before. For a seatless asker `role` is a hint, checked for shape only:
  validating it against the workspace's roles would tell a stranger which
  custom roles exist.

  Approving a role change goes through `Members.update_role/4`, the path an
  admin uses to change any seat's role, with the approver as `actor:` (so its
  ceiling and last-owner rail apply), never through a hand-written update.
  Refused with nothing changed: a stale request (`:request_stale`), a granted
  role that does not rank above the current one (`:role_not_higher`), and an
  approver who is the asker or a token the asker owns (`:self_approval`).

  ## Stale requests

  A request records the seat its asker held (`from_role`, nil for none). Once
  the seat is no longer that, by any door (removed, re-roled, seated another
  way), the request is stale: `stale?/2` decides it, in this module only.
  Approve refuses it, the admin list marks it `stale: true`, and asking again
  replaces it instead of answering the old row.

  ## How a seat is made

  `approve/4` seats the user through `Members.add_user_member/4`, the path an
  admin uses to seat anyone, with the admin as `actor:` (so the role ceiling
  applies: only an owner grants `owner`) and `consented: true` (the user asked,
  so no invitation round trip). The request is locked, the seat created, the
  request marked approved and one `membership` audit row written in one
  transaction; any failure rolls all of it back. A pending invitation for the
  same seat is deleted in that transaction too.

  ## Limits

  At most one pending request per user per slug (a partial unique index) and
  at most 20 pending per user (`max_pending/0`). The per-user rate limit
  lives at the HTTP door (`BarkparkWeb.AccessRequestController`).
  """

  import Ecto.Query, warn: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.AccessRequest
  alias Barkpark.Tenancy.Invitation
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Members
  alias Barkpark.Tenancy.Membership

  @max_pending 20

  # The role a seat request is approved with when the approver names none.
  @default_seat_role "member"

  @doc "How many pending requests one user may hold at once."
  def max_pending, do: @max_pending

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

  @doc """
  Ask for a seat in the workspace with slug `slug`, or, as a member, for the
  higher `role`.

  `{:ok, own_row}` for a new request, a repeat of a pending one (the pending
  row is the answer; withdraw it to ask for something else; a STALE pending
  one is replaced instead), and a slug no workspace has. Refusals: `{:error, :email_unconfirmed}` (approving would
  hand the seat to whoever holds the password, not to the email's owner),
  `{:error, :already_member}` (a member naming no role),
  `{:error, :role_not_higher}`, `{:error, :unknown_role}`,
  `{:error, :too_many_pending}` and `{:error, %Ecto.Changeset{}}` for a
  malformed slug or role or a long note.
  """
  @spec request(User.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, own_row()} | {:error, term()}
  def request(user, slug, note, role \\ nil)

  def request(%User{confirmed_at: nil}, _slug, _note, _role), do: {:error, :email_unconfirmed}

  def request(%User{id: user_id}, slug, note, role)
      when is_binary(slug) and (is_nil(role) or is_binary(role)) do
    slug = String.trim(slug)

    changeset =
      AccessRequest.create_changeset(%{
        user_id: user_id,
        workspace_slug: slug,
        note: note,
        requested_role: role
      })

    if changeset.valid? do
      ws = Tenancy.get_workspace_by_slug(slug)

      case ws && TenancyAuth.membership(user_id, ws.id, :user) do
        %Membership{} = seat -> member_request(changeset, user_id, slug, ws, seat, role)
        _ -> seat_request(changeset, user_id, slug, ws)
      end
    else
      {:error, changeset}
    end
  end

  def request(_user, _slug, _note, _role), do: {:error, :invalid_workspace}

  defp seat_request(changeset, user_id, slug, ws) do
    {live, stale} = pending_for(user_id, slug, nil)

    cond do
      live -> {:ok, own_row(live)}
      over_cap?(user_id, stale) -> {:error, :too_many_pending}
      true -> insert(changeset, user_id, slug, ws, stale)
    end
  end

  # A member knows the workspace exists, so the role is checked for real here.
  defp member_request(changeset, user_id, slug, ws, %Membership{role: current}, role) do
    {live, stale} = pending_for(user_id, slug, current)

    cond do
      is_nil(role) ->
        {:error, :already_member}

      role not in TenancyAuth.valid_role_names(ws.id) ->
        {:error, :unknown_role}

      not outranks?(role, current, ws.id) ->
        {:error, :role_not_higher}

      live ->
        {:ok, own_row(live)}

      over_cap?(user_id, stale) ->
        {:error, :too_many_pending}

      true ->
        changeset
        |> Ecto.Changeset.put_change(:from_role, current)
        |> insert(user_id, slug, ws, stale)
    end
  end

  defp outranks?(role, current, ws_id),
    do: TenancyAuth.role_rank(role, ws_id) > TenancyAuth.role_rank(current, ws_id)

  # The pending request for this slug, split by `stale?/2` against the seat
  # the asker holds now: `{live, nil}`, `{nil, stale}` or `{nil, nil}`.
  defp pending_for(user_id, slug, current_role) do
    case pending(user_id, slug) do
      nil -> {nil, nil}
      row -> if stale?(row, current_role), do: {nil, row}, else: {row, nil}
    end
  end

  # A stale row is about to be replaced, so it does not count against the cap.
  defp over_cap?(user_id, stale),
    do: pending_count(user_id) - if(stale, do: 1, else: 0) >= @max_pending

  # Insert the new request, replacing a stale pending one in the same
  # transaction (the one-pending-per-slug index would refuse it otherwise).
  defp insert(changeset, user_id, slug, ws, stale) do
    ws_id = ws && ws.id

    Repo.transaction(fn ->
      if stale,
        do:
          Repo.delete_all(
            from r in AccessRequest, where: r.id == ^stale.id and r.status == "pending"
          )

      case changeset |> Ecto.Changeset.put_change(:workspace_id, ws_id) |> Repo.insert() do
        {:ok, row} -> row
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
    |> case do
      {:ok, row} ->
        {:ok, own_row(row)}

      # Two asks raced past `pending/2`: the other one's row is the answer.
      {:error, %Ecto.Changeset{} = cs} ->
        case pending(user_id, slug) do
          %AccessRequest{} = row -> {:ok, own_row(row)}
          nil -> {:error, cs}
        end
    end
  end

  defp pending(user_id, slug) do
    Repo.one(
      from r in AccessRequest,
        where: r.user_id == ^user_id and r.workspace_slug == ^slug and r.status == "pending"
    )
  end

  defp pending_count(user_id) do
    Repo.aggregate(
      from(r in AccessRequest, where: r.user_id == ^user_id and r.status == "pending"),
      :count
    )
  end

  @doc "The user's own requests, newest first, as `own_row`s."
  @spec list_for_user(binary()) :: [own_row()]
  def list_for_user(user_id) when is_binary(user_id) do
    case Repo.uuid_or_nil(user_id) do
      nil ->
        []

      uid ->
        from(r in AccessRequest,
          where: r.user_id == ^uid,
          order_by: [desc: r.inserted_at, desc: r.id]
        )
        |> Repo.all()
        |> Enum.map(&own_row/1)
    end
  end

  @doc """
  Withdraw (delete) one of the user's own PENDING requests. Someone else's, a
  decided one or a missing id all answer `{:error, :not_found}`.
  """
  @spec withdraw(binary(), binary()) :: {:ok, own_row()} | {:error, :not_found}
  def withdraw(user_id, id) do
    # One statement: the status is checked by the DELETE itself, so an approve
    # or deny that commits first leaves nothing for it to match.
    with uuid when is_binary(uuid) <- Repo.uuid_or_nil(id),
         uid when is_binary(uid) <- Repo.uuid_or_nil(user_id),
         {1, [row]} <-
           Repo.delete_all(
             from(r in AccessRequest,
               where: r.id == ^uuid and r.user_id == ^uid and r.status == "pending",
               select: r
             )
           ) do
      {:ok, own_row(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The workspace's pending requests, oldest first: who asked (email and display
  name), their note, the role they asked for, the role they hold now (`nil`
  for a seatless asker) and when. The admin's view.
  """
  @spec list_pending(binary()) :: [map()]
  def list_pending(workspace_id) when is_binary(workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      ws ->
        rows =
          from(r in AccessRequest,
            join: u in User,
            on: u.id == r.user_id,
            left_join: m in Membership,
            on:
              m.workspace_id == r.workspace_id and m.principal_type == "user" and
                m.principal_id == r.user_id,
            where: r.workspace_id == ^ws and r.status == "pending",
            order_by: [asc: r.inserted_at, asc: r.id],
            select: {r, u.email, m.role}
          )
          |> Repo.all()

        names = rows |> Enum.map(fn {r, _, _} -> r.user_id end) |> Accounts.display_names()

        Enum.map(rows, fn {r, email, current} ->
          admin_row(r, email, Map.get(names, r.user_id), current)
        end)
    end
  end

  @doc """
  Approve a pending request of THIS workspace.

  A seat request seats the user with `role` (`nil` means `"member"`) through
  `Members.add_user_member/4`. A member's role request changes their seat to
  `role` (`nil` means the role they asked for) through `Members.update_role/4`.
  Either way the approver is the `actor:`, so the roster's role ceiling holds.

  `{:ok, %{access_request: row, member: member_row}}`. A request of another
  workspace, a decided one or a missing id answers `{:error, :not_found}` and
  writes nothing. Every other refusal rolls everything back: `:self_approval`,
  `:request_stale`, `:role_not_higher`, `:unknown_role`, and the roster's own
  (`:owner_required`, `:already_member`, a changeset for an unknown role).
  """
  @spec approve(binary(), binary(), String.t() | nil, ApiToken.t() | User.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def approve(workspace_id, id, role, actor) when is_nil(role) or is_binary(role) do
    Repo.transaction(fn ->
      with %AccessRequest{} = row <- lock_pending(workspace_id, id),
           %User{email: email} = user <- Repo.get(User, row.user_id),
           :ok <- not_self(row, actor),
           seat <- lock_seat(row),
           false <- stale?(row, seat_role(seat)) || {:error, :request_stale},
           {:ok, member, granted, meta} <- grant(row, seat, email, role, actor),
           {:ok, _} <- drop_invitation(row),
           {:ok, row} <- decide(row, "approved", granted, actor),
           :ok <- audit("access_request_approved", row, user, actor, meta) do
        %{access_request: admin_row(row, email, nil, member.role), member: member}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
    |> tap(fn
      # The roster call announces before this transaction commits; say it
      # again once the new role is visible to the re-check.
      {:ok, _} -> Members.announce_seats_changed(workspace_id)
      _ -> :ok
    end)
  end

  # The asker never decides their own request: not as themselves and not
  # through a token they own (whose seat may outrank their own).
  defp not_self(%AccessRequest{user_id: uid}, %User{id: uid}), do: {:error, :self_approval}

  defp not_self(%AccessRequest{user_id: uid}, %ApiToken{owner_user_id: uid}),
    do: {:error, :self_approval}

  defp not_self(_row, _actor), do: :ok

  # A seat request (not stale, so no seat now): the normal seating path.
  defp grant(%AccessRequest{from_role: nil} = row, _seat, email, role, actor) do
    granted = role || @default_seat_role

    with {:ok, member} <- seat(row.workspace_id, email, granted, actor),
         do: {:ok, member, granted, %{"role" => granted}}
  end

  # A role change (not stale, so the seat still holds `from_role`, locked for
  # the rest of the transaction): changed through the roster's own path.
  defp grant(%AccessRequest{} = row, %Membership{role: current}, _email, role, actor) do
    granted = role || row.requested_role
    ws = row.workspace_id

    with true <- is_binary(granted) || {:error, :unknown_role},
         true <- granted in TenancyAuth.valid_role_names(ws) || {:error, :unknown_role},
         true <- outranks?(granted, current, ws) || {:error, :role_not_higher},
         {:ok, member} <-
           Members.update_role(ws, %{type: :user, id: row.user_id}, granted, actor: actor) do
      {:ok, member, granted, %{"role" => granted, "from_role" => current}}
    end
  end

  # THE staleness rule (task-018e79d8734a1b08), the one place it is decided:
  # a request records the seat its asker held when asking (`from_role`, nil
  # for none). Once the seat is no longer that (removed, re-roled, or seated
  # by another path) the request describes a situation that is gone. Approve
  # refuses it, the admin list marks it, and asking again replaces it. A row
  # for a missing workspace has no seat to compare and is never stale.
  defp stale?(%AccessRequest{workspace_id: nil}, _current_role), do: false
  defp stale?(%AccessRequest{from_role: from}, current_role), do: current_role != from

  defp seat_role(%Membership{role: role}), do: role
  defp seat_role(nil), do: nil

  defp lock_seat(%AccessRequest{workspace_id: nil}), do: nil

  defp lock_seat(%AccessRequest{workspace_id: ws, user_id: uid}) do
    Repo.one(
      from m in Membership,
        where: m.workspace_id == ^ws and m.principal_type == "user" and m.principal_id == ^uid,
        lock: "FOR UPDATE"
    )
  end

  @doc """
  Deny a pending request of THIS workspace. No seat is made; the asker sees
  `denied`. Same `{:error, :not_found}` rule as `approve/4`.
  """
  @spec deny(binary(), binary(), ApiToken.t() | User.t()) :: {:ok, map()} | {:error, term()}
  def deny(workspace_id, id, actor) do
    Repo.transaction(fn ->
      with %AccessRequest{} = row <- lock_pending(workspace_id, id),
           %User{email: email} = user <- Repo.get(User, row.user_id),
           {:ok, row} <- decide(row, "denied", nil, actor),
           :ok <- audit("access_request_denied", row, user, actor, %{}) do
        %{access_request: admin_row(row, email, nil, nil)}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  defp lock_pending(workspace_id, id) do
    with ws when is_binary(ws) <- Repo.uuid_or_nil(workspace_id),
         uuid when is_binary(uuid) <- Repo.uuid_or_nil(id) do
      Repo.one(
        from r in AccessRequest,
          where: r.id == ^uuid and r.workspace_id == ^ws and r.status == "pending",
          lock: "FOR UPDATE"
      )
    end
  end

  # The normal seating path. `{:invited, _}` cannot come back with
  # `consented: true`; if it ever did, nothing would be seated, so refuse.
  defp seat(workspace_id, email, role, actor) do
    case Members.add_user_member(workspace_id, email, role, actor: actor, consented: true) do
      {:ok, {:reclaimed, member}} -> {:ok, member}
      {:ok, {:invited, _}} -> {:error, :not_seated}
      {:ok, member} -> {:ok, member}
      {:error, reason} -> {:error, reason}
    end
  end

  # A pending invitation for the same seat is spent once the user is seated
  # (accepting it would only answer `:already_member`); the roster drops it.
  defp drop_invitation(%AccessRequest{workspace_id: ws, user_id: uid}) do
    {deleted, _} =
      Repo.delete_all(from i in Invitation, where: i.workspace_id == ^ws and i.user_id == ^uid)

    {:ok, deleted}
  end

  defp decide(row, status, role, actor) do
    row
    |> AccessRequest.decide_changeset(%{
      status: status,
      role: role,
      decided_by: actor_ref(actor),
      decided_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  # Inside the transaction: an audit row that cannot be written takes the
  # decision down with it (`Barkpark.Audit.emit/1`).
  defp audit(action, row, user, actor, metadata) do
    {actor_type, actor_id} = actor_fields(actor)

    case Barkpark.Audit.emit(%{
           category: "membership",
           action: action,
           subject: user.id,
           actor_type: actor_type,
           actor_id: actor_id,
           workspace_id: row.workspace_id,
           metadata: Map.put(metadata, "access_request_id", row.id)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp actor_fields(%ApiToken{id: id}), do: {"token", id}
  defp actor_fields(%User{id: id}), do: {"user", id}
  defp actor_fields(_), do: {nil, nil}

  defp actor_ref(%ApiToken{id: id}), do: "api_token:" <> id
  defp actor_ref(%User{id: id}), do: "user:" <> id
  defp actor_ref(_), do: nil

  defp own_row(%AccessRequest{} = r) do
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

  # `kind` is "role" for a member's request to change their role, "seat" for
  # a seatless user's request. `current_role` is the seat's role now; `stale`
  # says the seat is no longer what the request recorded (approve refuses it).
  defp admin_row(%AccessRequest{} = r, email, display_name, current_role) do
    %{
      id: r.id,
      user_id: r.user_id,
      email: email,
      display_name: display_name,
      note: r.note,
      status: r.status,
      kind: if(is_nil(r.from_role), do: "seat", else: "role"),
      stale: r.status == "pending" and stale?(r, current_role),
      requested_role: r.requested_role,
      current_role: current_role,
      role: r.role,
      inserted_at: r.inserted_at,
      decided_at: r.decided_at
    }
  end
end
