defmodule Barkpark.Quiz.Bridge do
  @moduledoc """
  P4 live-edit bridge (`/papers/hyperquiz-content-model`) — the differentiator:
  a Studio edit to a quiz updates the running game in the same second.

  Subscribes to the dataset's document-list topics the way any tenant-scoped
  consumer does (`Content.Broadcast.subscribe_documents/2`): the global
  `documents:<dataset>` topic (shared layer) PLUS the seeded Default
  workspace's keyed topic `documents:ws:<default>:<dataset>` — see
  `safe_subscribe/1` for why THAT workspace. When a `quiz` document changes,
  every live room bound to that quiz reloads it
  (`Barkpark.Quiz.Content.load_question/2`) and the new question is applied to the
  room (`Barkpark.Quiz.Room.apply_question/2`), which broadcasts
  `{:question_updated, question}` to players — no reconnect, no redeploy.

  The bridge holds the quiz_id → room-pins index and does the DB read, so the
  Room stays pure/in-memory. Stale pins are harmless: `apply_question/2` no-ops
  on a dead room.

  ## Binding lifetime: monitor-based cleanup (hq-bridge-binding-gc)

  THE POLICY, and why it is this one rather than the three alternatives.

  A `Barkpark.Quiz.Room` is mortal by design — it self-stops after a short
  empty window (2 min) or a long idle one (60 min). The index entry it was
  bound under is not: before this, every `quiz_id → %{pin => dataset}` pair
  ever written stayed in this GenServer's heap for the life of the BEAM. Stale
  pins were *behaviourally* harmless (`apply_question/2` no-ops on a dead pin)
  and that is exactly why nothing ever noticed the growth.

  **Chosen: monitor-based cleanup, with a periodic liveness sweep as the floor.**

    1. `bind/3` resolves the pin to its live room pid (`Room.whereis/1`) and
       monitors it. The `:DOWN` removes that pin from EVERY quiz_id it appears
       under — immediate, precise, and it sees all three ways a room dies
       (idle timer, supervisor shutdown, crash).
    2. Every `@sweep_ms` the Bridge drops every indexed pin whose `whereis/1`
       is `nil`. This is the FLOOR that makes "bounded" true rather than
       mostly-true: a pin can be bound while no room is live (nothing forbids
       it, and `Barkpark.Quiz.BridgeSandboxCascadeTest` does exactly that), and
       such a pin has no process to monitor. The sweep does not care why an
       entry has no room — only that it has none.

  The index's size is therefore bounded by the number of LIVE rooms plus at
  most one sweep interval of churn, instead of by the BEAM's uptime.

  Rejected:

    * *Explicit unbind* — needs every room death to run a callback, and a
      crashed room runs none.
    * *Bounded prune alone (LRU / prune-on-`document_changed`-miss)* — evicts
      by age or by publish traffic, not by liveness: it can drop a binding
      whose room is still hosting, and it never touches a quiz nobody
      republishes. The sweep above keys on liveness, which is the actual
      lifetime.
    * *Accepted leak with a measured bound* — the bound is "every pin ever
      bound, forever", which is not a bound.

  **How it preserves rebind correctness across a reap.** The monitor deletes an
  index entry; it never deletes room content, and it cannot make a rebind
  worse, because the pre-GC entry was already inert. A re-ensured room starts
  on `Room.default_question/0` either way — the last-applied question lives in
  the (now dead) room process, never in this index. What restores it is the
  rebind: `QuizHostLive.mount/3` re-calls `bind_quiz/3` for its `?quiz=` id, and
  `bind/3` does `apply_now/3` FIRST, so the recreated room carries the quiz's
  current question immediately — before any further publish — and is re-indexed
  (and re-monitored) so later publishes still reach it. `test/barkpark/quiz/
  bridge_test.exs` proves that reap → recreate → rebind round trip.

  Cross-dataset safety: both paths remove one PIN at a time, per quiz_id. A
  second pin bound to the same quiz in another dataset keeps its entry — one
  room's death never unbinds another dataset's live room.

  ## Rebind replaces, it does not accumulate (hq-bridge-rebind-retires-old-quiz)

  Liveness GC is about entries whose ROOM is dead. A rebind is the other case:
  the room is alive and correctly bound, and it is the STALE QUIZ ID beside the
  live one that is wrong. `bind(pin, quiz_a)` then `bind(pin, quiz_b)` must
  leave `pin` indexed under quiz_b ONLY — a pin displays exactly one quiz at a
  time. Left additive, a later publish of quiz_a re-applies quiz_a's question to
  a room showing quiz_b, on SOMEBODY ELSE'S edit: to the host the room appears
  to revert on its own, and nothing in the room's state explains it, because the
  room is not wrong — the index is. The monitor cannot see this; there is
  nothing dead to observe.

  `retire_previous_quiz/4` is scoped by PIN (the index is many-pins-per-quiz, so
  dropping the old quiz_id wholesale would unbind unrelated live rooms) and by
  DATASET (the same pin string in another dataset is a different binding, and a
  rebind on production says nothing about staging).
  """
  use GenServer

  alias Barkpark.Content.Broadcast
  alias Barkpark.Quiz

  @pubsub Barkpark.PubSub
  @default_dataset "production"

  # The liveness-sweep interval (see the moduledoc policy). Sized against the
  # Room's own windows — it self-stops after 2 min empty / 60 min idle — so a
  # retired room's index entry outlives it by well under one reap cycle.
  @sweep_ms :timer.minutes(5)

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

  @doc """
  The current binding index, `%{quiz_id => %{pin => dataset}}`.

  Read-only introspection over state that is otherwise invisible — the GC
  policy above is a claim about THIS map's size over time, and a claim nothing
  can read is a claim nothing can test.
  """
  @spec bindings() :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}
  def bindings, do: GenServer.call(__MODULE__, :bindings)

  @doc """
  Run the liveness sweep NOW and return the resulting index.

  The periodic sweep is the policy's floor; a floor nothing can trigger on
  demand is a floor nothing can test inside a test's lifetime.
  """
  @spec sweep() :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(opts) do
    dataset = Keyword.get(opts, :dataset, @default_dataset)
    # As a PLUGIN worker (register_workers/1) the Bridge starts BEFORE the host's
    # Phoenix.PubSub child (application.ex splices plugin_children ahead of
    # PubSub), so subscribing synchronously here would crash the boot. Defer the
    # default-dataset subscribe to a self-message that retries until PubSub is
    # alive. `topics` starts EMPTY and tracks the TOPIC STRINGS we've actually
    # joined — bind/3 re-derives the wanted set for its dataset on every call
    # and joins whatever is still missing (the Default workspace's keyed topic
    # may not have been resolvable at boot; see `safe_subscribe/1`).
    send(self(), {:subscribe, dataset})
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{topics: MapSet.new(), bindings: %{}, rooms: %{}}}
  end

  @impl true
  def handle_call({:bind, pin, quiz_id, dataset}, _from, state) do
    # Each binding records its OWN dataset; subscribe to every bound dataset's
    # topic so a room on a non-default dataset still gets live edits.
    state = ensure_subscribed(dataset, state)
    apply_now(pin, quiz_id, dataset)

    # A REBIND REPLACES, it does not accumulate. A pin shows exactly one quiz at
    # a time, so its PREVIOUS quiz id must be retired here — otherwise a later
    # publish of that old quiz re-applies the old question to a room that has
    # moved on, and to the host the room looks like it spontaneously reverted.
    state = retire_previous_quiz(state, pin, quiz_id, dataset)

    # Index pins BY pin → its own dataset (not one dataset per quiz_id): the same
    # quiz_id bound in two datasets must reload each pin from the dataset it bound,
    # never cross-inject one dataset's content into the other's room.
    pins = state.bindings |> Map.get(quiz_id, %{}) |> Map.put(pin, dataset)

    # The index entry's LIFETIME is the room's (see the moduledoc policy). Bind
    # to the LIVE room's monitor when there is one; when there is not, the entry
    # is still indexed — callers may bind ahead of a room — and the periodic
    # sweep is what retires it.
    state =
      case Quiz.Room.whereis(pin) do
        nil -> state
        room -> monitor_room(pin, room, state)
      end

    {:reply, :ok, put_in(state.bindings[quiz_id], pins)}
  end

  def handle_call(:bindings, _from, state), do: {:reply, state.bindings, state}

  # Synchronous sweep — the same work the timer does, for callers that must
  # observe the result rather than wait out `@sweep_ms`.
  def handle_call(:sweep, _from, state) do
    state = sweep(state)
    {:reply, state.bindings, state}
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

  # A bound room died (idle reap, shutdown, or crash) — retire its pin from the
  # index. Matched by REF, not by pid: a pin can be re-ensured and re-bound
  # before this message is drained, and dropping the NEW binding on the OLD
  # room's :DOWN would silently unbind a live room.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.rooms, fn {_pin, {_pid, r}} -> r == ref end) do
      nil -> {:noreply, state}
      {pin, _} -> {:noreply, drop_pin(pin, state)}
    end
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, sweep(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Retire every indexed pin with no live room. Keys on LIVENESS, not on age or
  # on publish traffic, so it cannot evict a room that is still hosting — and it
  # catches the entries a monitor never could (a pin bound while no room was up).
  defp sweep(state) do
    state.bindings
    |> Enum.flat_map(fn {_quiz_id, pins} -> Map.keys(pins) end)
    |> Enum.uniq()
    |> Enum.reject(&Quiz.Room.whereis/1)
    |> Enum.reduce(state, &drop_pin/2)
  end

  # Monitor `pin`'s room exactly once. Re-binding the SAME live room reuses the
  # existing monitor; a DIFFERENT pid under the same pin (reap then re-ensure)
  # replaces it, flushing the old ref so its stale :DOWN cannot arrive later and
  # delete the binding we just made.
  defp monitor_room(pin, room, state) do
    case Map.get(state.rooms, pin) do
      {^room, _ref} ->
        state

      {_dead, old_ref} ->
        Process.demonitor(old_ref, [:flush])
        %{state | rooms: Map.put(state.rooms, pin, {room, Process.monitor(room)})}

      nil ->
        %{state | rooms: Map.put(state.rooms, pin, {room, Process.monitor(room)})}
    end
  end

  # Retire `pin` from its OTHER quiz ids — scoped two ways, because both scopes
  # are load-bearing:
  #
  #   * by PIN, not by quiz_id: the index is many-pins-per-quiz, so dropping the
  #     old quiz_id wholesale would silently unbind every unrelated live room
  #     bound to it (the failure shape PR #18850's mutation (D) demonstrates).
  #   * by DATASET: the same pin string bound in another dataset is a DIFFERENT
  #     binding, and a rebind on production says nothing about staging.
  #
  # `drop_pin/2` is the liveness path's remover and is deliberately NOT reused —
  # it is dataset-blind, which is correct when the ROOM is dead (a dead room kills
  # every dataset's binding) and wrong here (the room is alive).
  defp retire_previous_quiz(state, pin, quiz_id, dataset) do
    bindings =
      Enum.reduce(state.bindings, %{}, fn
        {^quiz_id, pins}, acc ->
          Map.put(acc, quiz_id, pins)

        {other_quiz_id, pins}, acc ->
          if Map.get(pins, pin) == dataset do
            case Map.delete(pins, pin) do
              rest when map_size(rest) == 0 -> acc
              rest -> Map.put(acc, other_quiz_id, rest)
            end
          else
            Map.put(acc, other_quiz_id, pins)
          end
      end)

    %{state | bindings: bindings}
  end

  # Remove ONE pin from every quiz_id it is indexed under, dropping quiz_ids that
  # are left with no pins. Sibling pins — including the same quiz_id bound to a
  # live room in another dataset — are untouched.
  defp drop_pin(pin, state) do
    bindings =
      Enum.reduce(state.bindings, %{}, fn {quiz_id, pins}, acc ->
        case Map.delete(pins, pin) do
          rest when map_size(rest) == 0 -> acc
          rest -> Map.put(acc, quiz_id, rest)
        end
      end)

    %{state | bindings: bindings, rooms: Map.delete(state.rooms, pin)}
  end

  # Join every document-list topic this dataset needs, each exactly once. If
  # PubSub isn't up yet (boot race — plugin workers precede the host PubSub
  # child), reschedule and retry; at runtime PubSub is always alive so this
  # subscribes on the first try. Re-entered on every bind/3, so a keyed topic
  # that was not resolvable at boot is picked up the first time a room binds.
  defp ensure_subscribed(dataset, state) do
    missing = Enum.reject(wanted_topics(dataset), &MapSet.member?(state.topics, &1))

    case Enum.split_with(missing, &(safe_subscribe(&1) == :ok)) do
      {joined, []} ->
        %{state | topics: MapSet.union(state.topics, MapSet.new(joined))}

      {joined, _retry} ->
        Process.send_after(self(), {:subscribe, dataset}, 50)
        %{state | topics: MapSet.union(state.topics, MapSet.new(joined))}
    end
  end

  # THE TOPICS, AND WHY THIS WORKSPACE (task-b7e81f26e959106c, retiring the
  # task-5d0615ee60143cc8 residual). The global `documents:<dataset>` topic now
  # announces the SHARED LAYER (nil-workspace documents) ONLY — nothing about a
  # workspace-owned document, not even its id, reaches it — so a daemon that
  # sat on the global topic alone would never hear a quiz publish again.
  #
  # The Bridge is instance-wide, but its BINDABLE set is not: `apply_now/3`
  # re-reads through `Quiz.load_question/2` -> `Content.get_public_document/3`,
  # which is pinned to the seeded Default (public) workspace, plus the
  # `workspace_or_global` nil-workspace rows. A quiz in any OTHER workspace is
  # not loadable here by design (the anonymous host door), so a frame for it
  # would be a re-read that returns `:not_found` — there is nothing to hear.
  # `Broadcast.subscribe_documents/2` with the Default workspace's id is
  # therefore exactly the set of frames this process can act on, and no
  # other tenant's frames at all.
  #
  # When no Default is seeded (fresh sandbox, or the support provisioner's
  # reset window) only the global topic is joined; the next bind/3 re-derives
  # and joins the keyed topic once the seat is filled.
  defp wanted_topics(dataset) do
    case default_workspace_id() do
      nil ->
        [Broadcast.global_list_topic(dataset)]

      ws_id ->
        [Broadcast.global_list_topic(dataset), Broadcast.workspace_list_topic(dataset, ws_id)]
    end
  end

  # The Repo may not be answering at boot (this worker starts early) — treat any
  # failure as "no Default yet"; nil is never cached, so a later bind re-asks.
  defp default_workspace_id do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
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
