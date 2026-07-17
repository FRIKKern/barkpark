defmodule Barkpark.Secrets do
  @moduledoc """
  Cloud run-secrets — a GENERAL store for secrets BP Cloud keeps
  encrypted-at-rest, where an authenticated ADMIN can always retrieve and rotate
  them. Each secret is a single string keyed by `name` within a TIER, encrypted
  via `Barkpark.EncryptedBinary` (Cloak AES-GCM). Every mutating op and every
  reveal is audited; plain reads (`get/1,2`) are NOT audited so resolvers can
  poll cheaply.

  ## Two-tier scoping (connectors W21, charter D191–D195)

  Every public function threads a `scope` — `:global` (the default, so every
  pre-W21 caller is byte-identical) or a workspace id binary. The private
  `scope_secrets/2` gate mirrors `Barkpark.StudioChat.scope_sessions/2` /
  `Content.Scope.scope_to_workspace/3`:

    * `:global`     → `WHERE workspace_id IS NULL` — an explicit arm, never
                      all-rows. Global reads NEVER see workspace rows (no
                      tenant shadowing of `ingest_token`).
    * binary ws id  → `WHERE workspace_id = ^ws`. Scoped reads NEVER see
                      NULL-owner globals — no `OR is_nil` carve-out; instance
                      credentials must not leak into a tenant scope.
    * anything else → fail-closed: zero rows / `:not_found` / `[]`, and `put`
                      refuses with `{:error, :invalid_scope}` rather than
                      guessing a tier.

  ## Cryptographic tenant binding (connectors D201, option C)

  The tier wall is CRYPTOGRAPHIC, not merely SQL. `SecretRecord.value` is a raw
  `:binary` column and this context runs an explicit per-tier codec (see
  `encode_value/2` / `decode_value/1`):

    * GLOBAL rows (`workspace_id` nil) use `Barkpark.Vault` directly — exactly
      what `EncryptedBinary` delegated to, so on-disk bytes stay byte-identical
      and the prod `ingest_token` keeps round-tripping through a plain Cloak
      blob.
    * SCOPED rows store a `Barkpark.Crypto.FieldCipher` envelope keyed by the
      per-`(workspace_id, "run-secrets")` DEK (`DataKeys`, charter D51-D54). The
      per-workspace DEK SELECTION is the binding — a row physically MOVED to
      another workspace is decrypted under the WRONG DEK, GCM tag mismatch,
      `:error`. Reads branch on the ROW's own `workspace_id` and seal ANY
      decrypt failure to the tier's opaque-absent reply (`{:error, :not_found}`
      for `reveal`, `nil` for `get`) — the leak reaches `get/2` too, so BOTH
      verbs are sealed. This replaces the D196a SQL-only wall.

  The ingest token is the first consumer: `ingest_token/0` resolves the
  effective shared secret DB-first (GLOBAL tier only, structurally
  instance-level), env-fallback, so an admin can rotate it at runtime without a
  redeploy while bootstrap/non-cloud installs keep using
  `config :barkpark, :ingest_token`.

  Mirrors `Barkpark.Plugins.Settings` (the encrypted-KV pattern), with a clean
  single-value column instead of a JSON map. `Plugins.Settings` stays
  instance-global BY DESIGN (singleton plugin config — D196c).
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Secrets.{SecretRecord, SecretAudit}
  alias Barkpark.Plugins.Settings.Masking
  alias Barkpark.Crypto.FieldCipher

  # The FieldCipher AAD/DEK scope for every workspace-scoped run-secret. The
  # per-workspace binding is the DEK SELECTION (workspace_id, @field_scope), NOT
  # this string — it stays constant so the DEK is what walls one tenant off from
  # another (crypto_test "per-workspace isolation").
  @field_scope "run-secrets"

  @typedoc "Secret tier: instance-global or one workspace (anything else fails closed)."
  @type scope :: :global | Ecto.UUID.t()

  @doc """
  Fetch the decrypted secret value in `scope`, or `nil` when absent (or when
  the scope is invalid — fail-closed). NOT audited — this is the resolver/poll
  path (e.g. `ingest_token/0`). Use `reveal/2` for the admin-facing, audited
  read. `get/1` stays pinned to the GLOBAL tier (its sole caller is
  `ingest_token/0`, checked before any workspace resolution exists).
  """
  @spec get(String.t(), scope()) :: String.t() | nil
  def get(name, scope \\ :global) when is_binary(name) do
    with %SecretRecord{} = record <- fetch(name, scope),
         {:ok, value} <- decode_value(record) do
      value
    else
      # Absent, or the ciphertext failed to decrypt under this row's tier (e.g.
      # a swap-attacked scoped row) — seal to `nil`, indistinguishable from
      # absent. The leak reaches this un-audited resolver path too, so it is
      # sealed identically to `reveal/2`.
      _ -> nil
    end
  end

  @doc """
  Fetch the unmasked secret value and record a `"reveal"` audit row (stamped
  with the acting workspace). Used by the admin HTTP `GET /v1/secrets/:name`.
  Returns `{:error, :not_found}` (and writes no audit row) when the secret is
  absent from the tier — a foreign workspace's secret and a global secret read
  under a workspace scope are both indistinguishable from absent.

  Options: `:actor` — audit attribution; `:scope` — tier (default `:global`).
  """
  @spec reveal(String.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def reveal(name, opts \\ []) when is_binary(name) do
    actor = Keyword.get(opts, :actor)
    scope = Keyword.get(opts, :scope, :global)

    with %SecretRecord{} = record <- fetch(name, scope),
         {:ok, value} <- decode_value(record) do
      # Atomic reveal: the secret is only returned once the audit row commits.
      {:ok, ^value} =
        Repo.transaction(fn ->
          log_audit(name, "reveal", actor, scope)
          value
        end)

      {:ok, value}
    else
      # Absent, or a scoped row that fails to decrypt under this scope's DEK (a
      # relocated/swap-attacked row) — opaque `:not_found`, no audit row. The
      # crypto denial is indistinguishable from a foreign or absent secret.
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Set or rotate a secret within its tier and record a `"set"` audit row.
  The mutation and its audit row are atomic — an audit failure rolls back the
  write rather than stranding an un-audited secret.

  The upsert arbiter is the tier's own partial unique index (D194 — a bare
  `conflict_target: :name` raises Postgrex 42P10 now that the PK is the
  surrogate id), and `on_conflict` replaces ONLY `value`/`updated_at`/
  `updated_by` — never `id`/`name`/`workspace_id` (precedent bug:
  connectors-upsert-install-conflict-wipes-sibling-secret).

  Options: `:actor`; `:scope` (default `:global`). An invalid scope (e.g.
  `nil`) refuses with `{:error, :invalid_scope}` — a write must never guess
  its tier.
  """
  @spec put(String.t(), String.t(), keyword()) ::
          {:ok, SecretRecord.t()} | {:error, Ecto.Changeset.t() | :invalid_scope}
  def put(name, value, opts \\ []) when is_binary(name) and is_binary(value) do
    actor = Keyword.get(opts, :actor)

    case Keyword.get(opts, :scope, :global) do
      scope when scope == :global or is_binary(scope) -> do_put(name, value, actor, scope)
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp do_put(name, value, actor, scope) do
    now = DateTime.utc_now()

    attrs = %{
      name: name,
      value: encode_value(value, scope),
      updated_at: now,
      updated_by: actor,
      workspace_id: scope_workspace_id(scope)
    }

    record = fetch(name, scope) || %SecretRecord{}

    Repo.transaction(fn ->
      case record
           |> SecretRecord.changeset(attrs)
           |> Repo.insert_or_update(
             on_conflict: {:replace, [:value, :updated_at, :updated_by]},
             conflict_target: conflict_target(scope)
           ) do
        {:ok, rec} ->
          log_audit(name, "set", actor, scope)
          rec

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  List every secret name in `scope` with a MASKED value (last 4 chars), newest
  write first. `list()` lists the GLOBAL tier only; `list(workspace_id)` that
  workspace only; an invalid scope lists nothing (fail-closed). Never returns
  plaintext — the masked projection reuses `Barkpark.Plugins.Settings.Masking`.
  """
  @spec list(scope()) :: [%{name: String.t(), value: String.t(), updated_at: DateTime.t() | nil}]
  def list(scope \\ :global) do
    SecretRecord
    |> scope_secrets(scope)
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
    |> Enum.map(fn %SecretRecord{name: name, updated_at: at} = record ->
      # Decode per the row's own tier, then mask. A row that fails to decrypt
      # (e.g. relocated ciphertext) never surfaces plaintext — it masks the
      # empty string.
      plaintext =
        case decode_value(record) do
          {:ok, value} -> value
          :error -> ""
        end

      %{name: name, value: Masking.mask(plaintext), updated_at: at}
    end)
  end

  @doc """
  Delete a secret from its tier and record a `"delete"` audit row (atomic).
  Returns `{:error, :not_found}` when absent from the tier — a foreign
  workspace's secret can never be deleted through another scope.

  Options: `:actor`; `:scope` (default `:global`).
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, :not_found}
  def delete(name, opts \\ []) when is_binary(name) do
    actor = Keyword.get(opts, :actor)
    scope = Keyword.get(opts, :scope, :global)

    case fetch(name, scope) do
      nil ->
        {:error, :not_found}

      rec ->
        # A concurrent double-DELETE would raise Ecto.StaleEntryError inside the
        # txn (→ 500); stale_error_field turns it into a rollback with :not_found.
        txn =
          Repo.transaction(fn ->
            case Repo.delete(rec, stale_error_field: :id) do
              {:ok, _} ->
                log_audit(name, "delete", actor, scope)
                :deleted

              {:error, _cs} ->
                Repo.rollback(:not_found)
            end
          end)

        case txn do
          {:ok, :deleted} -> :ok
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc """
  The effective ingest shared-secret. DB-first (the rotatable cloud secret,
  GLOBAL tier — a workspace row shadowing the name is never consulted),
  falling back to `config :barkpark, :ingest_token` (bootstrap / non-cloud
  installs). Returns `nil` when neither is set — callers treat that as "closed".
  """
  @spec ingest_token() :: String.t() | nil
  def ingest_token do
    get("ingest_token") || Application.get_env(:barkpark, :ingest_token)
  end

  # ---------------------------------------------------------------------------
  # Tier gate (D193) — mirrors StudioChat.scope_sessions/2 with one deliberate
  # difference: `:global` is an EXPLICIT `IS NULL` arm, never pass-through
  # all-rows, so neither tier can see the other. Anything that is not `:global`
  # or a binary workspace id (a `nil` from an unresolved workspace, a struct,
  # an atom typo) matches the final clause and reads ZERO rows — fail-closed
  # per the scope_to_workspace/3 law (docs/contracts/tenancy.md).
  # ---------------------------------------------------------------------------
  defp scope_secrets(query, :global), do: where(query, [s], is_nil(s.workspace_id))

  defp scope_secrets(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [s], s.workspace_id == ^workspace_id)

  defp scope_secrets(query, _fail_closed), do: where(query, false)

  # The single row for `name` in `scope` (nil when absent or scope invalid).
  # NEVER Repo.get/2 by name — the PK is the surrogate id (D191).
  defp fetch(name, scope) do
    SecretRecord
    |> where([s], s.name == ^name)
    |> scope_secrets(scope)
    |> Repo.one()
  end

  defp scope_workspace_id(:global), do: nil
  defp scope_workspace_id(workspace_id) when is_binary(workspace_id), do: workspace_id

  # ---------------------------------------------------------------------------
  # Per-tier crypto codec (D201, option C). The Ecto column is a raw `:binary`;
  # the tier decides the cipher:
  #   * GLOBAL (`:global`) — `Barkpark.Vault` (Cloak) blob, byte-identical to
  #     the old `EncryptedBinary` on-disk format (`ingest_token` unchanged).
  #   * SCOPED (workspace binary) — a Jason-encoded `FieldCipher` envelope keyed
  #     by the per-(workspace, "run-secrets") DEK. The workspace binding IS the
  #     DEK selection, so a row moved to another workspace can't be decrypted.
  # ---------------------------------------------------------------------------
  defp encode_value(value, :global), do: Barkpark.Vault.encrypt!(value)

  defp encode_value(value, workspace_id) when is_binary(workspace_id) do
    value
    |> FieldCipher.encrypt(@field_scope, workspace_id)
    |> Jason.encode!()
  end

  # Decrypt a stored row by its OWN tier (branch on the row's workspace_id, never
  # the requested scope — `fetch/2` already proved the row belongs to the scope).
  # ANY failure (bad payload, wrong-DEK GCM mismatch from a relocated row,
  # decode raise) collapses to `:error`, which the read verbs seal to opaque
  # absent. Fail-closed.
  @spec decode_value(SecretRecord.t()) :: {:ok, String.t()} | :error
  defp decode_value(%SecretRecord{value: encoded, workspace_id: nil}) do
    case Barkpark.Vault.decrypt(encoded) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_value(%SecretRecord{value: encoded, workspace_id: workspace_id})
       when is_binary(workspace_id) do
    with {:ok, envelope} <- Jason.decode(encoded),
         {:ok, value} when is_binary(value) <-
           FieldCipher.decrypt(envelope, @field_scope, workspace_id) do
      {:ok, value}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # D194: the upsert arbiter must name the tier's partial unique index — the
  # surrogate PK made bare `conflict_target: :name` a Postgrex 42P10 error.
  defp conflict_target(:global),
    do: {:unsafe_fragment, "(name) WHERE workspace_id IS NULL"}

  defp conflict_target(workspace_id) when is_binary(workspace_id),
    do: {:unsafe_fragment, "(workspace_id, name) WHERE workspace_id IS NOT NULL"}

  defp log_audit(name, action, actor, scope) do
    %SecretAudit{}
    |> SecretAudit.changeset(%{
      name: name,
      action: action,
      actor: actor,
      workspace_id: scope_workspace_id(scope),
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
