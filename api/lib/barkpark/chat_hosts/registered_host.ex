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

  defp safe_capabilities?(map) when map == %{}, do: true

  defp safe_capabilities?(%{"protocol_version" => version, "providers" => providers} = map)
       when is_integer(version) and version > 0 and map_size(map) == 2 and is_map(providers) do
    Enum.all?(providers, fn
      {provider, metadata} when provider in ["claude", "codex"] ->
        safe_provider_metadata?(metadata)

      _ ->
        false
    end)
  end

  defp safe_capabilities?(_), do: false

  # Non-secret provider readiness the host declares over the wire. `operations`
  # and `task_hands` are protocol-readiness facts the dispatch gate
  # (`Runtime.registered_provider_ready/2`) actually reads: without persisting
  # them here, a real host could store `installed`/`auth_ready`/`version` only,
  # so the gate — which ALSO demands the full `operations` set and
  # `task_hands == true` — could never pass on the public wire (only an in-memory
  # test fake, built past this changeset, ever satisfied it). They carry no
  # secret: `operations` is a bounded list of short command-name strings and
  # `task_hands` is a boolean, so admitting them keeps the "only non-secret
  # readiness metadata" invariant while making a genuine host reachable.
  @provider_metadata_keys ~w(installed auth_ready version operations task_hands)

  defp safe_provider_metadata?(%{"installed" => installed, "auth_ready" => auth_ready} = map)
       when is_boolean(installed) and is_boolean(auth_ready) do
    Enum.all?(Map.keys(map), &(&1 in @provider_metadata_keys)) and
      safe_version?(Map.get(map, "version")) and
      safe_operations?(Map.get(map, "operations")) and
      safe_task_hands?(Map.get(map, "task_hands"))
  end

  defp safe_provider_metadata?(_), do: false

  defp safe_version?(nil), do: true
  defp safe_version?(version) when is_binary(version), do: byte_size(version) <= 200
  defp safe_version?(_), do: false

  # Absent is fine (the gate reads it as "no operations declared" and refuses);
  # when present it must be a list of short, non-secret command-name strings.
  defp safe_operations?(nil), do: true

  defp safe_operations?(operations) when is_list(operations),
    do: Enum.all?(operations, &(is_binary(&1) and byte_size(&1) <= 64))

  defp safe_operations?(_), do: false

  defp safe_task_hands?(nil), do: true
  defp safe_task_hands?(value) when is_boolean(value), do: true
  defp safe_task_hands?(_), do: false
end
