defmodule Mix.Tasks.BarkparkCloud.CreateAdmin do
  @moduledoc """
  Bootstrap the very first admin on the control-plane box — create a User, a
  Team, and an owner membership DIRECTLY through the `Accounts` context. No
  HTTP, no payment, no warm-pool: this is the operator's hand-crank for the
  account that everything else hangs off of, run once on a fresh control plane
  before any public signup exists.

  ## Usage

      mix barkpark_cloud.create_admin EMAIL PASSWORD [TEAM_NAME]

  `TEAM_NAME` is optional — when omitted the team name + slug derive from the
  email local-part (`ada@example.com` → "ada"). Prints the created email, team
  name + slug, and user id on success.

  ## Idempotency

  If the email is already registered the task prints a clear message and exits
  non-zero (`System.halt(1)`) rather than crashing — so a re-run on an
  already-bootstrapped box is a loud, well-behaved no-op, not a stack trace.
  The user→team→membership chain runs inside one transaction, so a half-way
  failure leaves no orphan user or team behind.
  """
  @shortdoc "Create the first control-plane admin (user + team + owner) directly via Accounts"

  use Mix.Task

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Repo

  @impl Mix.Task
  def run(args) do
    # Boot the app so the Repo (and its connection pool) is live — same
    # precondition every data-touching Mix task relies on.
    Mix.Task.run("app.start")

    {email, password, team_name} = parse_args(args)

    case create_admin(email, password, team_name) do
      {:ok, %{user: user, team: team}} ->
        Mix.shell().info("""
        Created admin:
          email:   #{user.email}
          team:    #{team.name} (#{team.slug})
          user_id: #{user.id}
        """)

      {:error, :email_taken} ->
        Mix.shell().error(
          "Email #{inspect(email)} is already registered — nothing to do. " <>
            "Use `mix barkpark_cloud.create_admin` with a fresh email, or sign in."
        )

        exit_error()

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.shell().error("Could not create admin: #{format_errors(changeset)}")
        exit_error()

      {:error, reason} ->
        Mix.shell().error("Could not create admin: #{inspect(reason)}")
        exit_error()
    end
  end

  @doc """
  Create an admin user + team + owner membership directly via the Accounts
  context, in ONE transaction. Returns `{:ok, %{user, team, membership}}`,
  `{:error, :email_taken}` when the email already exists, or
  `{:error, %Ecto.Changeset{}}` on a validation failure.

  Public so a test can drive it against the sandbox repo without spawning a
  Mix process. `team_name` may be `nil` — the team then derives its name + slug
  from the email local-part.
  """
  @spec create_admin(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{user: term(), team: term(), membership: term()}}
          | {:error, :email_taken | Ecto.Changeset.t() | term()}
  def create_admin(email, password, team_name \\ nil)
      when is_binary(email) and is_binary(password) do
    if Accounts.get_user_by_email(email) do
      {:error, :email_taken}
    else
      do_create_admin(email, password, team_name)
    end
  end

  defp do_create_admin(email, password, team_name) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- Accounts.register_user(%{email: email, password: password}),
             {:ok, team} <- create_admin_team(user, team_name),
             {:ok, membership} <- Accounts.add_member(team, user, "owner") do
          %{user: user, team: team, membership: membership}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, payload} ->
        {:ok, payload}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if email_unique_violation?(errors), do: {:error, :email_taken}, else: {:error, changeset}

      {:error, other} ->
        {:error, other}
    end
  end

  # Create the team for the admin: the given team_name (slugified), or a name +
  # slug derived from the email local-part. The slug is deduped against the
  # teams.slug unique by a PRE-INSERT lookup — this runs inside the bootstrap
  # transaction, where a unique violation would abort the whole Postgres
  # transaction (25P02), so we pick a free slug first and insert once.
  defp create_admin_team(user, team_name) do
    {name, base_slug} =
      if is_binary(team_name) and String.trim(team_name) != "" do
        {team_name, slugify(team_name)}
      else
        local = user.email |> String.split("@") |> List.first()
        {local, slugify(local)}
      end

    Accounts.create_team(%{name: name, slug: dedupe_slug(base_slug, 0)})
  end

  defp dedupe_slug(base_slug, attempt) when attempt < 50 do
    candidate = if attempt == 0, do: base_slug, else: "#{base_slug}-#{attempt + 1}"

    if Accounts.get_team_by_slug(candidate),
      do: dedupe_slug(base_slug, attempt + 1),
      else: candidate
  end

  defp dedupe_slug(base_slug, _attempt), do: base_slug

  defp email_unique_violation?(errors) do
    Enum.any?(errors, fn
      {:email, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # name → slug: lowercase, non-alnum → hyphen, trim hyphens; fall back to a
  # short random suffix so a name like "!!!" still yields a valid slug. Mirrors
  # the router's slugify so the bootstrap path and the HTTP path agree.
  defp slugify(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if base == "" do
      "bp-" <>
        (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false) |> String.downcase())
    else
      base
    end
  end

  defp parse_args([email, password]), do: {email, password, nil}
  defp parse_args([email, password, team_name | _]), do: {email, password, team_name}

  defp parse_args(_) do
    Mix.shell().error("Usage: mix barkpark_cloud.create_admin EMAIL PASSWORD [TEAM_NAME]")
    exit_error()
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp exit_error, do: exit({:shutdown, 1})
end
