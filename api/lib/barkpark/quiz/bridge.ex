defmodule Barkpark.Quiz.Bridge do
  @moduledoc """
  P4 live-edit bridge (`/papers/hyperquiz-content-model`) — the differentiator:
  a Studio edit to a quiz updates the running game in the same second.

  Subscribes to the dataset's document-mutation topic (`documents:<dataset>`,
  the same fan-out `Content.broadcast_document_mutation/3` emits). When a `quiz`
  document changes, every live room bound to that quiz reloads it
  (`Barkpark.Quiz.Content.load_question/2`) and the new question is applied to the
  room (`Barkpark.Quiz.Room.apply_question/2`), which broadcasts
  `{:question_updated, question}` to players — no reconnect, no redeploy.

  The bridge holds the quiz_id → room-pins index and does the DB read, so the
  Room stays pure/in-memory. Stale pins are harmless: `apply_question/2` no-ops
  on a dead room.
  """
  use GenServer

  alias Barkpark.Quiz

  @pubsub Barkpark.PubSub
  @default_dataset "production"

  # TEST-ONLY SEAM. `test/barkpark/quiz/bridge_sandbox_cascade_test.exs` has to
  # observe the Bridge *while it holds the sandbox owner's connection*, and
  # racing that window from outside is what made that test flake on main (row
  # task-954f4dc7f924c359, run 33946170394). This attribute is resolved at
  # COMPILE time: outside `MIX_ENV=test` it is `false`, the hook clause below
  # compiles to `:ok`, and no Application lookup ever runs in dev or prod —
  # apply_now/3 does exactly the work it did before.
  @read_hook_enabled Mix.env() == :test

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Bind a room (by PIN) to a quiz id: load the quiz's current question into the
  room now, and re-apply it on every future publish of that quiz.
  """
  @spec bind(String.t(), String.t(), String.t()) :: :ok
  def bind(pin, quiz_id, dataset \\ @default_dataset),
    do: GenServer.call(__MODULE__, {:bind, pin, quiz_id, dataset})

  @impl true
  def init(opts) do
    dataset = Keyword.get(opts, :dataset, @default_dataset)
    # As a PLUGIN worker (register_workers/1) the Bridge starts BEFORE the host's
    # Phoenix.PubSub child (application.ex splices plugin_children ahead of
    # PubSub), so subscribing synchronously here would crash the boot. Defer the
    # default-dataset subscribe to a self-message that retries until PubSub is
    # alive. `datasets` starts EMPTY and tracks what we've actually subscribed —
    # bind/3 subscribes any not-yet-seen dataset on demand the same way.
    send(self(), {:subscribe, dataset})
    {:ok, %{datasets: MapSet.new(), bindings: %{}}}
  end

  @impl true
  def handle_call({:bind, pin, quiz_id, dataset}, _from, state) do
    # Each binding records its OWN dataset; subscribe to every bound dataset's
    # topic so a room on a non-default dataset still gets live edits.
    state = ensure_subscribed(dataset, state)
    apply_now(pin, quiz_id, dataset)
    # Index pins BY pin → its own dataset (not one dataset per quiz_id): the same
    # quiz_id bound in two datasets must reload each pin from the dataset it bound,
    # never cross-inject one dataset's content into the other's room.
    pins = state.bindings |> Map.get(quiz_id, %{}) |> Map.put(pin, dataset)
    {:reply, :ok, put_in(state.bindings[quiz_id], pins)}
  end

  @impl true
  def handle_info({:subscribe, dataset}, state) do
    {:noreply, ensure_subscribed(dataset, state)}
  end

  def handle_info({:document_changed, %{type: "quiz", doc_id: doc_id}}, state) do
    quiz_id = published_id(doc_id)

    # Each pin reloads from ITS OWN dataset (the read is dataset-scoped). A change
    # in one dataset re-applies the correct per-pin content; no cross-injection.
    for {pin, dataset} <- Map.get(state.bindings, quiz_id, %{}) do
      apply_now(pin, quiz_id, dataset)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Subscribe to a dataset's mutation topic exactly once. If PubSub isn't up yet
  # (boot race — plugin workers precede the host PubSub child), reschedule and
  # retry; at runtime PubSub is always alive so this subscribes on the first try.
  defp ensure_subscribed(dataset, state) do
    if MapSet.member?(state.datasets, dataset) do
      state
    else
      case safe_subscribe(dataset) do
        :ok ->
          %{state | datasets: MapSet.put(state.datasets, dataset)}

        :retry ->
          Process.send_after(self(), {:subscribe, dataset}, 50)
          state
      end
    end
  end

  defp safe_subscribe(dataset) do
    Phoenix.PubSub.subscribe(@pubsub, "documents:#{dataset}")
    :ok
  rescue
    # Phoenix.PubSub.subscribe raises ArgumentError when the named PubSub isn't
    # started yet — the only failure mode here (the topic is always well-formed).
    ArgumentError -> :retry
  catch
    :exit, _ -> :retry
  end

  # A load failure (DB hiccup, transient error) must never crash the bridge —
  # that would drop every room↔quiz binding. Skip this update and carry on.
  defp apply_now(pin, quiz_id, dataset) do
    before_read(quiz_id, dataset)

    case Quiz.load_question(quiz_id, dataset) do
      {:ok, question} -> Quiz.apply_question(pin, question)
      {:error, _} -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # The seam itself. Armed only by a test, only under MIX_ENV=test, and any
  # error it raises is swallowed by apply_now/3's own rescue — the same
  # protection a load failure already gets.
  if @read_hook_enabled do
    defp before_read(quiz_id, dataset) do
      case Application.get_env(:barkpark, :quiz_bridge_before_read) do
        fun when is_function(fun, 2) -> fun.(quiz_id, dataset)
        _ -> :ok
      end
    end
  else
    defp before_read(_quiz_id, _dataset), do: :ok
  end

  defp published_id("drafts." <> id), do: id
  defp published_id(id), do: id
end
