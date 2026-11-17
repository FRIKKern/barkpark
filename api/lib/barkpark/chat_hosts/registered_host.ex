defmodule Barkpark.ChatHosts.RegisteredHost do
  @moduledoc "Workspace-owned machine registered for outbound Studio Chat execution."

  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.StudioChat.Attachments
  alias Barkpark.StudioChat.NulText

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
  @host_declared_fields ~w(protocol_version capabilities)a

  def enrollment_changeset(host, attrs) do
    host
    |> cast(attrs, @enrollment_fields)
    |> validate_required([:workspace_id, :name, :enrollment_hash, :enrollment_expires_at])
    # `ChatHosts.issue_enrollment/2` takes the default for each of these only
    # when the key is ABSENT, so an owner's JSON null arrives as nil. All
    # three columns are NOT NULL: without this, a 500 (task-7f0bd4bfa363eb60).
    |> validate_required([:approved_roots, :protocol_version, :capabilities],
      message: "must not be null"
    )
    |> validate_length(:name, min: 1, max: 120)
    |> validate_protocol_version()
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
      :last_seen_at
    ])
    |> cast_host_declared(attrs)
    |> validate_required([:enrolled_at, :credential_hash, :credential_expires_at])
    |> validate_host_declared()
    |> validate_number(:credential_version, greater_than: 0)
    |> validate_protocol_version()
    |> validate_roots()
    |> validate_capabilities()
    |> check_constraint(:credential_hash, name: :registered_chat_hosts_credential_state)
  end

  def heartbeat_changeset(host, attrs) do
    host
    |> cast(attrs, [:last_seen_at])
    |> cast_host_declared(attrs)
    |> validate_host_declared()
    |> validate_protocol_version()
    |> validate_capabilities()
  end

  # The host sends these two on enroll and heartbeat. By default `cast/4`
  # swaps an empty value ("" or whitespace) for the field default BEFORE any
  # validation, so `capabilities: ""` became `%{}` and reset the stored map,
  # and `protocol_version: ""` became 1. With no empty values, a string is
  # cast as itself and refused as invalid (task-7dfa8c4e8a410e96). A map,
  # `%{}` included, is never an empty value, so the Go host's bodies cast as
  # before.
  defp cast_host_declared(changeset, attrs),
    do: cast(changeset, attrs, @host_declared_fields, empty_values: [])

  # The host sends these two on enroll and heartbeat. The context keeps the
  # stored value only when a key is ABSENT, so a key sent as JSON null casts
  # to a nil change, which `validate_number/3` and `validate_change/3` both
  # skip. Both columns are NOT NULL, so that nil used to reach Postgres and
  # raise: a 500 instead of this 422 (task-2cd727c3405afd23).
  defp validate_host_declared(changeset),
    do:
      validate_required(changeset, [:protocol_version, :capabilities],
        message: "must not be null"
      )

  # Only version 1 exists (the Go host sends the literal 1), and no contract
  # names a ceiling, so the bound is the column's: protocol_version is a
  # Postgres integer. Above it Postgrex raised DBConnection.EncodeError, a 500
  # on all three changesets (task-7dfa8c4e8a410e96).
  @protocol_version_max 2_147_483_647

  defp validate_protocol_version(changeset),
    do:
      validate_number(changeset, :protocol_version,
        greater_than: 0,
        less_than_or_equal_to: @protocol_version_max
      )

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

  # jsonb refuses U+0000 (22P05): a version or operations item holding it was a
  # 500 on enroll, heartbeat and the owner's issue (task-214ecfd6ffe27b56).
  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, value ->
      cond do
        NulText.check(value) != :ok ->
          [capabilities: "must not contain a NUL character (U+0000)"]

        safe_capabilities?(value) ->
          []

        true ->
          [capabilities: "must contain only non-secret readiness metadata"]
      end
    end)
  end

  # The shipped host binary (`cmd/barkpark-chat-host/main.go` `capabilities()`)
  # sends `chat_runtime: %{"protocol" => "bidirectional-v2"}` beside the other
  # two keys. Refusing it made every real enrollment and heartbeat fail
  # (task-c02eefeb0ed7381c). It is optional, because older hosts omit it. When
  # present it holds exactly one key, and that key's value is a protocol name
  # from this list, so it cannot carry a secret. Both sides are pinned by
  # `test/support/fixtures/chat_host_go_capabilities.json`.
  @capability_keys ~w(protocol_version providers chat_runtime)
  @chat_runtime_protocols ~w(bidirectional-v2)

  defp safe_capabilities?(map) when map == %{}, do: true

  defp safe_capabilities?(%{"protocol_version" => version, "providers" => providers} = map)
       when is_integer(version) and version > 0 and is_map(providers) do
    Enum.all?(Map.keys(map), &(&1 in @capability_keys)) and
      safe_chat_runtime?(Map.get(map, "chat_runtime")) and
      Enum.all?(providers, fn
        # Only claude works in a bot folder (StudioChat.BotFolder): a codex
        # entry claiming it is a host bug, refused rather than stored.
        {"codex", %{"bot_folders" => _}} ->
          false

        {provider, metadata} when provider in ["claude", "codex"] ->
          safe_provider_metadata?(metadata)

        _ ->
          false
      end)
  end

  defp safe_capabilities?(_), do: false

  defp safe_chat_runtime?(nil), do: true

  defp safe_chat_runtime?(%{"protocol" => protocol} = map)
       when map_size(map) == 1 and protocol in @chat_runtime_protocols,
       do: true

  defp safe_chat_runtime?(_), do: false

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
  @provider_metadata_keys ~w(installed auth_ready version operations task_hands attachments bot_folders)

  defp safe_provider_metadata?(%{"installed" => installed, "auth_ready" => auth_ready} = map)
       when is_boolean(installed) and is_boolean(auth_ready) do
    Enum.all?(Map.keys(map), &(&1 in @provider_metadata_keys)) and
      safe_version?(Map.get(map, "version")) and
      safe_operations?(Map.get(map, "operations")) and
      safe_task_hands?(Map.get(map, "task_hands")) and
      safe_attachments?(Map.get(map, "attachments")) and
      safe_bot_folders?(Map.get(map, "bot_folders"))
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

  # The attachment types this provider on the host can take: images as image
  # blocks (Paper chat-host-attachments-plan) and the two file types written to
  # its working folder (chat-host-file-attachments-plan). `TurnAttachments.admit/3`
  # reads it before a send_turn that carries attachment references is leased;
  # absent means none. Every value is one of the chat store's own types and none
  # repeats, so the list is at most six fixed strings and cannot carry a secret.
  @attachment_types Attachments.media_types() ++ Attachments.file_types()

  defp safe_attachments?(nil), do: true

  defp safe_attachments?(types) when is_list(types),
    do: Enum.all?(types, &(&1 in @attachment_types)) and Enum.uniq(types) == types

  defp safe_attachments?(_), do: false

  # The host makes and uses a bot folder under its root when a turn names one
  # (task-ed93b8c0ab2b44b8). `BotFolder.admit/3` leases such a turn only to a
  # host that says `true`; absent means it cannot. A boolean carries no secret.
  defp safe_bot_folders?(nil), do: true
  defp safe_bot_folders?(value), do: is_boolean(value)
end
