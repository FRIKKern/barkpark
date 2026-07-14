defmodule Barkpark.StudioChat.RuntimeAdmission do
  @moduledoc """
  Conservative node-local admission for managed Studio Chat runtimes.

  A lease is registered to the owning Recorder in its existing Registry. The
  Registry removes it automatically if the Recorder dies, and explicit release
  remains idempotent for normal close/open-error paths. Registered-host work is
  deliberately not counted because its process runs on another machine.
  """

  @registry Barkpark.StudioChat.RecorderRegistry
  @default_limit 3
  @key_tag :managed_runtime_admission

  defmodule Lease do
    @moduledoc false
    @enforce_keys [:runtime_id, :registry, :key, :limit]
    defstruct [:runtime_id, :registry, :key, :limit]

    @type t :: %__MODULE__{
            runtime_id: String.t(),
            registry: atom(),
            key: term(),
            limit: pos_integer()
          }
  end

  @type lease :: Lease.t() | :not_managed

  @doc "Acquire one managed-runtime slot or return deterministic backpressure."
  @spec acquire(String.t(), map() | keyword()) :: {:ok, lease()} | {:error, term()}
  def acquire(session_id, opts) when is_binary(session_id) do
    if value(opts, :execution_target, "managed") == "registered_host" do
      {:ok, :not_managed}
    else
      registry = value(opts, :admission_registry, @registry)
      limit = configured_limit(opts)

      :global.trans({__MODULE__, registry}, fn ->
        if active_count(registry) >= limit do
          {:error, {:managed_runtime_capacity, limit}}
        else
          runtime_id = Ecto.UUID.generate()
          key = {@key_tag, runtime_id}

          case Registry.register(registry, key, %{session_id: session_id}) do
            {:ok, _} ->
              {:ok, %Lease{runtime_id: runtime_id, registry: registry, key: key, limit: limit}}

            {:error, {:already_registered, _pid}} ->
              {:error, :admission_registration_conflict}
          end
        end
      end)
    end
  end

  @doc "Release a lease. Repeated and non-managed releases are harmless."
  @spec release(lease()) :: :ok
  def release(:not_managed), do: :ok

  def release(%Lease{registry: registry, key: key}) do
    Registry.unregister(registry, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Count live managed-runtime leases in a registry."
  def active_count(registry \\ @registry) do
    Registry.select(registry, [
      {{{@key_tag, :"$1"}, :"$2", :"$3"}, [], [true]}
    ])
    |> length()
  rescue
    ArgumentError -> 0
  end

  defp configured_limit(opts) do
    candidate =
      value(opts, :managed_runtime_limit) ||
        Application.get_env(:barkpark, __MODULE__, [])
        |> Keyword.get(:max_managed_runtimes)

    if is_integer(candidate) and candidate > 0, do: candidate, else: @default_limit
  end

  defp value(opts, key, default \\ nil)
  defp value(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp value(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
