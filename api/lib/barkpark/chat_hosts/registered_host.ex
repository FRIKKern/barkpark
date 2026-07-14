defmodule Barkpark.ChatHosts.RegisteredHost do
  @moduledoc "Workspace-owned machine registered for outbound Studio Chat execution."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "registered_chat_hosts" do
    field :name, :string
    field :enrollment_hash, :binary
    field :enrollment_expires_at, :utc_datetime_usec
    field :enrolled_at, :utc_datetime_usec
    field :credential_hash, :binary
    field :credential_version, :integer, default: 0
    field :credential_expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :approved_roots, {:array, :string}, default: []
    field :protocol_version, :integer, default: 1
    field :capabilities, :map, default: %{}
    field :last_seen_at, :utc_datetime_usec

    belongs_to :workspace, Barkpark.Tenancy.Workspace
    timestamps(type: :utc_datetime_usec)
  end

  @enrollment_fields ~w(workspace_id name enrollment_hash enrollment_expires_at approved_roots protocol_version capabilities)a
  @heartbeat_fields ~w(protocol_version capabilities last_seen_at)a

  def enrollment_changeset(host, attrs) do
    host
    |> cast(attrs, @enrollment_fields)
    |> validate_required([:workspace_id, :name, :enrollment_hash, :enrollment_expires_at])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_number(:protocol_version, greater_than: 0)
    |> validate_roots()
    |> validate_capabilities()
    |> unique_constraint([:workspace_id, :name])
  end

  def enrollment_complete_changeset(host, attrs) do
    host
    |> cast(attrs, [
      :enrolled_at,
      :credential_hash,
      :credential_version,
      :credential_expires_at,
      :approved_roots,
      :protocol_version,
      :capabilities,
      :last_seen_at
    ])
    |> validate_required([:enrolled_at, :credential_hash, :credential_expires_at])
    |> validate_number(:credential_version, greater_than: 0)
    |> validate_roots()
    |> validate_capabilities()
    |> check_constraint(:credential_hash, name: :registered_chat_hosts_credential_state)
  end

  def heartbeat_changeset(host, attrs) do
    host
    |> cast(attrs, @heartbeat_fields)
    |> validate_number(:protocol_version, greater_than: 0)
    |> validate_capabilities()
  end

  def revoke_changeset(host, at), do: change(host, revoked_at: at)

  def rotate_changeset(host, attrs) do
    host
    |> cast(attrs, [:credential_hash, :credential_version, :credential_expires_at])
    |> validate_required([:credential_hash, :credential_version, :credential_expires_at])
    |> validate_number(:credential_version, greater_than: 0)
  end

  defp validate_roots(changeset) do
    validate_change(changeset, :approved_roots, fn :approved_roots, roots ->
      cond do
        not is_list(roots) ->
          [approved_roots: "must be a list"]

        Enum.any?(roots, &(not is_binary(&1) or Path.type(&1) != :absolute)) ->
          [approved_roots: "must be absolute"]

        Enum.uniq(roots) != roots ->
          [approved_roots: "must not contain duplicates"]

        true ->
          []
      end
    end)
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, value ->
      if safe_capabilities?(value),
        do: [],
        else: [capabilities: "must contain only non-secret readiness metadata"]
    end)
  end

  @secret_key ~r/(token|secret|credential|password|authorization|cookie|key)$/i
  defp safe_capabilities?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      not Regex.match?(@secret_key, to_string(key)) and safe_capabilities?(value)
    end)
  end

  defp safe_capabilities?(list) when is_list(list), do: Enum.all?(list, &safe_capabilities?/1)

  defp safe_capabilities?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)
end
