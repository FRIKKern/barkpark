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
  alias BarkparkCloud.Registry.{AgentEvent, AgentToken, Barkpark, Provider, ProvisionJob, Vault}

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

  ## Helpers

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  defp barkpark_id(%Barkpark{id: id}), do: id
  defp barkpark_id(id) when is_binary(id), do: id

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
