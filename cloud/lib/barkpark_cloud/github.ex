defmodule BarkparkCloud.GitHub do
  @moduledoc """
  The GitHub App context (gh-2) — connect/disconnect a team's GitHub installation
  and the read side the dashboard renders, plus the config-selected client SEAM
  the deploy flow will call to act on the team's repos.

  ## HUMAN-LAST / fail-closed

  No real GitHub App credential exists in the repo. `configured?/0` reports
  whether the App id + private key are wired (env, prod-only); the connect
  endpoint refuses with a 503 `feature_not_configured` when they are absent. The
  app BOOTS regardless (plugins-off philosophy — GitHub off is a valid state);
  nothing here raises on missing credentials. In dev/test the client is the
  in-memory `GitHub.Fake`, so the whole connect/disconnect/state path — and its
  cross-team isolation — is provable at €0.

  ## Store

  One `GitHub.Installation` per team (unique on `team_id`). The installation
  handle is stored ENCRYPTED (`Registry.Vault`), the account login plaintext for
  display. `record_installation/2` VALIDATES the id through the client seam
  (`get_installation/1`) before persisting — a forged/uninstalled id never lands.
  """
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.GitHub.Installation
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo

  @doc """
  The configured `GitHub.Client`. Resolved at call time (config-at-call-time, so
  a runtime.exs override wins). Defaults to `GitHub.Fake` — a missing config is
  the safe in-memory double, never a real GitHub call.
  """
  @spec client() :: module()
  def client do
    config() |> Keyword.get(:client, BarkparkCloud.GitHub.Fake)
  end

  @doc """
  Is the GitHub App wired to actually talk to GitHub right now? True only when
  BOTH the App id and the RSA private key are configured (env, prod). The connect
  endpoint gates on this and 503s `feature_not_configured` when false — the
  feature is flagged off, not half-broken.
  """
  @spec configured?() :: boolean()
  def configured? do
    cfg = config()
    present?(cfg[:app_id]) and present?(cfg[:private_key])
  end

  @doc """
  The GitHub App install URL the dashboard's "Connect GitHub" affordance points
  at, derived from the App slug (`config … app_slug`). `nil` when no slug is
  configured, so the SPA renders a graceful not-configured state instead of a
  dead link.
  """
  @spec install_url() :: String.t() | nil
  def install_url do
    case config()[:app_slug] do
      slug when is_binary(slug) and slug != "" ->
        "https://github.com/apps/#{slug}/installations/new"

      _ ->
        nil
    end
  end

  @doc "The team's installation row, or `nil`. Team-scoped — never crosses teams."
  @spec installation_for(Team.t() | binary()) :: Installation.t() | nil
  def installation_for(team) do
    tid = team_id(team)
    Repo.one(from i in Installation, where: i.team_id == ^tid)
  end

  @doc "Whether the team has a connected GitHub installation."
  @spec connected?(Team.t() | binary()) :: boolean()
  def connected?(team), do: not is_nil(installation_for(team))

  @doc """
  The non-secret connection state for the dashboard:
  `%{connected: bool, account_login: login | nil}`. NEVER exposes the encrypted
  installation handle.
  """
  @spec connection_state(Team.t() | binary()) :: %{
          connected: boolean(),
          account_login: String.t() | nil
        }
  def connection_state(team) do
    case installation_for(team) do
      nil -> %{connected: false, account_login: nil}
      %Installation{account_login: login} -> %{connected: true, account_login: login}
    end
  end

  @doc """
  Record (or replace) a team's GitHub installation from the `installation_id` the
  App-install redirect handed back. VALIDATES the id through the client seam
  (`get_installation/1`) first — an unknown / uninstalled id yields
  `{:error, :installation_not_found}` and nothing is written. On success the
  handle is stored ENCRYPTED and the account login (from GitHub) plaintext, ONE
  row per team (a re-connect replaces the existing row).

  Returns `{:ok, %Installation{}}`, `{:error, :installation_not_found}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec record_installation(Team.t() | binary(), String.t() | integer()) ::
          {:ok, Installation.t()}
          | {:error, :installation_not_found}
          | {:error, Ecto.Changeset.t()}
  def record_installation(team, installation_id) do
    tid = team_id(team)

    case client().get_installation(installation_id) do
      {:ok, %{account_login: login}} ->
        attrs = %{
          team_id: tid,
          account_login: login,
          installation_id_encrypted: Vault.encrypt(to_string(installation_id))
        }

        base = installation_for(tid) || %Installation{}

        base
        |> Installation.changeset(attrs)
        |> Repo.insert_or_update()

      {:error, _reason} ->
        {:error, :installation_not_found}
    end
  end

  @doc """
  Disconnect a team's GitHub installation. Returns `:ok` when a row was removed,
  `{:error, :not_found}` when the team had none. Team-scoped.
  """
  @spec disconnect(Team.t() | binary()) :: :ok | {:error, :not_found}
  def disconnect(team) do
    case installation_for(team) do
      nil ->
        {:error, :not_found}

      %Installation{} = installation ->
        {:ok, _} = Repo.delete(installation)
        :ok
    end
  end

  @doc """
  Decrypt a stored installation's handle back to plaintext (server-side only —
  for making GitHub API calls). Returns `{:ok, id}` or `:error` (tampered
  ciphertext fails closed). NEVER call this on a response path.
  """
  @spec reveal_installation_id(Installation.t()) :: {:ok, binary()} | :error
  def reveal_installation_id(%Installation{installation_id_encrypted: ciphertext}),
    do: Vault.decrypt(ciphertext)

  @doc """
  The repos the team's GitHub App installation can access — the "Import Git
  Repository" picker's data source (gh-4). Resolves the team's installation,
  reveals its handle server-side, and lists through the client seam.

  Returns `{:ok, [repo_map]}` (each a `%{"full_name" => …, "private" => …}` as
  GitHub shapes them), `{:error, :no_installation}` when the team hasn't
  connected GitHub, `{:error, :installation_unreadable}` when the stored handle
  is tampered, or `{:error, term}` from the seam.
  """
  @spec list_repos_for(Team.t() | binary()) ::
          {:ok, [map()]}
          | {:error, :no_installation}
          | {:error, :installation_unreadable}
          | {:error, term}
  def list_repos_for(team) do
    case installation_for(team) do
      nil ->
        {:error, :no_installation}

      %Installation{} = inst ->
        with {:ok, id} <- reveal_installation_id(inst),
             {:ok, repos} <- client().list_repos(id) do
          {:ok, repos}
        else
          :error -> {:error, :installation_unreadable}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Register the push webhook for a Site ON GITHUB (gh-4 — the Vercel "Import Git
  Repository" moment). Resolves the team's installation, VALIDATES that
  `repo_full_name` is one the installation can actually reach (an attacker
  cannot wire a webhook onto a repo the team doesn't control), then registers a
  push webhook delivering to `webhook_url`, signed with `secret`, through the
  client seam.

  Idempotent by design: the `webhook_url` is the site's stable inbound endpoint,
  so a re-connect of the same repo→site replaces the same hook rather than
  minting a duplicate (the `Fake` models GitHub's one-hook-per-(repo,url) upsert;
  `Real` create-or-updates by url). The caller persists the repo/branch/secret
  link separately (`Registry.set_site_github/4`) so the secret we register here
  is exactly the one the inbound handler verifies.

  Returns `{:ok, hook}`, `{:error, :no_installation}`,
  `{:error, :repo_not_in_installation}`, `{:error, :installation_unreadable}`,
  or `{:error, term}` from the seam.
  """
  @spec register_site_webhook(Team.t() | binary(), String.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :no_installation}
          | {:error, :repo_not_in_installation}
          | {:error, :installation_unreadable}
          | {:error, term}
  def register_site_webhook(team, repo_full_name, webhook_url, secret)
      when is_binary(repo_full_name) and is_binary(webhook_url) and is_binary(secret) do
    case installation_for(team) do
      nil ->
        {:error, :no_installation}

      %Installation{} = inst ->
        with {:ok, id} <- reveal_installation_id(inst),
             {:ok, repos} <- client().list_repos(id),
             true <- repo_present?(repos, repo_full_name) do
          client().register_webhook(id, repo_full_name, webhook_url, secret)
        else
          false -> {:error, :repo_not_in_installation}
          :error -> {:error, :installation_unreadable}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  ## Internals ───────────────────────────────────────────────────────────────

  defp repo_present?(repos, full_name) when is_list(repos) do
    Enum.any?(repos, fn repo -> repo_full_name(repo) == full_name end)
  end

  defp repo_full_name(%{"full_name" => name}), do: name
  defp repo_full_name(%{full_name: name}), do: name
  defp repo_full_name(_), do: nil

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  defp present?(value) when is_integer(value), do: true
  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])
end
