defmodule Barkpark.Tenancy.WorkspaceBundle.SingleFlight do
  @moduledoc """
  Admission control for `GET /api/workspaces/:workspace_slug/export`.

  ## Why a guard exists at all (PDS-D719 — the measured argument)

  Until this module there was NO lock, semaphore, mutex or rate limit anywhere
  near the export route. `pipe_through([:api, :require_admin])` is an AUTH
  gate, not a concurrency gate, so N concurrent admin requests each paid the
  peak independently.

  The decisive quantity is NOT memory. Streaming (PDS-D204) already collapsed
  the per-request heap cost — the bundle is spilled per table and packed to a
  temp tar, never held as one BEAM binary. What streaming did not do is bound
  DISK, and disk is where the route now keeps its whole cost: for the length of
  the pack a live export holds (remaining spills + tar-so-far), which sums to
  roughly the whole member set, against guerrilla's **13.27 GiB free
  (14,251,499,520 B)** on a box that carries `/`, `/tmp` AND `/opt/barkpark` on
  ONE filesystem. A realistic full-bundle peak is **~1.458 GiB**.

  **The load-bearing fact is not "1.458 × N eventually exceeds 13.27". It is
  that the shipped free-space preflight is a TOCTOU check that goes silently
  vacuous at N = 2.** `WorkspaceBundle.require_export_free_space!/2` is
  documented in-code as "THE LAST HONEST MOMENT" — the only place an honest
  refusal can exist, because once `send_file/3` has put 200 + Content-Length on
  the wire no 503 envelope is producible and a mid-send ENOSPC can only
  truncate the download. That check reads `df` ONCE, BEFORE the first spill
  byte, and asserts `required ≤ free`. Two exports that start before either has
  written a byte read the SAME `free` and each independently concludes it fits.
  What the preflight can then guarantee is `required_i ≤ free` for every i —
  never `Σ required_i ≤ free`. Its entire margin is divided by the number of
  callers, and nothing in the process notices.

  So the guard is not "concurrency feels risky". It is the precondition that
  makes an ALREADY-SHIPPED refusal mean what its own comment says it means.

  ## Why the key is the FILESYSTEM, not the workspace

  It follows from the paragraph above. The quantity the preflight measures is
  free bytes on `:bundle_spill_dir` — a per-NODE, per-FILESYSTEM quantity. Two
  exports of DIFFERENT workspaces consume it exactly as fast as two of the
  same. A guard keyed only on the workspace slug would leave the hazard it was
  built for completely unbounded, and its charter entry would be false.

  The admission limit is therefore a GLOBAL slot count for this node
  (`:export_concurrency_limit`, default **1**), and the workspace slug survives
  only as a better-diagnosed refusal:

    * `:workspace_export_in_flight` — the caller's OWN workspace is already
      exporting. The slug is named back to the caller, who just proved
      `workspace_admin?/2` on it.
    * `:export_capacity_reached` — every slot is held, by at least one export
      of some OTHER workspace. **The in-flight slug is deliberately NOT named.**
      The caller proved admin on THEIR workspace and on nothing else; naming
      another tenant's slug here would be a cross-tenant existence leak on a
      route whose entire docstring is about not being one.

  Both refusals are 409 at the edge. Not 429: nothing about the caller's RATE
  is wrong and no budget will replenish on a timer — the request conflicts with
  a specific piece of work that is running right now, which is what 409 means.
  Not a QUEUE: a queued export holds a socket open for the ~130 s server-side
  phase (wave 7) plus the leader's drain, and a client that cannot tell "queued"
  from "hung" retries, which is the fan-out the guard exists to prevent.

  ## Release, including the paths `after` cannot reach

  A slot is released two ways, and it needs both:

    * the controller's `after` clause, for every normal and raising exit —
      including the `Bandit.TransportError` a socket killed mid-`send_file`
      raises, which IS catchable;
    * a `Process.monitor/1` on the holder, held by this GenServer. A holder
      that dies without running `after` — `Process.exit(pid, :kill)`, a
      supervisor shutdown — frees its slot on the `:DOWN`. This is the same
      lesson `Janitor` learned the expensive way (PDS-D210): the cover that
      matters is the one that still works when the owner's own cleanup did not
      run. A wedged slug would make the route permanently 409 with no operator
      signal at all, which is strictly worse than the unbounded fan-out it
      replaced, so it is proven by test rather than argued.

  Releases are idempotent and only ever act on rows owned by the calling pid,
  so a late `after` on a process whose monitor already fired cannot free a
  slot a LATER export has since taken.

  ## What this does NOT claim to fix — the janitor (criterion c1)

  `WorkspaceBundle.Janitor`'s moduledoc cites the absence of this guard when it
  justifies its pid-liveness sidecar: "Nothing in code enforces single-flight on
  the export route … So an mtime cutoff alone is not sufficient: the GREEN slot
  booting could delete files a live BLUE export still owns."

  **This guard does not retire that sidecar, and the sentence stays true where
  it matters.** The race the janitor names is between two OS processes — a
  booting GREEN BEAM and a live BLUE one, sharing one real `/tmp`
  (`PrivateTmp=no`). This module is an ETS table inside ONE BEAM; it cannot be
  consulted by, and says nothing about, a different OS process. What it removes
  is the SAME-NODE component: with a global limit of 1 a node can no longer
  have two of its own exports writing spills concurrently, so the sweep's
  worst case per node shrinks to one live export. The sidecar remains
  LOAD-BEARING for the cross-slot case and must not be deleted on the strength
  of this guard. Named, rather than quietly assumed away.

  ## Disabling

  `config :barkpark, :export_concurrency_limit, 0` (or any non-positive
  integer) turns admission control off entirely: `acquire/1` always returns
  `:ok`, records nothing, and `release/1` is a no-op. There is deliberately no
  entry in `config/config.exs` — the default lives in `limit/0`, so the guard
  is on for every environment that does not opt out in writing.
  """

  use GenServer

  require Logger

  @table __MODULE__

  # Wave 7 measured a full guerrilla export at ~130 s server-side alone (the
  # COPY + tar phase, before a byte reaches the client). Rounded DOWN to the
  # nearest minute so a polling client's first retry lands near the end of a
  # typical export rather than after it, and so a short export is not made to
  # look longer than it was. Advisory by definition (RFC 9110 §10.2.3) — the
  # authoritative answer is the next request.
  @retry_after_seconds 120

  @default_limit 1

  @type refusal ::
          {:error,
           {:export_in_flight,
            %{
              reason: :workspace_export_in_flight | :export_capacity_reached,
              workspace_slug: String.t() | nil,
              running_for_seconds: non_neg_integer(),
              retry_after_seconds: pos_integer(),
              limit: pos_integer()
            }}}

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take an export slot for `workspace_slug` on behalf of the calling process.

  `:ok` on admission (the caller MUST pair it with `release/1` in an `after`);
  a `{:error, {:export_in_flight, info}}` refusal otherwise — see the moduledoc
  for the two reasons and why one of them withholds the slug.
  """
  @spec acquire(String.t()) :: :ok | refusal()
  def acquire(workspace_slug) when is_binary(workspace_slug) do
    case limit() do
      n when is_integer(n) and n > 0 ->
        GenServer.call(__MODULE__, {:acquire, workspace_slug, self(), n})

      _ ->
        :ok
    end
  catch
    # The guard is admission control, not a correctness precondition. If the
    # process is not running (a test that never started the tree, a supervisor
    # restart in flight) the export proceeds UNGUARDED rather than failing —
    # the same posture the sibling pool remedy takes in
    # `Repo.start_export_pool/1`. Logged, because a guard that is silently not
    # running is exactly the "assertion nobody re-derived" this epic keeps
    # finding.
    :exit, reason ->
      Logger.warning(
        "workspace export single-flight guard unavailable (#{inspect(reason)}); " <>
          "admitting #{workspace_slug} unguarded"
      )

      :ok
  end

  @doc """
  Release the slot the calling process holds for `workspace_slug`.

  Idempotent, and scoped to the caller: a release from a process that does not
  own the row does nothing, so a late `after` cannot free a slot some later
  export has taken.
  """
  @spec release(String.t()) :: :ok
  def release(workspace_slug) when is_binary(workspace_slug) do
    GenServer.call(__MODULE__, {:release, workspace_slug, self()})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The exports in flight on this node, newest field first: `{slug, pid, started_at_ms}`.

  Reads ETS directly — a diagnostic must never queue behind the writer.
  """
  @spec in_flight() :: [{String.t(), pid(), integer()}]
  def in_flight do
    :ets.tab2list(@table)
    |> Enum.map(fn {slug, pid, _monitor_ref, started_at_ms} -> {slug, pid, started_at_ms} end)
  rescue
    ArgumentError -> []
  end

  @doc """
  How many exports may be in flight on this node at once. `0` or less disables
  admission control entirely.
  """
  @spec limit() :: integer()
  def limit, do: Application.get_env(:barkpark, :export_concurrency_limit, @default_limit)

  @doc "Advisory `Retry-After`, in seconds. See the derivation above the attribute."
  @spec retry_after_seconds() :: pos_integer()
  def retry_after_seconds, do: @retry_after_seconds

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # `:protected` — every write goes through this process, so a row can never
    # outlive its monitor. Reads are direct (`in_flight/0`).
    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:acquire, slug, pid, limit}, _from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      # SAME WORKSPACE FIRST, so the more specific (and safely nameable)
      # refusal wins whenever both apply.
      match?([_ | _], :ets.lookup(@table, slug)) ->
        [{^slug, _pid, _ref, started_at_ms}] = :ets.lookup(@table, slug)

        {:reply, refusal(:workspace_export_in_flight, slug, now - started_at_ms, limit), state}

      :ets.info(@table, :size) >= limit ->
        # The OTHER tenant's slug is NOT carried into the refusal. Only the
        # elapsed time is, which the caller could have measured anyway.
        oldest_ms =
          :ets.tab2list(@table)
          |> Enum.map(fn {_s, _p, _r, started_at_ms} -> now - started_at_ms end)
          |> Enum.max(fn -> 0 end)

        {:reply, refusal(:export_capacity_reached, nil, oldest_ms, limit), state}

      true ->
        ref = Process.monitor(pid)
        true = :ets.insert(@table, {slug, pid, ref, now})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:release, slug, pid}, _from, state) do
    case :ets.lookup(@table, slug) do
      [{^slug, ^pid, ref, _started_at_ms}] ->
        Process.demonitor(ref, [:flush])
        :ets.delete(@table, slug)

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # The cover for the paths `after` cannot reach. Matched on the MONITOR REF
    # as well as the pid so a stale DOWN can never evict a row a different
    # process has since inserted under the same slug.
    case :ets.match_object(@table, {:_, pid, ref, :_}) do
      [{slug, ^pid, ^ref, _started_at_ms}] ->
        Logger.warning(
          "workspace export holder for #{slug} went down (#{inspect(reason)}) without " <>
            "releasing its slot; the guard reclaimed it"
        )

        :ets.delete(@table, slug)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp refusal(reason, slug, elapsed_ms, limit) do
    {:error,
     {:export_in_flight,
      %{
        reason: reason,
        workspace_slug: slug,
        running_for_seconds: div(max(elapsed_ms, 0), 1000),
        retry_after_seconds: @retry_after_seconds,
        limit: limit
      }}}
  end
end
