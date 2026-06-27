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
  require Logger

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Registry.{AgentEvent, AgentToken, Barkpark, Provider, ProvisionJob, Vault}

  # The warm-pool defaults a provision job carries to the Go worker when the
  # Barkpark row doesn't pin a region / server_type of its own. These mirror the
  # warm-pool's own defaults (internal/cli/cloud) — Nuremberg, the cax11 ARM box.
  @default_region "nbg1"
  @default_server_type "cax11"

  # Stale-claim recovery. A claimed job whose `claimed_at` is older than this is
  # treated as abandoned (the worker crashed, or its succeed/fail report failed in
  # transit and — per the worker contract — it tore down its half-built box and
  # LEFT the row "claimed") and is re-claimable by claim_next_job. The threshold
  # is the Go worker's DefaultProvisionTimeout (8m — internal/provisioner) plus a
  # margin for the box teardown + the report round-trip, so a still-running job is
  # NEVER yanked out from under a live worker. Overridable via
  # `config :barkpark_cloud, :provision_stale_after_seconds` (e.g. to match a
  # non-default worker ProvisionTimeout). Default: 12 minutes.
  @default_stale_after_seconds 12 * 60

  # The attempt budget: claim_next_job bumps `attempts` on every (re)claim, and a
  # stale job whose attempts have already reached this cap is transitioned to
  # "failed" ("exceeded max provision attempts") instead of being handed out
  # again — so a permanently-failing job stops looping. Overridable via
  # `config :barkpark_cloud, :max_provision_attempts`.
  @default_max_provision_attempts 3

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
  Atomically claim the next claimable provision job for `claim_token`. This is
  the worker's pull, and it is the canonical Postgres job-claim: one transaction
  that SELECTs the oldest claimable row `FOR UPDATE SKIP LOCKED LIMIT 1` and
  UPDATEs that same locked row to `claimed`. The row-level lock makes the claim
  self-evidently race-safe — a second worker polling concurrently SKIPs the
  locked row and grabs the next claimable one, so two workers can never claim the
  same job (no CAS retry loop needed; the database serializes the contention).

  A row is *claimable* when it is either:

    * `pending` — never claimed, OR
    * `claimed` but STALE — `claimed_at` older than the staleness threshold
      (`stale_after_seconds/0`, default the worker's provision timeout + margin).
      A stale claim means the worker crashed or its succeed/fail report failed in
      transit and — per the worker contract — it tore down its box and LEFT the
      row "claimed"; re-claiming it runs a fresh attempt. A FRESH `claimed` row
      (within the threshold) is NOT re-claimable, so a live worker is never raced.

  Stale recovery is BOUNDED by `attempts`: every (re)claim bumps `attempts`. A
  stale row whose `attempts` have already reached `max_provision_attempts/0` is
  transitioned to `"failed"` ("exceeded max provision attempts") instead of being
  handed out again, and the claim moves on to the next claimable row — so a
  permanently-failing job stops looping forever.

  Returns `{job, barkpark}` for the claimed job, or `nil` when nothing is
  claimable (the worker's 204 / sleep path).
  """
  @spec claim_next_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_job(claim_token) when is_binary(claim_token) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    stale_before = DateTime.add(now, -stale_after_seconds(), :second)
    max_attempts = max_provision_attempts()

    result =
      Repo.transaction(fn ->
        claim_loop(claim_token, now, stale_before, max_attempts)
      end)

    case result do
      {:ok, claim} -> claim
      {:error, _} -> nil
    end
  end

  # Lock the oldest claimable row (pending, or claimed-but-stale); concurrent
  # claimers SKIP LOCKED past it. If a stale row has burned through its attempt
  # budget, fail it and recurse to the next claimable row (so an over-budget job
  # never blocks a younger pending one); otherwise (re)claim it, bumping attempts.
  defp claim_loop(claim_token, now, stale_before, max_attempts) do
    locked =
      from(j in ProvisionJob,
        where:
          j.status == "pending" or
            (j.status == "claimed" and j.claimed_at < ^stale_before),
        order_by: [asc: j.inserted_at, asc: j.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(locked) do
      nil ->
        nil

      %ProvisionJob{status: "claimed", attempts: attempts} = job when attempts >= max_attempts ->
        # A stale claim that already exhausted its attempt budget: fail it (don't
        # hand it out again) and keep looking for another claimable job.
        {:ok, _failed} =
          job
          |> ProvisionJob.changeset(%{
            status: "failed",
            error: "exceeded max provision attempts (#{max_attempts})"
          })
          |> Repo.update()

        claim_loop(claim_token, now, stale_before, max_attempts)

      %ProvisionJob{} = job ->
        {:ok, claimed} =
          job
          |> ProvisionJob.changeset(%{
            status: "claimed",
            claim_token: claim_token,
            claimed_at: now,
            attempts: job.attempts + 1
          })
          |> Repo.update()

        {claimed, Repo.get(Barkpark, claimed.barkpark_id)}
    end
  end

  @doc """
  Mark provision job `id` succeeded with the provisioned host `ip`, and flip the
  owning Barkpark to live: `health_status: "up"`, `host: ip`, and
  `agent_status: "offline"` (the on-box agent hasn't phoned home yet — that's a
  separate signal the agent report later flips to online).

  IDEMPOTENT + status-guarded, keyed on the job's current status:

    * `"claimed"` (the normal path) — flip the job to `"succeeded"` AND upsert the
      barkpark to up, atomically (see the transaction below).
    * `"succeeded"` (a RETRIED/duplicate succeed) — return `{:ok, job}` WITHOUT
      re-running the barkpark health/host upsert or any other side-effect. This is
      what self-heals a LOST-RESPONSE split-brain: the box was already committed
      live, the worker's HTTP response was dropped, the worker re-POSTs, and this
      re-POST returns 200 so the worker KEEPS the box (no double work, no teardown
      of a box the control plane already holds live).
    * any other TERMINAL state (`"failed"` — from the attempt cap or an explicit
      fail) — return `{:error, :conflict}` (→ 409). "failed" is genuinely terminal:
      we do NOT flip it to "succeeded" and do NOT touch the barkpark. The Go worker
      treats the 4xx as "the control plane gave up on this job — tear down the
      orphan box", which is correct.

  Returns `{:ok, %ProvisionJob{}}`, `{:error, :not_found}` when no job has that id,
  or `{:error, :conflict}` for a succeed against a terminal non-succeeded job.
  """
  @spec succeed_job(binary(), String.t()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def succeed_job(id, ip) when is_binary(id) and is_binary(ip) do
    case uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      # IDEMPOTENT: an already-succeeded job. Return it unchanged — NO re-upsert of
      # the barkpark, no error. A dropped response + worker re-POST lands here and
      # gets a 200, so the worker keeps the live box.
      %ProvisionJob{status: "succeeded"} = job ->
        {:ok, job}

      # STATUS GUARD: a job in a terminal NON-succeeded state ("failed"). Terminal
      # is terminal — don't resurrect it into "succeeded", don't touch the barkpark.
      %ProvisionJob{status: "failed"} ->
        {:error, :conflict}

      %ProvisionJob{} = job ->
        # ONE transaction: the job-status flip AND the barkpark health/host upsert
        # commit or roll back together. Before this, the flip ran first and the
        # health upsert's result was DISCARDED — so a failing upsert (e.g. the
        # global :url unique index, or a validation) left the job "succeeded" but
        # the barkpark still provisioning/host=nil: a silent split-brain where the
        # customer is billed for a box the dashboard never shows. Now either both
        # land or neither does, and the upsert failure surfaces (logged + the whole
        # call returns {:error, changeset}) instead of being swallowed.
        result =
          Repo.transaction(fn ->
            with {:ok, job} <-
                   job
                   |> ProvisionJob.changeset(%{status: "succeeded", result_ip: ip})
                   |> Repo.update(),
                 {:ok, _barkpark} <- upsert_succeeded_barkpark(job, ip) do
              job
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, job} ->
            {:ok, job}

          {:error, reason} ->
            Logger.error(
              "succeed_job: rolled back job #{id} — barkpark health upsert failed: " <>
                inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  # The barkpark-side half of a successful provision, run INSIDE succeed_job's
  # transaction: flip the owning barkpark to up at `ip`. A missing barkpark row
  # (the FK is on_delete: :delete_all, so this is the deleted-mid-provision edge)
  # is treated as a no-op success — there is nothing to flip and the job flip
  # should still stand.
  defp upsert_succeeded_barkpark(%ProvisionJob{barkpark_id: barkpark_id}, ip) do
    case Repo.get(Barkpark, barkpark_id) do
      nil ->
        {:ok, nil}

      %Barkpark{} = barkpark ->
        upsert_health(barkpark, %{health_status: "up", host: ip, agent_status: "offline"})
    end
  end

  @doc """
  Mark provision job `id` failed with `error`. The owning Barkpark stays in its
  provisioning state (health_status unchanged) — a fail is terminal here (no
  retries/backoff, YAGNI), and a human (or a re-launch) is the recovery path.

  IDEMPOTENT + status-guarded, keyed on the job's current status:

    * `"failed"` (a RETRIED/duplicate fail) — return `{:ok, job}` unchanged (→ 200),
      no re-write. A dropped fail-response + worker re-POST self-heals here.
    * `"succeeded"` — return `{:error, :conflict}` (→ 409). Do NOT un-succeed a job
      whose box is already live: a straggler fail must never tear down a live box.
    * `"claimed"` / `"pending"` (the normal path) — flip to `"failed"`.

  Returns `{:ok, %ProvisionJob{}}`, `{:error, :not_found}`, or `{:error, :conflict}`
  for a fail against an already-succeeded job.
  """
  @spec fail_job(binary(), String.t()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def fail_job(id, error) when is_binary(id) do
    case uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      # IDEMPOTENT: an already-failed job. Return it unchanged — no re-write, so a
      # retried/duplicate fail (lost response) self-heals to 200.
      %ProvisionJob{status: "failed"} = job ->
        {:ok, job}

      # STATUS GUARD: never un-succeed a live box. A straggler fail for a job that
      # already succeeded is a 409, and the barkpark is left up.
      %ProvisionJob{status: "succeeded"} ->
        {:error, :conflict}

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

  @doc """
  Seconds a `claimed` job may sit before claim_next_job treats it as abandoned and
  re-claimable. Defaults to the worker provision timeout + margin
  (#{@default_stale_after_seconds}s); overridable via
  `config :barkpark_cloud, :provision_stale_after_seconds`.
  """
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :provision_stale_after_seconds,
      @default_stale_after_seconds
    )
  end

  @doc """
  Max times a job may be (re)claimed before a stale claim is failed
  ("exceeded max provision attempts") instead of re-handed-out. Defaults to
  #{@default_max_provision_attempts}; overridable via
  `config :barkpark_cloud, :max_provision_attempts`.
  """
  @spec max_provision_attempts() :: pos_integer()
  def max_provision_attempts do
    Application.get_env(:barkpark_cloud, :max_provision_attempts, @default_max_provision_attempts)
  end

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

  # Guard a :binary_id PK lookup: a non-UUID id (a malformed path param) makes
  # Repo.get raise Ecto.Query.CastError → an HTTP 500. Returning nil here for a
  # non-castable id routes it to the {:error, :not_found} branch (→ 404), which is
  # what the API documents for an absent/invalid job id. A valid UUID passes
  # through unchanged.
  defp uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

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
