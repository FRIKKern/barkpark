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
  alias Barkpark.StudioChat.RuntimeAdmission
  alias Barkpark.StudioChat.RuntimeTelemetry

  @typedoc "A provider name persisted on a chat session."
  @type provider :: String.t()
  @type execution_target :: String.t()
  @type runtime_ref :: term()
  @remote_operations ~w(send_turn steer interrupt answer_approval close)
  @no_task_hands "__BARKPARK_CHAT_NO_TASK_HANDS__"

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
              usage: nil,
              observed_model: nil,
              observed_effort: nil,
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
            usage: map() | nil,
            observed_model: String.t() | nil,
            observed_effort: String.t() | nil,
            native: map()
          }
  end

  defmodule RemoteRef do
    @moduledoc "Opaque handle for a provider runtime executing on a registered host."

    @enforce_keys [:provider, :session_id, :workspace_id, :execution_host_id]
    defstruct [
      :provider,
      :session_id,
      :provider_session_id,
      :workspace_id,
      :execution_host_id,
      :cwd,
      :host_directory,
      :remote_dispatch,
      :lease_id,
      :task_hands,
      :task_token,
      :task_secret_id,
      :developer_instructions,
      :mode,
      :model,
      :effort,
      :bypass_armed
    ]
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

  def task_hands(_provider, %RemoteRef{task_hands: status}), do: status || :not_attempted

  def task_hands(provider, runtime_ref),
    do: optional_call(adapter(provider), :task_hands, [runtime_ref], :not_attempted)

  @doc "Extract the supervised process behind an adapter-specific runtime reference."
  def runtime_pid(runtime_ref) when is_pid(runtime_ref), do: runtime_ref
  def runtime_pid(%{runtime: pid}) when is_pid(pid), do: pid
  def runtime_pid(_runtime_ref), do: nil

  def alive?(%RemoteRef{} = ref) do
    match?({:ok, _host}, ref.host_directory.resolve(ref.workspace_id, ref.execution_host_id))
  rescue
    _ -> false
  end

  def alive?(runtime_ref) do
    case runtime_pid(runtime_ref) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc "Sample only non-secret, process-local identity for a runtime."
  def runtime_identity(%RemoteRef{}, :not_managed) do
    %{
      execution_target: "registered_host",
      status: "unsupported",
      runtime_id: nil,
      beam_pid: nil,
      os_pid: nil,
      memory_bytes: nil,
      reductions: nil,
      message_queue_len: nil,
      provider_memory_bytes: nil,
      provider_cpu_percent: nil,
      metric_provenance: %{},
      sampled_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      limitations: RuntimeTelemetry.registered_host_limitations()
    }
  end

  def runtime_identity(runtime_ref, %RuntimeAdmission.Lease{runtime_id: runtime_id}) do
    sampled_at = DateTime.utc_now() |> DateTime.to_iso8601()

    case runtime_pid(runtime_ref) do
      pid when is_pid(pid) ->
        info = Process.info(pid, [:memory, :reductions, :message_queue_len, :links]) || []

        %{
          execution_target: "managed",
          status: if(Process.alive?(pid), do: "observed", else: "unknown"),
          runtime_id: runtime_id,
          beam_pid: inspect(pid),
          os_pid: linked_os_pid(info[:links]),
          memory_bytes: info[:memory],
          reductions: info[:reductions],
          message_queue_len: info[:message_queue_len],
          provider_memory_bytes: nil,
          provider_cpu_percent: nil,
          metric_provenance: %{
            beam_pid: "beam_adapter_process",
            memory_bytes: "beam_adapter_process",
            reductions: "beam_adapter_process",
            message_queue_len: "beam_adapter_process",
            os_pid: "provider_process"
          },
          node: node(pid) |> Atom.to_string(),
          sampled_at: sampled_at,
          limitations: RuntimeTelemetry.managed_runtime_limitations()
        }

      _ ->
        %{
          execution_target: "managed",
          status: "unknown",
          runtime_id: runtime_id,
          beam_pid: nil,
          os_pid: nil,
          memory_bytes: nil,
          reductions: nil,
          message_queue_len: nil,
          provider_memory_bytes: nil,
          provider_cpu_percent: nil,
          metric_provenance: %{},
          sampled_at: sampled_at,
          limitations: [
            "managed runtime process was not alive when sampled"
            | RuntimeTelemetry.managed_runtime_limitations()
          ]
        }
    end
  end

  @doc "Extract an adapter-returned opaque provider session id when already known."
  def provider_session_id(%{provider_session_id: id}) when is_binary(id) and id != "", do: id
  def provider_session_id(_runtime_ref), do: nil

  def with_provider_session_id(%RemoteRef{} = runtime_ref, id)
      when is_binary(id) and id != "",
      do: %{runtime_ref | provider_session_id: id}

  def with_provider_session_id(runtime_ref, id)
      when is_map(runtime_ref) and is_binary(id) and id != "",
      do: Map.put(runtime_ref, :provider_session_id, id)

  def with_provider_session_id(runtime_ref, _id), do: runtime_ref

  def send_turn(_provider, %RemoteRef{} = runtime_ref, content),
    do: dispatch_remote(runtime_ref, :send_turn, %{content: content})

  def send_turn(provider, runtime_ref, content),
    do: adapter(provider).send_turn(runtime_ref, content)

  def steer(_provider, %RemoteRef{} = runtime_ref, command),
    do: dispatch_remote(runtime_ref, :steer, command)

  def steer(provider, runtime_ref, command), do: adapter(provider).steer(runtime_ref, command)

  def interrupt(_provider, %RemoteRef{} = runtime_ref),
    do: dispatch_remote(runtime_ref, :interrupt, %{})

  def interrupt(provider, runtime_ref), do: adapter(provider).interrupt(runtime_ref)

  def answer_approval(_provider, %RemoteRef{} = runtime_ref, approval_id, decision),
    do:
      dispatch_remote(runtime_ref, :answer_approval, %{decision: remote_decision(decision)},
        approval_id: approval_id
      )

  def answer_approval(provider, runtime_ref, approval_id, decision),
    do: adapter(provider).answer_approval(runtime_ref, approval_id, decision)

  def close(_provider, %RemoteRef{} = runtime_ref) do
    result = dispatch_remote(runtime_ref, :close, %{})
    cleanup_remote_task_hands(runtime_ref)
    result
  end

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
  def open(provider, %{execution_target: "registered_host"} = opts) do
    session_opts = Map.get(opts, :session_opts, %{})

    ref = %RemoteRef{
      provider: to_string(provider),
      session_id: Map.fetch!(opts, :session_id),
      provider_session_id: Map.get(opts, :provider_session_id),
      workspace_id: Map.fetch!(opts, :workspace_id),
      execution_host_id: Map.fetch!(opts, :execution_host_id),
      cwd: Map.get(opts, :cwd),
      host_directory: Map.get(opts, :host_directory, Barkpark.ChatHosts),
      remote_dispatch: Map.get(opts, :remote_dispatch, Barkpark.ChatHosts.RemoteDispatch),
      developer_instructions: Map.get(opts, :developer_instructions),
      mode: Map.get(opts, :mode),
      model: Map.get(session_opts, :model),
      effort: Map.get(session_opts, :effort),
      bypass_armed: Map.get(session_opts, :bypass_armed, false)
    }

    case ref.host_directory.resolve(ref.workspace_id, ref.execution_host_id) do
      {:ok, host} ->
        with :ok <- registered_provider_ready(host, ref.provider) do
          task_hands = setup_remote_task_hands(opts, ref)

          {:ok,
           %{
             ref
             | cwd: registered_host_cwd(host, ref.cwd),
               task_hands: task_hands.status,
               task_token: task_hands.token,
               task_secret_id: task_hands.secret_id
           }}
        end

      error ->
        error
    end
  end

  def open(provider, opts) when is_map(opts) do
    runtime = adapter(provider)
    opts = managed_options(provider, opts)
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

  # Recorder stores user choices under :session_opts for the provider-neutral
  # registered-host command. Managed adapters historically received that map
  # unchanged, while Codex's app-server seam reads top-level options. Flatten
  # the safe model/effort pair and, for the production Codex binary, configure
  # the per-process app-server so resume and start resolve the same values.
  defp managed_options(provider, opts) do
    session_opts = Map.get(opts, :session_opts, %{})

    opts =
      opts
      |> maybe_put_runtime_option(:model, Map.get(session_opts, :model))
      |> maybe_put_runtime_option(:effort, Map.get(session_opts, :effort))

    if provider in ["codex", :codex] and not Map.has_key?(opts, :args) do
      Map.put(opts, :args, codex_app_server_args(opts))
    else
      opts
    end
  end

  defp codex_app_server_args(opts) do
    ["app-server", "--stdio"]
    |> append_codex_config("model", Map.get(opts, :model))
    |> append_codex_config("model_reasoning_effort", Map.get(opts, :effort))
  end

  defp append_codex_config(args, _key, nil), do: args

  defp append_codex_config(args, key, value) when is_binary(value) do
    args ++ ["--config", "#{key}=#{Jason.encode!(value)}"]
  end

  defp linked_os_pid(links) when is_list(links) do
    Enum.find_value(links, fn
      port when is_port(port) ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) -> pid
          _ -> nil
        end

      _ ->
        nil
    end)
  rescue
    ArgumentError -> nil
  end

  defp linked_os_pid(_), do: nil

  defp dispatch_remote(%RemoteRef{} = ref, operation, payload, command_opts \\ []) do
    payload =
      if operation == :send_turn do
        payload
        |> Map.put(:cwd, ref.cwd)
        |> maybe_put_developer_instructions(ref.developer_instructions)
        |> maybe_put_runtime_option(:mode, ref.mode)
        |> maybe_put_runtime_option(:model, ref.model)
        |> maybe_put_runtime_option(:effort, ref.effort)
        |> maybe_put_runtime_option(:bypass_armed, ref.bypass_armed)
        |> maybe_put_task_env(remote_task_env(ref))
      else
        payload
      end

    command = %Command{
      operation: operation,
      provider: ref.provider,
      session_id: ref.session_id,
      provider_session_id: ref.provider_session_id,
      approval_id: command_opts[:approval_id],
      idempotency_key: Ecto.UUID.generate(),
      payload: payload
    }

    opts = [
      workspace_id: ref.workspace_id,
      execution_host_id: ref.execution_host_id,
      host_directory: ref.host_directory,
      remote_dispatch: ref.remote_dispatch
    ]

    case dispatch("registered_host", ref.provider, command, opts) do
      {:ok, result} when operation in [:start, :resume] ->
        {:ok, result}

      {:ok, _result} when operation in [:steer, :interrupt] ->
        {:ok, command.idempotency_key}

      {:ok, _result} ->
        :ok

      other ->
        other
    end
  end

  defp registered_host_cwd(host, fallback) do
    case Map.get(host, :approved_roots) || Map.get(host, "approved_roots") do
      [root | _] when is_binary(root) -> root
      _ -> fallback
    end
  end

  defp registered_provider_ready(host, provider) do
    capabilities = Map.get(host, :capabilities) || Map.get(host, "capabilities") || %{}
    providers = Map.get(capabilities, "providers") || Map.get(capabilities, :providers) || %{}

    readiness =
      Map.get(providers, provider) || Map.get(providers, String.to_atom(provider)) || %{}

    cond do
      value(readiness, :installed) != true or value(readiness, :auth_ready) != true ->
        {:error, {:provider_not_ready, provider}}

      not Enum.all?(@remote_operations, &(&1 in value(readiness, :operations, []))) ->
        {:error, {:provider_protocol_incompatible, provider}}

      value(readiness, :task_hands) != true ->
        {:error, {:provider_protocol_incompatible, provider}}

      true ->
        :ok
    end
  end

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp setup_remote_task_hands(opts, ref) do
    minter = Map.get(opts, :minter)

    if is_nil(minter) do
      %{status: :not_attempted, token: nil, secret_id: nil}
    else
      case Barkpark.Auth.create_claude_session_token(minter, ref.session_id,
             workspace_id: ref.workspace_id
           ) do
        {:ok, {raw, token}} ->
          env = remote_task_env(raw, ref)
          secret_id = Barkpark.StudioChat.Runtime.RemoteSecrets.put(env)
          %{status: :minted, token: token, secret_id: secret_id}

        {:error, _reason} ->
          %{status: :mint_refused, token: nil, secret_id: nil}
      end
    end
  rescue
    _ -> %{status: :mint_refused, token: nil, secret_id: nil}
  end

  defp remote_task_env(raw, ref) do
    %{
      "BARKPARK_API_TOKEN" => raw,
      "BARKPARK_API_URL" => remote_mcp_api_url(),
      "BARKPARK_WORKER_ID" => "#{ref.provider}-chat-#{ref.session_id}"
    }
  end

  defp remote_task_env(%RemoteRef{task_secret_id: secret_id} = ref) do
    case Barkpark.StudioChat.Runtime.RemoteSecrets.fetch(secret_id) do
      env when is_map(env) -> env
      _ -> no_task_hands_env(ref)
    end
  end

  defp no_task_hands_env(ref) do
    %{
      "BARKPARK_API_TOKEN" => @no_task_hands,
      "BARKPARK_API_URL" => remote_mcp_api_url(),
      "BARKPARK_WORKER_ID" => "#{ref.provider}-chat-#{ref.session_id}"
    }
  end

  defp maybe_put_task_env(payload, env) when is_map(env) and map_size(env) > 0,
    do: Map.put(payload, :task_env, env)

  defp maybe_put_task_env(payload, _env), do: payload

  defp maybe_put_developer_instructions(payload, instructions)
       when is_binary(instructions) and instructions != "",
       do: Map.put(payload, :developer_instructions, instructions)

  defp maybe_put_developer_instructions(payload, _instructions), do: payload

  defp maybe_put_runtime_option(payload, _key, nil), do: payload
  defp maybe_put_runtime_option(payload, _key, false), do: payload
  defp maybe_put_runtime_option(payload, key, value), do: Map.put(payload, key, value)

  defp remote_mcp_api_url do
    studio_config = Application.get_env(:barkpark, :studio_chat, [])

    Keyword.get(studio_config, :remote_mcp_api_url) || BarkparkWeb.Endpoint.url()
  end

  defp remote_decision(:allow), do: "allow"
  defp remote_decision(:allow_session), do: "allow_session"
  defp remote_decision(:cancel), do: "cancel"

  defp remote_decision({:allow, value}) when is_map(value),
    do: %{"kind" => "allow", "value" => value}

  defp remote_decision({:deny, message}), do: %{"kind" => "deny", "value" => to_string(message)}
  defp remote_decision(value) when is_binary(value), do: value
  defp remote_decision(_value), do: "deny"

  defp cleanup_remote_task_token(nil), do: :ok

  defp cleanup_remote_task_token(%{id: id}) when is_binary(id) do
    Barkpark.Auth.revoke_token(id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp cleanup_remote_task_hands(%RemoteRef{} = ref) do
    cleanup_remote_task_token(ref.task_token)
    Barkpark.StudioChat.Runtime.RemoteSecrets.delete(ref.task_secret_id)
  catch
    :exit, _ -> :ok
  end

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
