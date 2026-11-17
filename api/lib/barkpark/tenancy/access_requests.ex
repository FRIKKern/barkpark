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

  ## How a seat is made

  `approve/4` seats the user through `Members.add_user_member/4`, the path an
  admin uses to seat anyone, with the admin as `actor:` (so the role ceiling
  applies: only an owner grants `owner`) and `consented: true` (the user asked,
  so no invitation round trip). The request is locked, the seat created, the
  request marked approved and one `membership` audit row written in one
  transaction; any failure rolls all of it back.

  ## Limits

  At most one pending request per user per slug (a partial unique index) and
  at most 20 pending per user (`max_pending/0`). The per-user rate limit lives at the HTTP
  door (`BarkparkWeb.AccessRequestController`).
  """

  import Ecto.Query, warn: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.AccessRequest
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Members
  alias Barkpark.Tenancy.Membership

  @max_pending 20

  @doc "How many pending requests one user may hold at once."
  def max_pending, do: @max_pending

  @typedoc "A request as its asker sees it: the slug they sent and the outcome."
  @type own_row :: %{
          id: binary(),
          workspace: String.t(),
          status: String.t(),
          note: String.t() | nil,
          inserted_at: DateTime.t(),
          decided_at: DateTime.t() | nil
        }

  @doc """
  Ask for a seat in the workspace with slug `slug`.

  `{:ok, own_row}` for a new request, a repeat of a pending one, and a slug
  no workspace has. Refusals: `{:error, :email_unconfirmed}` (approving would
  hand the seat to whoever holds the password, not to the email's owner),
  `{:error, :already_member}`, `{:error, :too_many_pending}` and
  `{:error, %Ecto.Changeset{}}` for a malformed slug or a long note.
  """
  @spec request(User.t(), String.t(), String.t() | nil) :: {:ok, own_row()} | {:error, term()}
  def request(%User{confirmed_at: nil}, _slug, _note), do: {:error, :email_unconfirmed}

  def request(%User{id: user_id}, slug, note) when is_binary(slug) do
    slug = String.trim(slug)

    changeset =
      AccessRequest.create_changeset(%{user_id: user_id, workspace_slug: slug, note: note})

    cond do
      not changeset.valid? ->
        {:error, changeset}

      member?(user_id, slug) ->
        {:error, :already_member}

      existing = pending(user_id, slug) ->
        {:ok, own_row(existing)}

      pending_count(user_id) >= @max_pending ->
        {:error, :too_many_pending}

      true ->
        insert(changeset, user_id, slug)
    end
  end

  def request(_user, _slug, _note), do: {:error, :invalid_workspace}

  defp insert(changeset, user_id, slug) do
    ws_id =
      case Tenancy.get_workspace_by_slug(slug) do
        %{id: id} -> id
        nil -> nil
      end

    case changeset |> Ecto.Changeset.put_change(:workspace_id, ws_id) |> Repo.insert() do
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

  defp member?(user_id, slug) do
    case Tenancy.get_workspace_by_slug(slug) do
      %{id: ws_id} -> match?(%Membership{}, TenancyAuth.membership(user_id, ws_id, :user))
      nil -> false
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
    with uuid when is_binary(uuid) <- Repo.uuid_or_nil(id),
         %AccessRequest{user_id: ^user_id, status: "pending"} = row <-
           Repo.get(AccessRequest, uuid),
         {:ok, row} <- Repo.delete(row) do
      {:ok, own_row(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The workspace's pending requests, oldest first: who asked (email and display
  name), their note and when. The admin's view.
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
            where: r.workspace_id == ^ws and r.status == "pending",
            order_by: [asc: r.inserted_at, asc: r.id],
            select: {r, u.email}
          )
          |> Repo.all()

        names = rows |> Enum.map(fn {r, _} -> r.user_id end) |> Accounts.display_names()

        Enum.map(rows, fn {r, email} -> admin_row(r, email, Map.get(names, r.user_id)) end)
    end
  end

  @doc """
  Approve a pending request of THIS workspace and seat the user with `role`.

  `{:ok, %{access_request: row, member: member_row}}`. A request of another
  workspace, a decided one or a missing id answers `{:error, :not_found}` and
  writes nothing. Refusals from `Members.add_user_member/4` (`:owner_required`,
  `:already_member`, a changeset for an unknown role) roll everything back.
  """
  @spec approve(binary(), binary(), String.t(), ApiToken.t() | User.t()) ::
          {:ok, map()} | {:error, term()}
  def approve(workspace_id, id, role, actor) when is_binary(role) do
    Repo.transaction(fn ->
      with %AccessRequest{} = row <- lock_pending(workspace_id, id),
           %User{email: email} = user <- Repo.get(User, row.user_id),
           {:ok, member} <- seat(workspace_id, email, role, actor),
           {:ok, row} <- decide(row, "approved", role, actor),
           :ok <- audit("access_request_approved", row, user, actor, %{"role" => role}) do
        %{access_request: admin_row(row, email, nil), member: member}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
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
        %{access_request: admin_row(row, email, nil)}
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
      inserted_at: r.inserted_at,
      decided_at: r.decided_at
    }
  end

  defp admin_row(%AccessRequest{} = r, email, display_name) do
    %{
      id: r.id,
      user_id: r.user_id,
      email: email,
      display_name: display_name,
      note: r.note,
      status: r.status,
      role: r.role,
      inserted_at: r.inserted_at,
      decided_at: r.decided_at
    }
  end
end
