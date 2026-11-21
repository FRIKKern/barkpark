defmodule BarkparkWeb.Studio.Desk.VisionListenStream do
  @moduledoc """
  One Vision Listen (`BarkparkWeb.Studio.Desk.VisionListen`): a process that
  subscribes to one dataset's document changes and tells the desk's LiveView
  about each change the listener may see, as `{:vision_listen, ref, message}`.

  It decides what passes the way the listen stream does
  (`BarkparkWeb.ListenController`), on the scope the desk's socket resolved,
  never on anything the browser sent:

    * The topic is the workspace's (`documents:ws:<ws>:<dataset>`), so another
      workspace's changes are never delivered here. Without a workspace, only
      the shared layer's topic is read, and only its changes pass.
    * Every change is checked again against the workspace
      (`ListenController.forward_event?/2`), then against the filter:
      `ListenFilter.pass_meta?/2` (types, perspective, the project, a preview
      token's documents), the document as this caller may see it
      (`ListenController.live_result/4`), `ListenFilter.pass_result?/2` and the
      query (`ListenFilter.query_step/3`).

  At most `@per_second` changes a second are passed on. The rest are counted
  and reported once the second is over (`{:skipped, n}`). A LiveView whose
  mailbox is already long gets nothing more until it is short again; those
  changes are counted the same way.

  The process ends on `stop/1`, and when the LiveView ends: it monitors it, so
  leaving the page, a crash or a closed tab all end the subscription. If it
  fails itself, it says `:closed` first.
  """

  alias BarkparkWeb.ListenController
  alias BarkparkWeb.ListenFilter

  @per_second 20
  @mailbox_limit 200

  @doc "The most changes a second one Listen passes on."
  def per_second, do: @per_second

  @doc """
  Start a Listen for `lv`, subscribed before this returns, so a change written
  after it is seen. `opts`: `:dataset`, `:scope` (the socket's `scope_opts`)
  and `:filter` (a `ListenFilter`, already narrowed to the scope).
  """
  @spec start(pid(), reference(), keyword()) :: {:ok, pid()}
  def start(lv, ref, opts) when is_pid(lv) and is_reference(ref) do
    caller = self()
    dataset = Keyword.fetch!(opts, :dataset)
    scope = Keyword.fetch!(opts, :scope)
    workspace = workspace(scope)

    state = %{
      lv: lv,
      ref: ref,
      dataset: dataset,
      scope: scope,
      workspace: workspace,
      caller_context: Keyword.get(scope, :caller_context),
      filter: Keyword.fetch!(opts, :filter),
      window: now(),
      sent: 0,
      skipped: 0,
      flush: nil
    }

    pid =
      spawn(fn ->
        monitor = Process.monitor(lv)
        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic(dataset, workspace))
        send(caller, {:vision_listen_ready, self()})
        state = Map.put(state, :monitor, monitor)

        try do
          run(state)
        rescue
          _ -> tell(state, :closed)
        end
      end)

    receive do
      {:vision_listen_ready, ^pid} -> {:ok, pid}
    after
      5_000 -> raise "Vision Listen did not subscribe"
    end
  end

  @doc "End a Listen. Its subscription ends with it."
  @spec stop(pid() | nil) :: :ok
  def stop(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def stop(_), do: :ok

  @doc """
  The workspace the stream is held to: the scope's, or `:shared_only` when it
  named none, so an unscoped socket hears the shared layer only (never every
  tenant, which is what `nil` means to `forward_event?/2`).
  """
  def workspace(scope) do
    case Keyword.get(scope, :workspace_id) do
      id when is_binary(id) -> id
      _ -> :shared_only
    end
  end

  @doc false
  def topic(dataset, workspace) when is_binary(workspace),
    do: Barkpark.Content.Broadcast.workspace_list_topic(dataset, workspace)

  def topic(dataset, :shared_only), do: Barkpark.Content.Broadcast.global_list_topic(dataset)

  defp run(state) do
    receive do
      {:DOWN, ref, :process, _, _} when ref == state.monitor ->
        :ok

      {:document_changed, %{event_id: _} = msg} ->
        state |> change(msg) |> run()

      {:document_changed, _} ->
        run(state)

      :vision_listen_flush ->
        state |> flush() |> run()

      _ ->
        run(state)
    end
  end

  defp change(state, msg) do
    case decide(state, msg) do
      {:send, event, filter} ->
        state |> Map.put(:filter, filter) |> pass(event)

      {:drop, filter} ->
        %{state | filter: filter}

      {:limit, message, _filter} ->
        tell(state, {:error, message})
        exit(:normal)
    end
  end

  # The listen stream's order: workspace, metadata, the document as this caller
  # may see it, its fields, then the query.
  @doc false
  def decide(state, msg) do
    with true <- ListenController.forward_event?(msg, state.workspace),
         true <- ListenFilter.pass_meta?(state.filter, msg),
         result when result != :drop <-
           ListenController.live_result(msg, state.dataset, state.caller_context, state.scope),
         true <- ListenFilter.pass_result?(state.filter, result),
         {:send, _transition, filter} <- ListenFilter.query_step(state.filter, msg.doc_id, result) do
      {:send, event(msg, result), filter}
    else
      {:drop, filter} -> {:drop, filter}
      {:limit, _message, _filter} = limit -> limit
      _ -> {:drop, state.filter}
    end
  end

  # As the listen stream's `mutation` event (`ListenController.format_event/2`).
  defp event(msg, result) do
    previous = Map.get(msg, :previous_rev)

    %{
      eventId: msg.event_id,
      mutation:
        if(msg.mutation == "create" and is_binary(previous), do: "update", else: msg.mutation),
      type: msg.type,
      documentId: msg.doc_id,
      rev: msg.rev,
      previousRev: previous,
      result: result
    }
  end

  defp pass(state, event) do
    state = roll(state)

    if state.sent < @per_second and not busy?(state.lv) do
      tell(state, {:mutation, event})
      %{state | sent: state.sent + 1}
    else
      later(%{state | skipped: state.skipped + 1})
    end
  end

  # A new second starts the count again.
  defp roll(state) do
    if now() - state.window >= 1_000, do: %{state | window: now(), sent: 0}, else: state
  end

  defp later(%{flush: nil} = state) do
    wait = max(1_000 - (now() - state.window), 0)
    %{state | flush: Process.send_after(self(), :vision_listen_flush, wait)}
  end

  defp later(state), do: state

  defp flush(%{skipped: 0} = state), do: %{state | flush: nil}

  defp flush(state) do
    tell(state, {:skipped, state.skipped})
    %{state | skipped: 0, flush: nil}
  end

  defp busy?(lv) do
    case Process.info(lv, :message_queue_len) do
      {:message_queue_len, n} -> n >= @mailbox_limit
      nil -> true
    end
  end

  defp tell(state, message) do
    send(state.lv, {:vision_listen, state.ref, message})
    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
