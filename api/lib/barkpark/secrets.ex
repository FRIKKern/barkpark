defmodule Barkpark.Secrets do
  @moduledoc """
  Cloud run-secrets — a GENERAL store for secrets BP Cloud keeps
  encrypted-at-rest, where an authenticated ADMIN can always retrieve and rotate
  them. Each secret is a single string keyed by `name`, encrypted via
  `Barkpark.EncryptedBinary` (Cloak AES-GCM). Every mutating op and every reveal
  is audited; plain reads (`get/1`) are NOT audited so resolvers can poll cheaply.

  The ingest token is the first consumer: `ingest_token/0` resolves the effective
  shared secret DB-first, env-fallback, so an admin can rotate it at runtime
  without a redeploy while bootstrap/non-cloud installs keep using
  `config :barkpark, :ingest_token`.

  Mirrors `Barkpark.Plugins.Settings` (the encrypted-KV pattern), with a clean
  single-value column instead of a JSON map.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Secrets.{SecretRecord, SecretAudit}
  alias Barkpark.Plugins.Settings.Masking

  @doc """
  Fetch the decrypted secret value, or `nil` when absent. NOT audited — this is
  the resolver/poll path (e.g. `ingest_token/0`). Use `reveal/2` for the
  admin-facing, audited read.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(name) when is_binary(name) do
    case Repo.get(SecretRecord, name) do
      nil -> nil
      %SecretRecord{value: value} -> value
    end
  end

  @doc """
  Fetch the unmasked secret value and record a `"reveal"` audit row. Used by the
  admin HTTP `GET /v1/secrets/:name`. Returns `{:error, :not_found}` (and writes
  no audit row) when the secret is absent.
  """
  @spec reveal(String.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def reveal(name, opts \\ []) when is_binary(name) do
    actor = Keyword.get(opts, :actor)

    case Repo.get(SecretRecord, name) do
      nil ->
        {:error, :not_found}

      %SecretRecord{value: value} ->
        # Atomic reveal: the secret is only returned once the audit row commits.
        {:ok, ^value} =
          Repo.transaction(fn ->
            log_audit(name, "reveal", actor)
            value
          end)

        {:ok, value}
    end
  end

  @doc """
  Set or rotate a secret (`on_conflict: replace`) and record a `"set"` audit row.
  The mutation and its audit row are atomic — an audit failure rolls back the
  write rather than stranding an un-audited secret.
  """
  @spec put(String.t(), String.t(), keyword()) ::
          {:ok, SecretRecord.t()} | {:error, Ecto.Changeset.t()}
  def put(name, value, opts \\ []) when is_binary(name) and is_binary(value) do
    actor = Keyword.get(opts, :actor)
    now = DateTime.utc_now()

    attrs = %{name: name, value: value, updated_at: now, updated_by: actor}
    record = Repo.get(SecretRecord, name) || %SecretRecord{name: name}

    Repo.transaction(fn ->
      case record
           |> SecretRecord.changeset(attrs)
           |> Repo.insert_or_update(
             on_conflict: {:replace_all_except, [:name]},
             conflict_target: :name
           ) do
        {:ok, rec} ->
          log_audit(name, "set", actor)
          rec

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  List every secret name with a MASKED value (last 4 chars), newest write first.
  Never returns plaintext — the masked projection reuses
  `Barkpark.Plugins.Settings.Masking`.
  """
  @spec list() :: [%{name: String.t(), value: String.t(), updated_at: DateTime.t() | nil}]
  def list do
    SecretRecord
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
    |> Enum.map(fn %SecretRecord{name: name, value: value, updated_at: at} ->
      %{name: name, value: Masking.mask(value), updated_at: at}
    end)
  end

  @doc """
  Delete a secret and record a `"delete"` audit row (atomic). Returns
  `{:error, :not_found}` when absent.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, :not_found}
  def delete(name, opts \\ []) when is_binary(name) do
    actor = Keyword.get(opts, :actor)

    case Repo.get(SecretRecord, name) do
      nil ->
        {:error, :not_found}

      rec ->
        {:ok, :deleted} =
          Repo.transaction(fn ->
            Repo.delete!(rec)
            log_audit(name, "delete", actor)
            :deleted
          end)

        :ok
    end
  end

  @doc """
  The effective ingest shared-secret. DB-first (the rotatable cloud secret),
  falling back to `config :barkpark, :ingest_token` (bootstrap / non-cloud
  installs). Returns `nil` when neither is set — callers treat that as "closed".
  """
  @spec ingest_token() :: String.t() | nil
  def ingest_token do
    get("ingest_token") || Application.get_env(:barkpark, :ingest_token)
  end

  defp log_audit(name, action, actor) do
    %SecretAudit{}
    |> SecretAudit.changeset(%{
      name: name,
      action: action,
      actor: actor,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
