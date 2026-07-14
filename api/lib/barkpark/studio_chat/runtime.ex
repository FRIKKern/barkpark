defmodule Barkpark.StudioChat.Runtime do
  @moduledoc """
  Provider-neutral command and event boundary for Studio Chat.

  The public Barkpark session id, provider-native session id, provider, and
  execution target remain distinct across this boundary. Managed runtimes call
  an `Adapter` locally; registered-host runtimes resolve the selected host and
  hand the same command to `RemoteDispatch`. Only `Recorder` projects returned
  events into durable chat rows.
  """

  alias Barkpark.StudioChat.Runtime.Claude

  @typedoc "A provider name persisted on a chat session."
  @type provider :: String.t()
  @type execution_target :: String.t()
  @type runtime_ref :: term()

  defmodule Adapter do
    @moduledoc "Lifecycle contract implemented by each managed provider runtime."

    @callback start(map()) :: {:ok, term()} | {:error, term()}
    @callback resume(map()) :: {:ok, term()} | {:error, term()}
    @callback send_turn(term(), String.t() | [map()]) :: :ok | {:error, term()}
    @callback steer(term(), map()) :: {:ok, term()} | :ok | {:error, term()}
    @callback interrupt(term()) :: {:ok, term()} | {:error, term()}
    @callback answer_approval(term(), String.t(), term()) :: :ok | {:error, term()}
    @callback close(term()) :: :ok | {:error, term()}
    @callback readiness(map()) :: map() | {:ok, map()} | {:error, term()}
    @callback capabilities() :: struct() | map()
  end

  defmodule HostDirectory do
    @moduledoc "Workspace-scoped registered-host lookup contract."

    @callback resolve(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  end

  defmodule RemoteDispatch do
    @moduledoc "Transport-neutral command dispatch contract for a resolved host."

    @callback dispatch(map(), Barkpark.StudioChat.Runtime.Command.t(), keyword()) ::
                {:ok, term()} | :ok | {:error, term()}
  end

  defmodule Command do
    @moduledoc "A fenced, idempotent runtime command suitable for local or remote execution."

    @enforce_keys [:operation, :provider, :session_id]
    defstruct operation: nil,
              provider: nil,
              session_id: nil,
              provider_session_id: nil,
              turn_id: nil,
              item_id: nil,
              approval_id: nil,
              idempotency_key: nil,
              payload: %{}

    @type t :: %__MODULE__{
            operation: atom(),
            provider: Barkpark.StudioChat.Runtime.provider(),
            session_id: String.t(),
            provider_session_id: String.t() | nil,
            turn_id: String.t() | nil,
            item_id: String.t() | nil,
            approval_id: String.t() | nil,
            idempotency_key: String.t() | nil,
            payload: map()
          }
  end

  defmodule Event do
    @moduledoc "Normalized provider event. `native` retains the lossless provider envelope."

    defstruct version: 1,
              provider: nil,
              session_id: nil,
              provider_session_id: nil,
              turn_id: nil,
              item_id: nil,
              sequence: nil,
              idempotency_key: nil,
              durability: :delta,
              kind: nil,
              approval_id: nil,
              terminal_state: nil,
              error: nil,
              native: %{}

    @type t :: %__MODULE__{
            version: pos_integer(),
            provider: Barkpark.StudioChat.Runtime.provider(),
            session_id: String.t(),
            provider_session_id: String.t() | nil,
            turn_id: String.t() | nil,
            item_id: String.t() | nil,
            sequence: non_neg_integer() | nil,
            idempotency_key: String.t() | nil,
            durability: :durable | :delta,
            kind: atom() | String.t(),
            approval_id: String.t() | nil,
            terminal_state: atom() | String.t() | nil,
            error: map() | nil,
            native: map()
          }
  end

  @doc "Resolve the configured managed adapter without coupling callers to a provider module."
  @spec adapter(provider() | atom()) :: module()
  def adapter(provider) when provider in ["claude", :claude],
    do: configured_adapter(:claude, Claude)

  def adapter(provider) when provider in ["codex", :codex] do
    configured_adapter(:codex, Barkpark.StudioChat.Runtime.Codex)
  end

  @doc "Provider-scoped readiness."
  def readiness(provider, opts \\ %{}), do: adapter(provider).readiness(opts)

  @doc "Provider-scoped capability matrix."
  def capabilities(provider), do: adapter(provider).capabilities()

  @doc "Start or resume a managed runtime using one provider-neutral entry point."
  def open(provider, opts) when is_map(opts) do
    runtime = adapter(provider)
    if Map.get(opts, :resume, false), do: runtime.resume(opts), else: runtime.start(opts)
  end

  @doc "Dispatch one command to managed compute or a registered host."
  def dispatch(execution_target, provider, command, opts \\ [])

  def dispatch("managed", provider, %Command{} = command, opts) do
    dispatch_managed(adapter(provider), command, opts)
  end

  def dispatch("registered_host", _provider, %Command{} = command, opts) do
    with {:ok, directory} <- fetch_contract(:host_directory, opts),
         {:ok, dispatcher} <- fetch_contract(:remote_dispatch, opts),
         {:ok, host} <- directory.resolve(opts[:workspace_id], opts[:execution_host_id]) do
      dispatcher.dispatch(host, command, opts)
    end
  end

  defp dispatch_managed(adapter, %Command{operation: :start, payload: payload}, _opts),
    do: adapter.start(payload)

  defp dispatch_managed(adapter, %Command{operation: :resume, payload: payload}, _opts),
    do: adapter.resume(payload)

  defp dispatch_managed(
         adapter,
         %Command{operation: :send_turn, payload: %{runtime: ref, content: content}},
         _opts
       ),
       do: adapter.send_turn(ref, content)

  defp dispatch_managed(
         adapter,
         %Command{operation: :steer, payload: %{runtime: ref} = payload},
         _opts
       ),
       do: adapter.steer(ref, Map.delete(payload, :runtime))

  defp dispatch_managed(
         adapter,
         %Command{operation: :interrupt, payload: %{runtime: ref}},
         _opts
       ),
       do: adapter.interrupt(ref)

  defp dispatch_managed(
         adapter,
         %Command{
           operation: :answer_approval,
           approval_id: approval_id,
           payload: %{runtime: ref, decision: decision}
         },
         _opts
       ),
       do: adapter.answer_approval(ref, approval_id, decision)

  defp dispatch_managed(adapter, %Command{operation: :close, payload: %{runtime: ref}}, _opts),
    do: adapter.close(ref)

  defp dispatch_managed(_adapter, %Command{operation: operation}, _opts),
    do: {:error, {:unsupported_runtime_operation, operation}}

  defp configured_adapter(provider, default) do
    :barkpark
    |> Application.get_env(:studio_chat_runtime_adapters, %{})
    |> Map.get(provider, default)
  end

  defp fetch_contract(key, opts) do
    case Keyword.get(opts, key) || Application.get_env(:barkpark, key) do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, {:missing_runtime_contract, key}}
    end
  end
end
