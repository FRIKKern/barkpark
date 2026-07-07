defmodule Barkpark.Plugins.Github.Health do
  @moduledoc """
  Pure LOCAL-READ sync-health aggregate for the `github` mirror plugin
  (epic wave 6 — observability).

  `snapshot/1` composes four cheap local reads into ONE plain map that both the
  `/admin/github` `:ops` console LiveView (slice 2) and the JSON status
  controller (slice 3) render, plus what `bp github status` (slice 4) prints:

    1. **conflicts** — the open `github_sync_conflicts` quarantine (epic D7),
       bucketed by the fixed 3-value `kind` set, with the newest rows as plain
       maps for the console table.
    2. **datasets** — per mirror dataset: the outbound cursor, the local
       `mutation_events` head, their lag, and how many un-mirrored task events
       are still pending (the EXACT drain window the wave-2 `Outbox` reader
       uses).
    3. **queue** — the `github_mirror` Oban queue depth by state.
    4. **active / repo** — the settings gate + repo string for the console
       header.

  ## Rules it honors

    * **ZERO GitHub calls.** No `Auth`, no `Client`, no GraphQL, no network —
      this reads only local Postgres, so it works with the plugin DARK and is
      safe to call from a LiveView `mount/3` AND a controller action. It NEVER
      reads a GitHub field back into anything (D5: read-only, no GitHub
      read-back).
    * **Total, never raising.** Each sub-read is wrapped defensively: a missing
      table, an unmigrated conflict store, or a dark/half-provisioned plugin
      yields ZEROS for that section rather than crashing the caller. The map is
      always fully shaped.
    * **No worker, no mutation.** Pure reads through `Repo` — it never enqueues
      an Oban job, never writes a `mutation_events` row, never touches
      `Content.*`. It can never re-trigger sync.
    * **Honest, not fabricated.** Unknown counts surface as `0`, not a guess.
      It surfaces the visible quarantine (D7) rather than hiding drift.
  """

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Conflict, Conflicts, Cursor, Outbox, Settings}
  alias Barkpark.Repo

  # The fixed conflict-kind set (mirrors `Conflict.kinds/0`). Buckets are always
  # keyed on these three so the console renders a stable header even at zero.
  @conflict_kinds ~w(out_of_band_edit detached dedup_refused)

  # How deep to scan open conflicts for the bucket counts (epic D7: a maintainer
  # reconciles by hand; 200 is plenty of headroom over a healthy handful).
  @conflict_scan_limit 200

  # How many open conflict rows to hand the console as plain maps (newest-first).
  @open_conflicts_cap 50

  # The Oban queue the wave-2 mirror engine drains on.
  @queue "github_mirror"

  # The Oban states that count as live queue depth (pending or in-flight work).
  # `completed`/`cancelled`/`discarded` are terminal and NOT depth.
  @queue_states ~w(available scheduled executing retryable)

  # The outbox drain probe cap — matches the wave-2 drain batch size so `pending`
  # measures the SAME window the drain worker sees, and `pending_capped` flags
  # "there may be more than this".
  @outbox_probe_limit 500

  @typedoc "Fully-shaped sync-health snapshot; every field is always present."
  @type t :: %{
          active: boolean(),
          repo: String.t() | nil,
          conflicts: %{
            out_of_band_edit: non_neg_integer(),
            detached: non_neg_integer(),
            dedup_refused: non_neg_integer(),
            total: non_neg_integer(),
            open: [map()]
          },
          datasets: [
            %{
              dataset: String.t(),
              cursor: non_neg_integer(),
              head: non_neg_integer(),
              lag: non_neg_integer(),
              pending: non_neg_integer(),
              pending_capped: boolean()
            }
          ],
          queue: %{
            available: non_neg_integer(),
            scheduled: non_neg_integer(),
            executing: non_neg_integer(),
            retryable: non_neg_integer()
          }
        }

  @doc """
  Aggregate the GitHub sync-health snapshot from LOCAL reads only.

  Total by construction: any sub-read that fails (dark plugin, missing table,
  transient DB error) degrades to zeros for its section, never a raise. `opts`
  is accepted for forward-compatibility and currently unused — the snapshot
  always reflects the plugin's OWN resolved settings (repo, datasets).
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(_opts \\ []) do
    %{
      active: safe(fn -> Settings.active?() end, false),
      repo: safe(fn -> Settings.repo() end, nil),
      conflicts: conflicts_snapshot(),
      datasets: datasets_snapshot(),
      queue: queue_snapshot()
    }
  end

  # ---------------------------------------------------------------------------
  # (1) Conflicts — the visible quarantine (D7)
  # ---------------------------------------------------------------------------

  defp conflicts_snapshot do
    safe(
      fn ->
        rows = Conflicts.list(conflicts_list_opts())
        counts = bucket_kinds(rows)

        %{
          out_of_band_edit: Map.fetch!(counts, "out_of_band_edit"),
          detached: Map.fetch!(counts, "detached"),
          dedup_refused: Map.fetch!(counts, "dedup_refused"),
          total: length(rows),
          open: rows |> Enum.take(@open_conflicts_cap) |> Enum.map(&conflict_to_map/1)
        }
      end,
      zero_conflicts()
    )
  end

  # Filter to the configured repo when one is set; pass NO :repo filter when the
  # plugin is dark (Settings.repo/0 nil) so a pre-provisioning snapshot still
  # surfaces any orphaned rows rather than filtering to nothing.
  defp conflicts_list_opts do
    base = [limit: @conflict_scan_limit]

    case safe(fn -> Settings.repo() end, nil) do
      repo when is_binary(repo) -> [{:repo, repo} | base]
      _ -> base
    end
  end

  # Count rows into the fixed 3-kind bucket; unknown kinds (should never occur —
  # the schema constrains them) are ignored so the shape stays stable.
  defp bucket_kinds(rows) do
    zero = Map.new(@conflict_kinds, &{&1, 0})

    Enum.reduce(rows, zero, fn %Conflict{kind: kind}, acc ->
      case acc do
        %{^kind => n} -> %{acc | kind => n + 1}
        _ -> acc
      end
    end)
  end

  defp conflict_to_map(%Conflict{} = c) do
    %{
      id: c.id,
      repo: c.repo,
      issue: c.issue,
      doc_id: c.doc_id,
      dataset: c.dataset,
      kind: c.kind,
      detail: c.detail,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp zero_conflicts do
    %{out_of_band_edit: 0, detached: 0, dedup_refused: 0, total: 0, open: []}
  end

  # ---------------------------------------------------------------------------
  # (2) Cursor + lag per dataset
  # ---------------------------------------------------------------------------

  defp datasets_snapshot do
    datasets = safe(fn -> Settings.datasets() end, ["production"])
    Enum.map(datasets, &dataset_snapshot/1)
  end

  defp dataset_snapshot(dataset) when is_binary(dataset) do
    safe(
      fn ->
        cursor = Cursor.get(dataset)
        head = head_id(dataset)
        pending = length(Outbox.fetch(dataset, cursor, @outbox_probe_limit))

        %{
          dataset: dataset,
          cursor: cursor,
          head: head,
          lag: max(head - cursor, 0),
          pending: pending,
          pending_capped: pending >= @outbox_probe_limit
        }
      end,
      zero_dataset(dataset)
    )
  end

  defp dataset_snapshot(dataset), do: zero_dataset(dataset)

  # Largest local mutation_events.id for the dataset (the head the cursor chases);
  # nil (no events yet) → 0.
  defp head_id(dataset) do
    Repo.one(from(e in MutationEvent, where: e.dataset == ^dataset, select: max(e.id))) || 0
  end

  defp zero_dataset(dataset) do
    ds = if is_binary(dataset), do: dataset, else: to_string(dataset)
    %{dataset: ds, cursor: 0, head: 0, lag: 0, pending: 0, pending_capped: false}
  end

  # ---------------------------------------------------------------------------
  # (3) Queue depth
  # ---------------------------------------------------------------------------

  defp queue_snapshot do
    safe(
      fn ->
        counts =
          from(j in Oban.Job,
            where: j.queue == @queue and j.state in @queue_states,
            group_by: j.state,
            select: {j.state, count(j.id)}
          )
          |> Repo.all()
          |> Map.new()

        Map.new(@queue_states, fn state ->
          {String.to_atom(state), Map.get(counts, state, 0)}
        end)
      end,
      zero_queue()
    )
  end

  defp zero_queue do
    Map.new(@queue_states, fn state -> {String.to_atom(state), 0} end)
  end

  # ---------------------------------------------------------------------------
  # Defensive wrapper
  # ---------------------------------------------------------------------------

  # Run `fun`; on ANY raise/exit (missing table, dark plugin, transient DB
  # error) fall back to `default`. Keeps the snapshot total so a LiveView mount
  # or a controller action never 500s on a health probe.
  defp safe(fun, default) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
