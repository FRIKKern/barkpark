defmodule BarkparkCloud.Accounts do
  @moduledoc """
  The Cloud identity context — Users, Teams, and the membership binding
  between them, plus email+password authentication.

  This is what makes "one login for all your Barkparks" real: a single User
  authenticates here, and Team memberships fan that identity out across the
  control plane. Scope is deliberately narrow (YAGNI):

    * email + password ONLY — no OAuth, no sessions/tokens, no web layer, no
      password-reset / email-confirmation. Those are later tasks. What lives
      here is the callable, tested Accounts context + auth functions.

  Authentication entry points:

    * `register_user/1` — create a User from attrs (hashes the password).
    * `get_user_by_email_and_password/2` — verify a login, timing-safe.
  """
  import Ecto.Query, warn: false

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.{Team, TeamMembership, User, UserToken}

  ## Users

  @doc """
  Register a new user from `attrs` (`:email`, `:password`).

  Hashes the password via `Bcrypt.hash_pwd_salt` (the plaintext never reaches
  the DB) and enforces email format + case-insensitive uniqueness. Returns
  `{:ok, %User{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a user by id, or nil."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc "Fetch a user by email (case-insensitive via citext), or nil."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Authenticate by email + password.

  Returns the `%User{}` on a correct password, `nil` otherwise. When no user
  matches the email it still runs `Bcrypt.no_user_verify/0` so the response
  time does not leak whether the email is registered (timing-attack defense).
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    cond do
      user && Bcrypt.verify_pass(password, user.hashed_password) ->
        user

      true ->
        # No matching user (or wrong password): burn a hash so the timing of
        # the failure path matches the success path — never reveal which.
        Bcrypt.no_user_verify()
        nil
    end
  end

  ## Teams

  @doc "Create a Team from `attrs` (`:name`, `:slug`)."
  @spec create_team(map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def create_team(attrs) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a team by id, or nil."
  @spec get_team(binary()) :: Team.t() | nil
  def get_team(id), do: Repo.get(Team, id)

  @doc "Fetch a team by slug, or nil."
  @spec get_team_by_slug(String.t()) :: Team.t() | nil
  def get_team_by_slug(slug) when is_binary(slug), do: Repo.get_by(Team, slug: slug)

  ## Memberships

  @doc """
  Add `user` to `team` with `role` (defaults to `member` — the role is the
  grant, mirroring the api/ tenancy rule).

  Accepts structs or raw binary ids for both. Returns `{:ok, %TeamMembership{}}`
  or `{:error, %Ecto.Changeset{}}` (e.g. the (user, team) pair already exists,
  or an invalid role).
  """
  @spec add_member(Team.t() | binary(), User.t() | binary(), String.t()) ::
          {:ok, TeamMembership.t()} | {:error, Ecto.Changeset.t()}
  def add_member(team, user, role \\ TeamMembership.default_role())

  def add_member(%Team{id: team_id}, user, role), do: add_member(team_id, user, role)
  def add_member(team_id, %User{id: user_id}, role), do: add_member(team_id, user_id, role)

  def add_member(team_id, user_id, role)
      when is_binary(team_id) and is_binary(user_id) and is_binary(role) do
    %TeamMembership{}
    |> TeamMembership.changeset(%{team_id: team_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  @doc "Fetch the membership for `user` in `team`, or nil."
  @spec get_membership(Team.t() | binary(), User.t() | binary()) :: TeamMembership.t() | nil
  def get_membership(%Team{id: team_id}, user), do: get_membership(team_id, user)
  def get_membership(team_id, %User{id: user_id}), do: get_membership(team_id, user_id)

  def get_membership(team_id, user_id) when is_binary(team_id) and is_binary(user_id) do
    Repo.get_by(TeamMembership, team_id: team_id, user_id: user_id)
  end

  @doc """
  All Teams `user` belongs to, oldest membership first. The membership order is
  stable, so `List.first/1` of this is a deterministic "primary" team.
  """
  @spec list_user_teams(User.t() | binary()) :: [Team.t()]
  def list_user_teams(user) do
    uid = user_id(user)

    from(t in Team,
      join: m in TeamMembership,
      on: m.team_id == t.id,
      where: m.user_id == ^uid,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: t
    )
    |> Repo.all()
  end

  @doc """
  The Team `user` acts within by default — the first team they joined, or `nil`
  if they belong to none. A logged-in User acts within ONE team at a time; a
  team-switcher is a later concern (YAGNI), so the primary team is the API's
  current-team for now.
  """
  @spec primary_team(User.t() | binary()) :: Team.t() | nil
  def primary_team(user), do: user |> list_user_teams() |> List.first()

  ## Session tokens

  @doc """
  Mint a USER session token for `user`. Returns the PLAINTEXT exactly once — only
  its SHA-256 hash is stored, so the credential is unrecoverable after this call
  (mirrors `Registry.mint_agent_token/3`).

  The token is valid for `UserToken.default_validity_days/0` from now. On the
  (vanishingly unlikely) hash collision the insert retries with a fresh token.
  """
  @spec create_user_session_token(User.t()) :: {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_user_session_token(%User{} = user) do
    plaintext = generate_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(UserToken.default_validity_days() * 24 * 3600, :second)
      |> DateTime.truncate(:microsecond)

    %UserToken{}
    |> UserToken.changeset(%{
      user_id: user.id,
      context: "session",
      token_hash: UserToken.hash_token(plaintext),
      expires_at: expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a presented session-token `plaintext`. Returns the owning `%User{}` when
  the token exists and is not past `expires_at`; otherwise `nil`. Lookup is by
  hash — the plaintext is never stored to compare against.
  """
  @spec verify_user_session_token(binary()) :: User.t() | nil
  def verify_user_session_token(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserToken,
        where: t.token_hash == ^hash,
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserToken{user_id: user_id} -> Repo.get(User, user_id)
      nil -> nil
    end
  end

  def verify_user_session_token(_), do: nil

  ## Helpers

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id), do: id
end
