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

  @doc "Whether the selected provider runtime is available on this host."
  def enabled?(provider), do: optional_call(adapter(provider), :enabled?, [], false)

  def normalize_mode(provider, value),
    do: optional_call(adapter(provider), :normalize_mode, [value], value)

  def normalize_model(provider, value),
    do: optional_call(adapter(provider), :normalize_model, [value], nil)

  def normalize_effort(provider, value),
    do: optional_call(adapter(provider), :normalize_effort, [value], nil)

  def auth_failure?(provider, event),
    do: optional_call(adapter(provider), :auth_failure?, [event], false)

  def result_success?(provider, event),
    do: optional_call(adapter(provider), :result_success?, [event], false)

  def worker_id(provider, session_id),
    do: optional_call(adapter(provider), :worker_id, [session_id], nil)

  def task_hands(provider, runtime_ref),
    do: optional_call(adapter(provider), :task_hands, [runtime_ref], :not_attempted)

  @doc "Extract the supervised process behind an adapter-specific runtime reference."
  def runtime_pid(runtime_ref) when is_pid(runtime_ref), do: runtime_ref
  def runtime_pid(%{runtime: pid}) when is_pid(pid), do: pid
  def runtime_pid(_runtime_ref), do: nil

  def alive?(runtime_ref) do
    case runtime_pid(runtime_ref) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc "Extract an adapter-returned opaque provider session id when already known."
  def provider_session_id(%{provider_session_id: id}) when is_binary(id) and id != "", do: id
  def provider_session_id(_runtime_ref), do: nil

  def send_turn(provider, runtime_ref, content),
    do: adapter(provider).send_turn(runtime_ref, content)

  def steer(provider, runtime_ref, command), do: adapter(provider).steer(runtime_ref, command)
  def interrupt(provider, runtime_ref), do: adapter(provider).interrupt(runtime_ref)

  def answer_approval(provider, runtime_ref, approval_id, decision),
    do: adapter(provider).answer_approval(runtime_ref, approval_id, decision)

  def close(provider, runtime_ref), do: adapter(provider).close(runtime_ref)

  @doc "Run an optional provider initialization handshake."
  def initialize(provider, runtime_ref),
    do: optional_call(adapter(provider), :initialize, [runtime_ref])

  @doc "Move an existing runtime's event sink after Recorder recovery."
  def adopt_sink(provider, runtime_ref, sink),
    do: optional_call(adapter(provider), :adopt_sink, [runtime_ref, sink])

  @doc "Whether a provider-specific approval may be answered automatically."
  def auto_approve?(provider, approval),
    do: optional_call(adapter(provider), :auto_approve?, [approval], false)

  def cwd(provider), do: optional_call(adapter(provider), :cwd, [], nil)
  def tool_name(provider, name), do: optional_call(adapter(provider), :tool_name, [name], nil)

  def normalize_choice(provider, field, value) when field in [:models, :efforts] do
    allowed = Map.fetch!(capabilities(provider), field)
    if value in allowed, do: value, else: nil
  end

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

  defp optional_call(module, function, args, default \\ :ok) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: default
  end
end
