defmodule BarkparkCloud.Registry.Site do
  @moduledoc """
  A hosted website running co-located with a Barkpark instance — the runtime
  half of the cloud-website-hosting story. Belongs to a `Barkpark` (the box it
  runs on) and through it to a `Team`.

  The `(team_id, slug)` pair is unique — a Team names each of its sites once.
  `domains` is an array because one site can answer on the apex, www, and any
  number of custom hostnames; the array carries a GIN index so the on-demand
  TLS `/v1/tls/ask` gate can answer "is this domain registered?" in O(1).

  `env_encrypted` is `Vault.encrypt/1`'d JSON; the plaintext is never persisted.
  Setting env always replaces the whole blob.

  Two scale modes:

    * `always_on` — the runtime container stays warm for instant response.
    * `zero`     — agent stops idle containers; a wakeup handler boots on first
                   request. Cheaper, cold-start latency.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/
  @domain_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

  @frameworks ~w(nextjs nuxt sveltekit astro static)
  @scale_modes ~w(always_on zero)

  # owner/repo — the only shape GitHub uses for repos, e.g. "FRIKKern/barkpark".
  # Two segments separated by one slash; each segment is letters/digits/_/-/.
  @github_repo_format ~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/

  schema "sites" do
    field :name, :string
    field :slug, :string
    field :framework, :string, default: "nextjs"
    field :domains, {:array, :string}, default: []
    field :env_encrypted, :binary
    field :scale_mode, :string, default: "always_on"
    field :port, :integer
    field :current_deployment_id, :binary_id

    # P7 github-webhook: a GitHub push to `github_branch` of `github_repo`
    # triggers /v1/webhooks/github/:site_id, which verifies the HMAC with the
    # encrypted secret and enqueues a Deployment with git_ref = the pushed sha.
    field :github_repo, :string
    field :github_branch, :string, default: "main"
    field :github_webhook_secret_encrypted, :string

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark
    belongs_to :team, BarkparkCloud.Accounts.Team

    has_many :deployments, BarkparkCloud.Registry.Deployment

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def frameworks, do: @frameworks
  def scale_modes, do: @scale_modes
  def domain_format, do: @domain_format

  @doc """
  Changeset for creating / updating a Site. `name`, `slug`, `barkpark_id`, and
  `team_id` are required. `domains` are normalised to lowercase and validated
  against the public-suffix-ish DNS shape; an invalid domain in the list is a
  validation error on the whole changeset.
  """
  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :name,
      :slug,
      :framework,
      :domains,
      :env_encrypted,
      :scale_mode,
      :port,
      :current_deployment_id,
      :github_repo,
      :github_branch,
      :github_webhook_secret_encrypted,
      :barkpark_id,
      :team_id
    ])
    |> validate_required([:name, :slug, :barkpark_id, :team_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_inclusion(:framework, @frameworks)
    |> validate_inclusion(:scale_mode, @scale_modes)
    |> validate_github_repo()
    |> validate_length(:github_branch, max: 255)
    |> normalize_domains()
    |> validate_domains()
    |> assoc_constraint(:barkpark)
    |> assoc_constraint(:team)
    |> unique_constraint([:team_id, :slug],
      name: :sites_team_slug_unique_idx,
      message: "a site with this slug already exists in this team"
    )
  end

  defp validate_github_repo(changeset) do
    case get_change(changeset, :github_repo) do
      nil ->
        changeset

      "" ->
        changeset

      repo when is_binary(repo) ->
        if Regex.match?(@github_repo_format, repo) do
          changeset
        else
          add_error(changeset, :github_repo, "must be in 'owner/repo' form")
        end
    end
  end

  @doc """
  Narrow changeset for the on-box agent / control-plane runtime that allocates
  the runtime port and stamps the live deployment pointer. Cannot rename or
  re-team the site.
  """
  def runtime_changeset(site, attrs) do
    site
    |> cast(attrs, [:port, :current_deployment_id])
  end

  defp normalize_domains(changeset) do
    case get_change(changeset, :domains) do
      nil ->
        changeset

      domains when is_list(domains) ->
        normed =
          domains
          |> Enum.map(&normalize_domain/1)
          |> Enum.uniq()

        put_change(changeset, :domains, normed)
    end
  end

  defp normalize_domain(d) when is_binary(d) do
    d |> String.downcase() |> String.trim() |> String.trim_trailing(".")
  end

  defp normalize_domain(other), do: other

  defp validate_domains(changeset) do
    validate_change(changeset, :domains, fn :domains, list ->
      bad =
        Enum.reject(list, fn d ->
          is_binary(d) and String.length(d) <= 253 and Regex.match?(@domain_format, d)
        end)

      case bad do
        [] -> []
        [b | _] -> [domains: "invalid domain: #{inspect(b)}"]
      end
    end)
  end
end
