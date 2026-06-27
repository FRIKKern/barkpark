defmodule BarkparkCloud.Registry do
  @moduledoc """
  The Barkparks registry context — the metadata store behind "one dashboard of
  all your Barkparks", and the seam the warm-pool (cloud-6) registers a new live
  server into.

  Everything here is Team-scoped: a Barkpark belongs to a Team, and the list /
  lookup functions take a Team so one Team can never see another's instances.

  Four moving parts:

    * `Barkpark`   — the registry row (one per instance). `register_barkpark/2`
      / `upsert_barkpark/2` create-or-update it (the warm-pool's write path);
      `upsert_health/2` lands the agent's health report.
    * `Provider`   — a connected cloud account. `connect_provider/3` encrypts the
      account token at rest (`Vault`) before storing it.
    * `AgentEvent` — the append-only agent event stream (`record_event/3`,
      `recent_events/2`).
    * `AgentToken` — revocable agent bearer tokens. `mint_agent_token/3` returns
      the plaintext ONCE and stores only its hash; `verify_agent_token/1` returns
      the Barkpark for a valid (unrevoked, unexpired) token; `revoke_agent_token/1`.
  """
  import Ecto.Query, warn: false

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Registry.{
    AgentEvent,
    AgentToken,
    Barkpark,
    Deployment,
    Provider,
    ProvisionJob,
    Site,
    Vault
  }

  # The warm-pool defaults a provision job carries to the Go worker when the
  # Barkpark row doesn't pin a region / server_type of its own. These mirror the
  # warm-pool's own defaults (internal/cli/cloud) — Nuremberg, the cax11 ARM box.
  @default_region "nbg1"
  @default_server_type "cax11"


  ## Barkparks

  @doc """
  Register a Barkpark for `team` from `attrs`. The Team is taken from the first
  argument (struct or id) — `attrs` need not (and should not) carry `:team_id`.

  Returns `{:ok, %Barkpark{}}` or `{:error, %Ecto.Changeset{}}` (e.g. the slug
  already exists in this team).
  """
  @spec register_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def register_barkpark(team, attrs) do
    %Barkpark{}
    |> Barkpark.changeset(put_team_id(attrs, team))
    |> Repo.insert()
  end

  @doc """
  Create-or-update a Barkpark for `team`, keyed on `(team_id, slug)`. This is
  the warm-pool's idempotent write path: registering the same slug twice updates
  the existing row instead of failing the unique constraint.

  Requires a `:slug` in `attrs`.
  """
  @spec upsert_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def upsert_barkpark(team, attrs) do
    attrs = put_team_id(attrs, team)
    team_id = attrs |> Map.get(:team_id) || Map.get(attrs, "team_id")
    slug = attrs |> Map.get(:slug) || Map.get(attrs, "slug")

    case team_id && slug && Repo.get_by(Barkpark, team_id: team_id, slug: slug) do
      %Barkpark{} = existing ->
        existing
        |> Barkpark.changeset(attrs)
        |> Repo.update()

      _ ->
        register_barkpark(team, attrs)
    end
  end

  @doc "List a Team's Barkparks, newest first. Scoped — never crosses teams."
  @spec list_barkparks(Team.t() | binary()) :: [Barkpark.t()]
  def list_barkparks(team) do
    team_id = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^team_id)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a Barkpark by id, or nil."
  @spec get_barkpark(binary()) :: Barkpark.t() | nil
  def get_barkpark(id), do: Repo.get(Barkpark, id)

  @doc """
  Land an agent health report onto `barkpark`. Accepts a subset of
  `%{health_status, version, git_commit, agent_status, last_seen_at}` — the
  narrow `health_changeset` means a health report can't rename the Barkpark or
  move it between Teams.
  """
  @spec upsert_health(Barkpark.t(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def upsert_health(%Barkpark{} = barkpark, attrs) do
    barkpark
    |> Barkpark.health_changeset(attrs)
    |> Repo.update()
  end

  ## Provisioning jobs — the queue bridging this control plane and the Go worker

  @doc """
  Enqueue a `pending` provision job for `barkpark` — the async half of go-live.
  After the pay + registry write, this is what hands the work to the off-box Go
  warm-pool provisioner. Returns `{:ok, %ProvisionJob{}}`.
  """
  @spec enqueue_provision_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_provision_job(barkpark) do
    %ProvisionJob{}
    |> ProvisionJob.changeset(%{barkpark_id: barkpark_id(barkpark), status: "pending"})
    |> Repo.insert()
  end

  @doc """
  Atomically claim the oldest `pending` provision job for `claim_token`. This is
  the worker's pull, and it is the canonical Postgres job-claim: one transaction
  that SELECTs the oldest pending row `FOR UPDATE SKIP LOCKED LIMIT 1` and
  UPDATEs that same locked row to `claimed`. The row-level lock makes the claim
  self-evidently race-safe — a second worker polling concurrently SKIPs the
  locked row and grabs the next pending one, so two workers can never claim the
  same job (no CAS retry loop needed; the database serializes the contention).

  Returns `{job, barkpark}` for the claimed job, or `nil` when no job is pending
  (the worker's 204 / sleep path).
  """
  @spec claim_next_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_job(claim_token) when is_binary(claim_token) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    result =
      Repo.transaction(fn ->
        # Lock the oldest pending row; concurrent claimers SKIP LOCKED past it.
        locked =
          from(j in ProvisionJob,
            where: j.status == "pending",
            order_by: [asc: j.inserted_at, asc: j.id],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"
          )

        case Repo.one(locked) do
          nil ->
            nil

          %ProvisionJob{} = job ->
            {:ok, claimed} =
              job
              |> ProvisionJob.changeset(%{
                status: "claimed",
                claim_token: claim_token,
                claimed_at: now
              })
              |> Repo.update()

            {claimed, Repo.get(Barkpark, claimed.barkpark_id)}
        end
      end)

    case result do
      {:ok, claim} -> claim
      {:error, _} -> nil
    end
  end

  @doc """
  Mark provision job `id` succeeded with the provisioned host `ip`, and flip the
  owning Barkpark to live: `health_status: "up"`, `host: ip`, and
  `agent_status: "offline"` (the on-box agent hasn't phoned home yet — that's a
  separate signal the agent report later flips to online).

  Returns `{:ok, %ProvisionJob{}}`, or `{:error, :not_found}` when no job has
  that id.
  """
  @spec succeed_job(binary(), String.t()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def succeed_job(id, ip) when is_binary(id) and is_binary(ip) do
    case Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      %ProvisionJob{} = job ->
        with {:ok, job} <-
               job
               |> ProvisionJob.changeset(%{status: "succeeded", result_ip: ip})
               |> Repo.update() do
          if barkpark = Repo.get(Barkpark, job.barkpark_id) do
            _ = upsert_health(barkpark, %{health_status: "up", host: ip, agent_status: "offline"})
          end

          {:ok, job}
        end
    end
  end

  @doc """
  Mark provision job `id` failed with `error`. The owning Barkpark stays in its
  provisioning state (health_status unchanged) — a fail is terminal here (no
  retries/backoff, YAGNI), and a human (or a re-launch) is the recovery path.

  Returns `{:ok, %ProvisionJob{}}`, or `{:error, :not_found}`.
  """
  @spec fail_job(binary(), String.t()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def fail_job(id, error) when is_binary(id) do
    case Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      %ProvisionJob{} = job ->
        job
        |> ProvisionJob.changeset(%{status: "failed", error: error})
        |> Repo.update()
    end
  end

  @doc "The warm-pool default region a provision job carries when unset."
  @spec default_region() :: String.t()
  def default_region, do: @default_region

  @doc "The warm-pool default server_type a provision job carries when unset."
  @spec default_server_type() :: String.t()
  def default_server_type, do: @default_server_type

  ## Agent events

  @doc """
  Append an event of `type` (`health`/`status`/`backup`/`tls`) with `payload`
  (a map) to `barkpark`'s stream.
  """
  @spec record_event(Barkpark.t() | binary(), String.t(), map()) ::
          {:ok, AgentEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(barkpark, type, payload \\ %{}) do
    %AgentEvent{}
    |> AgentEvent.changeset(%{
      barkpark_id: barkpark_id(barkpark),
      type: type,
      payload: payload
    })
    |> Repo.insert()
  end

  @doc "Most-recent `limit` events for `barkpark`, newest first."
  @spec recent_events(Barkpark.t() | binary(), pos_integer()) :: [AgentEvent.t()]
  def recent_events(barkpark, limit \\ 50) do
    bp_id = barkpark_id(barkpark)

    AgentEvent
    |> where([e], e.barkpark_id == ^bp_id)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  ## Providers

  @doc """
  Connect a cloud `Provider` of `kind` (`hetzner`/etc.) for `team`, storing the
  account `token` ENCRYPTED at rest (`Vault.encrypt/1`). The plaintext token is
  never persisted. `opts` may carry `:label`.

  Returns `{:ok, %Provider{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec connect_provider(Team.t() | binary(), String.t(), binary(), keyword()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def connect_provider(team, kind, token, opts \\ []) when is_binary(token) do
    %Provider{}
    |> Provider.changeset(%{
      team_id: team_id(team),
      kind: kind,
      label: Keyword.get(opts, :label),
      encrypted_token: Vault.encrypt(token)
    })
    |> Repo.insert()
  end

  @doc "List a Team's connected providers, newest first. Scoped — never crosses teams."
  @spec list_providers(Team.t() | binary()) :: [Provider.t()]
  def list_providers(team) do
    tid = team_id(team)

    Provider
    |> where([p], p.team_id == ^tid)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  Decrypt a stored provider token back to plaintext. Returns `{:ok, token}` or
  `:error` (tampered ciphertext fails closed). Call-site sugar over
  `Vault.decrypt/1` so consumers don't reach into the schema field directly.
  """
  @spec reveal_provider_token(Provider.t()) :: {:ok, binary()} | :error
  def reveal_provider_token(%Provider{encrypted_token: ciphertext}),
    do: Vault.decrypt(ciphertext)

  ## Agent tokens

  @doc """
  Mint a revocable agent token for `barkpark` with `scope`. Returns
  `{:ok, plaintext, %AgentToken{}}` — the PLAINTEXT is shown ONCE here and never
  stored; only its SHA-256 hash is persisted.

  `opts`:
    * `:expires_at` — a `DateTime` after which the token is invalid (default: no
      expiry).
  """
  @spec mint_agent_token(Barkpark.t() | binary(), String.t(), keyword()) ::
          {:ok, binary(), AgentToken.t()} | {:error, Ecto.Changeset.t()}
  def mint_agent_token(barkpark, scope, opts \\ []) do
    plaintext = generate_token()

    attrs = %{
      barkpark_id: barkpark_id(barkpark),
      scope: scope,
      token_hash: AgentToken.hash_token(plaintext),
      expires_at: Keyword.get(opts, :expires_at)
    }

    case %AgentToken{} |> AgentToken.changeset(attrs) |> Repo.insert() do
      {:ok, token} -> {:ok, plaintext, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a presented `plaintext` agent token. Returns the owning `%Barkpark{}`
  when the token exists, is not revoked, and is not past `expires_at`; otherwise
  `nil`. Lookup is by hash — the plaintext is never stored to compare against.
  """
  @spec verify_agent_token(binary()) :: Barkpark.t() | nil
  def verify_agent_token(plaintext) when is_binary(plaintext) do
    hash = AgentToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in AgentToken,
        where: t.token_hash == ^hash,
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %AgentToken{barkpark_id: barkpark_id} -> Repo.get(Barkpark, barkpark_id)
      nil -> nil
    end
  end

  @doc """
  Revoke an agent token (idempotent). Accepts the `%AgentToken{}` struct or its
  plaintext. Stamps `revoked_at`; a revoked token never verifies again. Returns
  `{:ok, %AgentToken{}}`, or `{:error, :not_found}` when a plaintext matches no
  live token.
  """
  @spec revoke_agent_token(AgentToken.t() | binary()) ::
          {:ok, AgentToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_agent_token(%AgentToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
    |> Repo.update()
  end

  def revoke_agent_token(plaintext) when is_binary(plaintext) do
    hash = AgentToken.hash_token(plaintext)

    case Repo.get_by(AgentToken, token_hash: hash) do
      %AgentToken{} = token -> revoke_agent_token(token)
      nil -> {:error, :not_found}
    end
  end

  ## Sites — hosted websites running co-located with a Barkpark.

  @doc """
  Create a Site under `barkpark`. The Site's `team_id` is taken from the
  Barkpark — sites can never belong to a different team than their box.

  Returns `{:ok, %Site{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_site(Barkpark.t(), map()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def create_site(%Barkpark{} = barkpark, attrs) do
    %Site{}
    |> Site.changeset(
      attrs
      |> Map.put_new(:barkpark_id, barkpark.id)
      |> Map.put_new(:team_id, barkpark.team_id)
    )
    |> Repo.insert()
  end

  @doc "List a Team's sites across all of its barkparks, newest first."
  @spec list_sites_for_team(Team.t() | binary()) :: [Site.t()]
  def list_sites_for_team(team) do
    tid = team_id(team)

    Site
    |> where([s], s.team_id == ^tid)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "List sites running on `barkpark`, newest first."
  @spec list_sites(Barkpark.t() | binary()) :: [Site.t()]
  def list_sites(barkpark) do
    bp_id = barkpark_id(barkpark)

    Site
    |> where([s], s.barkpark_id == ^bp_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a Site by id, or nil."
  @spec get_site(binary()) :: Site.t() | nil
  def get_site(id), do: Repo.get(Site, id)

  @doc """
  Fetch a Site by id only if it belongs to `team` — the team-scoped read for the
  user-facing API. Returns `nil` if the site exists but is owned by another
  team (an existence leak protection: callers cannot distinguish "wrong team"
  from "no such site").
  """
  @spec get_team_site(Team.t() | binary(), binary()) :: Site.t() | nil
  def get_team_site(team, id) do
    tid = team_id(team)

    Site
    |> where([s], s.id == ^id and s.team_id == ^tid)
    |> Repo.one()
  end

  @doc """
  Replace the Site's encrypted env blob with the JSON-encoded `env_map`. The
  plaintext is encrypted via `Vault.encrypt/1`; only ciphertext lands at rest.
  """
  @spec set_site_env(Site.t(), map()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def set_site_env(%Site{} = site, env_map) when is_map(env_map) do
    json = Jason.encode!(env_map)

    site
    |> Site.changeset(%{env_encrypted: Vault.encrypt(json)})
    |> Repo.update()
  end

  @doc "Decrypt a Site's env blob back to a plaintext map. `{:ok, map} | :error | {:ok, %{}}` when unset."
  @spec reveal_site_env(Site.t()) :: {:ok, map()} | :error
  def reveal_site_env(%Site{env_encrypted: nil}), do: {:ok, %{}}

  def reveal_site_env(%Site{env_encrypted: ciphertext}) do
    with {:ok, json} <- Vault.decrypt(ciphertext),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  @doc """
  Add `domain` to a Site's `domains` array. Domains are stored lowercase and
  deduplicated. Returns `{:ok, site}` (already-present is a no-op) or a
  validation `{:error, changeset}` for malformed domains.
  """
  @spec add_site_domain(Site.t(), String.t()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def add_site_domain(%Site{domains: existing} = site, domain) when is_binary(domain) do
    new_domains = Enum.uniq(existing ++ [domain])

    site
    |> Site.changeset(%{domains: new_domains})
    |> Repo.update()
  end

  @doc "Remove `domain` from a Site's `domains` array. No-op if absent."
  @spec remove_site_domain(Site.t(), String.t()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def remove_site_domain(%Site{domains: existing} = site, domain) when is_binary(domain) do
    norm = domain |> String.downcase() |> String.trim() |> String.trim_trailing(".")
    new_domains = Enum.reject(existing, &(&1 == norm))

    site
    |> Site.changeset(%{domains: new_domains})
    |> Repo.update()
  end

  @doc """
  The on-demand TLS gate: is `domain` registered to ANY Site? Lookup is an
  indexed array-contains against `sites.domains` (GIN). Returns true / false.

  Caddy's `on_demand_tls.ask` calls this — a 200 means "we own this hostname,
  go ahead and issue a cert"; a 404 means "stop, this is not our hostname"
  (prevents the box from being a cert-issuance DoS target).
  """
  @spec domain_registered?(String.t()) :: boolean()
  def domain_registered?(domain) when is_binary(domain) do
    norm = domain |> String.downcase() |> String.trim() |> String.trim_trailing(".")

    Site
    |> where([s], fragment("? = ANY(?)", ^norm, s.domains))
    |> select([s], 1)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  ## Sites — GitHub webhook configuration (P7).

  @doc """
  Configure a Site's GitHub link: the `owner/repo` form, the branch to listen on
  (default "main"), and the webhook secret used to verify the HMAC on incoming
  pushes. `secret` is Vault-encrypted at rest — the plaintext is never persisted.

  Pass `secret` as `nil` to leave the existing secret in place (idempotent
  re-configure of repo/branch only). Pass a binary to replace it.

  Returns `{:ok, %Site{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec set_site_github(Site.t(), String.t(), String.t() | nil, binary() | nil) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def set_site_github(%Site{} = site, repo, branch, secret)
      when is_binary(repo) do
    branch = if is_binary(branch) and branch != "", do: branch, else: "main"

    attrs =
      %{
        github_repo: repo,
        github_branch: branch
      }
      |> maybe_put_encrypted_secret(secret)

    site
    |> Site.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_put_encrypted_secret(attrs, nil), do: attrs

  defp maybe_put_encrypted_secret(attrs, secret) when is_binary(secret) do
    Map.put(attrs, :github_webhook_secret_encrypted, Vault.encrypt(secret))
  end

  @doc """
  Decrypt a Site's GitHub webhook secret back to plaintext.

  Returns `{:ok, plaintext}` when set, `{:ok, nil}` when never configured, or
  `:error` when the stored ciphertext is tampered.
  """
  @spec reveal_site_github_secret(Site.t()) :: {:ok, binary() | nil} | :error
  def reveal_site_github_secret(%Site{github_webhook_secret_encrypted: nil}), do: {:ok, nil}

  def reveal_site_github_secret(%Site{github_webhook_secret_encrypted: ciphertext}) do
    case Vault.decrypt(ciphertext) do
      {:ok, plain} -> {:ok, plain}
      :error -> :error
    end
  end

  ## Deployments — the build-job queue.

  @doc """
  Create a Deployment for `site`, defaulting to `status: "queued"`. This is the
  enqueue half of `bp deploy`: the off-box builder polls for queued rows and
  walks them through building → pushing → live.
  """
  @spec create_deployment(Site.t(), map()) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def create_deployment(%Site{} = site, attrs \\ %{}) do
    %Deployment{}
    |> Deployment.changeset(Map.put(attrs, :site_id, site.id))
    |> Repo.insert()
  end

  @doc "List a Site's deployments, newest first."
  @spec list_deployments(Site.t() | binary()) :: [Deployment.t()]
  def list_deployments(site) do
    site_id = site_id(site)

    Deployment
    |> where([d], d.site_id == ^site_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a Deployment by id, or nil."
  @spec get_deployment(binary()) :: Deployment.t() | nil
  def get_deployment(id), do: Repo.get(Deployment, id)

  @doc """
  Transition a Deployment to a new status, optionally stamping `image_tag`,
  `build_log_url`, `failure_reason`, or `became_live_at`. Used by the off-box
  builder (P2) and the box agent (P3). Narrow by design — cannot move a
  deployment between sites.
  """
  @spec transition_deployment(Deployment.t(), map()) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def transition_deployment(%Deployment{} = deployment, attrs) do
    deployment
    |> Deployment.transition_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically claim the oldest queued Deployment for `worker_id`. Returns
  `{:ok, deployment}` carrying the bumped `claim_epoch`, or `{:error, :no_queued}`
  when the queue is empty.

  Concurrency: the SELECT uses `FOR UPDATE SKIP LOCKED` so two workers racing
  never collide — each picks a distinct row (or one finds no rows). The whole
  operation runs in one transaction, so the epoch bump + status flip + worker
  stamp are atomic with the row lock.

  Fencing: the `claim_epoch` increments on every successful claim; the builder
  passes the observed epoch into `transition_deployment_fenced/4`, which CASes
  on it — a stale-but-alive worker writing after its lease was swept fails the
  CAS instead of corrupting state.
  """
  @spec claim_next_deployment(String.t()) ::
          {:ok, Deployment.t()} | {:error, :no_queued}
  def claim_next_deployment(worker_id) when is_binary(worker_id) and worker_id != "" do
    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          where: d.status == "queued",
          order_by: [asc: d.inserted_at],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:no_queued)

        %Deployment{} = d ->
          {:ok, claimed} =
            d
            |> Deployment.transition_changeset(%{
              status: "building",
              claim_worker: worker_id,
              claimed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
              claim_epoch: d.claim_epoch + 1
            })
            |> Repo.update()

          claimed
      end
    end)
  end

  @doc """
  Transition a claimed Deployment, CASing on the worker's observed epoch. Returns
  `{:ok, deployment}` when the CAS holds; `{:error, :stale_epoch}` when the row's
  epoch has moved past `observed_epoch` (lease swept, re-claimed by another
  worker, or even the same worker after a re-claim); `{:error, :not_found}` when
  the deployment id doesn't exist.

  This is the fenced write the off-box builder uses for status updates — pushing,
  live, failed — without trampling a parallel re-claim.
  """
  @spec transition_deployment_fenced(binary(), String.t(), non_neg_integer(), map()) ::
          {:ok, Deployment.t()} | {:error, :stale_epoch | :not_found | Ecto.Changeset.t()}
  def transition_deployment_fenced(deployment_id, worker_id, observed_epoch, attrs)
      when is_binary(deployment_id) and is_binary(worker_id) and is_integer(observed_epoch) do
    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          where: d.id == ^deployment_id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Deployment{claim_epoch: e, claim_worker: w}
        when e != observed_epoch or w != worker_id ->
          Repo.rollback(:stale_epoch)

        %Deployment{} = d ->
          case d |> Deployment.transition_changeset(attrs) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, cs} -> Repo.rollback(cs)
          end
      end
    end)
  end

  @doc """
  Like `transition_deployment_fenced/4`, but in the SAME transaction also updates
  the Deployment's Site with the `site_attrs` runtime-changeset map (allowed
  keys: `:port`, `:current_deployment_id`). This is how the on-box agent flips
  the live-pointer atomically with the deployment going `live` — no window where
  the deployment is `live` but the site still points at the old port, or vice
  versa.

  Returns the updated deployment on success; same `:stale_epoch` / `:not_found`
  / changeset errors as the simple variant.
  """
  @spec transition_deployment_with_site_update(
          binary(),
          String.t(),
          non_neg_integer(),
          map(),
          map()
        ) ::
          {:ok, Deployment.t()} | {:error, :stale_epoch | :not_found | Ecto.Changeset.t()}
  def transition_deployment_with_site_update(
        deployment_id,
        worker_id,
        observed_epoch,
        deployment_attrs,
        site_attrs
      )
      when is_binary(deployment_id) and is_binary(worker_id) and
             is_integer(observed_epoch) and is_map(site_attrs) do
    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          where: d.id == ^deployment_id,
          lock: "FOR UPDATE",
          preload: [:site]
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Deployment{claim_epoch: e, claim_worker: w}
        when e != observed_epoch or w != worker_id ->
          Repo.rollback(:stale_epoch)

        %Deployment{} = d ->
          with {:ok, updated} <-
                 d |> Deployment.transition_changeset(deployment_attrs) |> Repo.update(),
               {:ok, _site} <-
                 d.site |> Site.runtime_changeset(site_attrs) |> Repo.update() do
            updated
          else
            {:error, cs} -> Repo.rollback(cs)
          end
      end
    end)
  end

  ## Agent (on-box runtime) — pending pickup + atomic claim, scoped to the
  ## agent's Barkpark. The runtime executor (P3) calls these to drive
  ## Deployments from `pushing` → `live` (or → `failed` on health-check fail).

  @doc """
  List Deployments in `pushing` status that belong to a Site on `barkpark` —
  the on-box agent's pending queue. Newest first so a fresh deploy claims first.
  """
  @spec list_pending_deployments_for_barkpark(Barkpark.t() | binary()) :: [Deployment.t()]
  def list_pending_deployments_for_barkpark(barkpark) do
    bp_id = barkpark_id(barkpark)

    from(d in Deployment,
      join: s in Site,
      on: s.id == d.site_id,
      where: d.status == "pushing" and s.barkpark_id == ^bp_id,
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Atomically claim the oldest pushing Deployment whose Site is on `barkpark`,
  for `worker_id`. The on-box agent's analogue of `claim_next_deployment/1` —
  same `FOR UPDATE SKIP LOCKED` discipline + epoch bump, narrower filter.

  Returns `{:ok, deployment}` with the bumped epoch, or `{:error, :no_pending}`
  when the agent has nothing waiting on this box. Returns `{:error, :wrong_box}`
  is NOT a case — a deployment whose site is on another box simply isn't in
  this barkpark's queue, indistinguishable from an empty queue, and that is
  intentional (no cross-box existence leak).
  """
  @spec claim_pending_deployment_for_barkpark(Barkpark.t() | binary(), String.t()) ::
          {:ok, Deployment.t()} | {:error, :no_pending}
  def claim_pending_deployment_for_barkpark(barkpark, worker_id)
      when is_binary(worker_id) and worker_id != "" do
    bp_id = barkpark_id(barkpark)

    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          join: s in Site,
          on: s.id == d.site_id,
          where:
            d.status == "pushing" and s.barkpark_id == ^bp_id and
              is_nil(d.claim_worker),
          order_by: [asc: d.inserted_at],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED",
          select: d
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:no_pending)

        %Deployment{} = d ->
          {:ok, claimed} =
            d
            |> Deployment.transition_changeset(%{
              claim_worker: worker_id,
              claimed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
              claim_epoch: d.claim_epoch + 1
            })
            |> Repo.update()

          claimed
      end
    end)
  end

  ## Helpers

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  defp barkpark_id(%Barkpark{id: id}), do: id
  defp barkpark_id(id) when is_binary(id), do: id

  defp site_id(%Site{id: id}), do: id
  defp site_id(id) when is_binary(id), do: id

  # Stamp the resolved team_id into attrs (string- or atom-keyed), so callers
  # pass the Team positionally and never have to thread :team_id themselves.
  defp put_team_id(attrs, team) when is_map(attrs) do
    tid = team_id(team)

    if Map.has_key?(attrs, "team_id") or
         (not Map.has_key?(attrs, :team_id) and string_keyed?(attrs)) do
      Map.put(attrs, "team_id", tid)
    else
      Map.put(attrs, :team_id, tid)
    end
  end

  defp string_keyed?(attrs) do
    Enum.any?(attrs, fn {k, _} -> is_binary(k) end)
  end
end
