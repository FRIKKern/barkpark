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
    5. **unacknowledged** — the REPORTER LOOP census
       (`Github.Acknowledgement.census/2`): `gh-<num>` rows born from an
       outsider's issue whose acknowledgement criterion is not stamped met. It
       is here rather than in its own surface because it is the same question
       every other section answers — what is this bridge quietly not doing —
       and because `bp github status` and the `:ops` console already read this
       map, so the overdue rows reach an operator with no new plumbing.

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
  alias Barkpark.Plugins.Github.{Acknowledgement, Conflict, Cursor, Outbox, Settings}
  alias Barkpark.Repo

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
          db_ok: boolean(),
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
            retryable: non_neg_integer(),
            total: non_neg_integer()
          },
          unacknowledged: Acknowledgement.census()
        }

  @doc """
  Aggregate the GitHub sync-health snapshot from LOCAL reads only.

  Total by construction: any sub-read that fails (dark plugin, missing table,
  transient DB error) degrades to zeros for its section, never a raise.

  The argument is a **scope filter**. Two shapes:

    * a binary / `nil` — the legacy DATASET-ONLY filter, described below. Every
      existing caller (the admin `:ops` console, `bp github status`) keeps this
      shape and its exact behaviour.
    * a keyword or map carrying `:dataset` and/or `:workspace_ids` — the
      MEMBERSHIP-FENCED read (`github-bridge-w9-health-workspace-isolation`).
      `:workspace_ids` is the caller's own membership set, as produced by
      `Tenancy.list_workspaces_for/1`. When present (INCLUDING an empty list) the
      open-conflict read admits only rows whose `workspace_id` is in that set or
      is NULL; absent means no membership fence at all.

  ## Why a dataset string was never isolation, and why NULL is still admitted

  A dataset slug is unique per PROJECT, not globally — every workspace gets a
  `"production"` — so pinning to the bearer's own `api_token.dataset` (D18)
  narrows a whole-fleet read to a SHARED LABEL. Two workspaces both named
  `production` still read each other's quarantine. The `workspace_id` column
  (migration 20260911120000) is the tenant key that string never was.

  A NULL `workspace_id` is UNATTRIBUTED, not "everyone's": a `dedup_refused` row
  has no `doc_id` to trace, and a `{doc_id, dataset}` under a shared slug names
  no single tenant. Those rows were already visible at the dataset-string grain
  and stay visible there — admitting them keeps the fence from silently blanking
  an operator's existing backlog, while every row that CAN name its tenant is
  fenced to it. New writes always stamp, so the NULL population does not grow.

  The legacy dataset filter (`nil` | `""` | `"<name>"`):

    * a non-blank binary NARROWS the per-dataset rows AND the open-conflict
      read to that ONE dataset — this is what lets the JSON status controller
      pin a snapshot to the caller's own token dataset so an operator token
      cannot read whole-fleet conflict/lag detail (D18);
    * `nil` / blank / any non-binary (e.g. the legacy `keyword` shape the
      forward-compat callers passed) means WHOLE FLEET — every configured
      dataset, conflicts filtered by repo only. This is what the admin-gated
      `:ops` console mount uses.

  The header `active`/`repo` and the fleet-wide `queue` depth are unaffected by
  the filter — they are plugin-global, not per-dataset.
  """
  @spec snapshot(String.t() | nil | keyword() | map()) :: t()
  def snapshot(filter \\ nil) do
    # A non-blank binary narrows the snapshot to one dataset; anything else
    # (nil, blank, or a keyword/map without :dataset) is the whole-fleet view.
    dataset = normalize_dataset(filter)
    # The caller's membership set, or nil for "no membership fence" (every
    # legacy caller). An EMPTY list is a real, fail-closed answer — a principal
    # with no memberships — and is NOT the same as nil.
    workspace_ids = normalize_workspace_ids(filter)

    # Resolve the repo ONCE and thread it down. Each `Settings.repo/0` is a DB
    # fallback read that logs an audit row, so a single read (vs one per section)
    # both trims audit-table churn on a per-mount probe AND guarantees the header
    # `repo` and the conflict repo-filter observe the SAME value.
    repo = safe(fn -> Settings.repo() end, nil)

    %{
      active: safe(fn -> Settings.active?() end, false),
      # Liveness bit for the whole snapshot: a trivial round-trip to Postgres. On
      # a healthy DB it is `true`; if the DB is down/unreachable the `SELECT 1`
      # raises or exits and `safe/2` degrades it to `false` — the ONE field that
      # distinguishes a genuinely healthy zero-snapshot from the all-zeros a dead
      # DB would otherwise silently produce (every section falls back to zeros).
      # The console/`bp github status` reads it to tell "quiet" from "blind".
      db_ok:
        safe(
          fn ->
            Repo.query!("SELECT 1")
            true
          end,
          false
        ),
      repo: repo,
      conflicts: conflicts_snapshot(repo, dataset, workspace_ids),
      datasets: datasets_snapshot(dataset),
      queue: queue_snapshot(),
      unacknowledged: unacknowledged_snapshot(dataset)
    }
  end

  # A non-blank binary is the dataset filter; nil / blank / any non-binary shape
  # (the legacy `keyword` forward-compat arg) collapses to nil = whole fleet.
  defp normalize_dataset(d) when is_binary(d) do
    case String.trim(d) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A keyword/map filter carries the dataset under :dataset (string or atom key);
  # recursing through the binary clause keeps blank-string handling in ONE place.
  defp normalize_dataset(filter) when is_list(filter) do
    if Keyword.keyword?(filter),
      do: normalize_dataset(Keyword.get(filter, :dataset)),
      else: nil
  end

  defp normalize_dataset(filter) when is_map(filter) do
    normalize_dataset(Map.get(filter, :dataset, Map.get(filter, "dataset")))
  end

  defp normalize_dataset(_), do: nil

  # The membership fence. `nil` = UNFENCED (the filter carries no `:workspace_ids`
  # key at all — every legacy caller, including the admin `:ops` console). A list
  # — EMPTY INCLUDED — is a real membership answer and IS enforced; an empty one
  # means "this principal is a member of nothing", which must fence, not widen.
  # Two steps deliberately: `fence/1` LIFTS the key out of a keyword/map filter,
  # `fence_ids/1` normalizes the lifted VALUE. Folding them into one clause set
  # would make a plain list of ids (the value) collide with a keyword filter (the
  # container) and silently drop the fence.
  defp normalize_workspace_ids(filter) when is_list(filter) do
    if Keyword.keyword?(filter), do: fence_ids(Keyword.get(filter, :workspace_ids)), else: nil
  end

  defp normalize_workspace_ids(filter) when is_map(filter) do
    fence_ids(Map.get(filter, :workspace_ids, Map.get(filter, "workspace_ids")))
  end

  defp normalize_workspace_ids(_), do: nil

  # Non-binary members are dropped rather than passed to the query, so a
  # malformed caller can only ever NARROW the fence, never widen it.
  defp fence_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp fence_ids(_), do: nil

  # ---------------------------------------------------------------------------
  # (1) Conflicts — the visible quarantine (D7)
  # ---------------------------------------------------------------------------

  defp conflicts_snapshot(repo, dataset, workspace_ids) do
    safe(
      fn ->
        counts = open_conflict_counts(repo, dataset, workspace_ids)
        rows = open_conflict_rows(repo, dataset, workspace_ids)

        %{
          out_of_band_edit: Map.get(counts, "out_of_band_edit", 0),
          detached: Map.get(counts, "detached", 0),
          dedup_refused: Map.get(counts, "dedup_refused", 0),
          total: counts |> Map.values() |> Enum.sum(),
          open: Enum.map(rows, &conflict_to_map/1)
        }
      end,
      zero_conflicts()
    )
  end

  # EXACT open-conflict counts grouped by kind — a `COUNT ... GROUP BY kind`,
  # not a bounded row scan, so `total` and every bucket are honest even past a
  # large backlog (no silent cap) while staying O(kinds) in memory. Filtered to
  # the configured repo when one is set; NO :repo filter when the plugin is dark
  # (repo nil) so a pre-provisioning snapshot still surfaces orphaned rows. The
  # `dataset` filter is applied on top (D18) when the caller pins one, so a
  # per-dataset-scoped read never counts another dataset's quarantine.
  defp open_conflict_counts(repo, dataset, workspace_ids) do
    Conflict
    |> where([c], is_nil(c.resolved_at))
    |> maybe_repo(repo)
    |> maybe_dataset(dataset)
    |> maybe_workspaces(workspace_ids)
    |> group_by([c], c.kind)
    |> select([c], {c.kind, count(c.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp maybe_repo(query, repo) when is_binary(repo), do: where(query, [c], c.repo == ^repo)
  defp maybe_repo(query, _repo), do: query

  defp maybe_dataset(query, dataset) when is_binary(dataset),
    do: where(query, [c], c.dataset == ^dataset)

  defp maybe_dataset(query, _dataset), do: query

  # THE TENANT FENCE. A list (empty included) restricts the read to rows this
  # caller's memberships own, PLUS the unattributed (NULL) population the
  # migration could not resolve — see the moduledoc for why NULL is admitted and
  # why it cannot grow. `nil` = no fence (every legacy caller). Applied IN THE
  # DATABASE, alongside repo/dataset, so the counts and the capped row list
  # observe the identical window.
  defp maybe_workspaces(query, ids) when is_list(ids),
    do: where(query, [c], is_nil(c.workspace_id) or c.workspace_id in ^ids)

  defp maybe_workspaces(query, _ids), do: query

  # Newest-first open rows for the console table / status JSON, capped at
  # `@open_conflicts_cap`. Applies the SAME repo + dataset filters as the counts
  # (dark → repo-wide; unpinned → all datasets) IN THE DATABASE so the cap and
  # the counts observe the identical window — filtering post-cap would drop a
  # pinned dataset's rows behind another dataset's newer ones. Built locally (not
  # via `Conflicts.list/1`, which has no `:dataset` option) to keep the D18
  # dataset narrowing inside this one slice.
  defp open_conflict_rows(repo, dataset, workspace_ids) do
    Conflict
    |> where([c], is_nil(c.resolved_at))
    |> maybe_repo(repo)
    |> maybe_dataset(dataset)
    |> maybe_workspaces(workspace_ids)
    |> order_by([c], desc: c.id)
    |> limit(@open_conflicts_cap)
    |> Repo.all()
  end

  defp conflict_to_map(%Conflict{} = c) do
    %{
      id: c.id,
      repo: c.repo,
      issue: c.issue,
      doc_id: c.doc_id,
      dataset: c.dataset,
      workspace_id: c.workspace_id,
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

  # Pinned dataset (D18) → exactly that ONE dataset's row, even if the plugin's
  # configured `Settings.datasets/0` does not list it: a token-scoped read must
  # see its OWN dataset's lag and nothing else. Unpinned → the whole configured
  # fleet, as the admin `:ops` console expects.
  defp datasets_snapshot(dataset) when is_binary(dataset) do
    [dataset_snapshot(dataset)]
  end

  defp datasets_snapshot(_dataset) do
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

  # Both `String.to_atom` calls below walk @queue_states, a compile-time literal
  # (`~w(available scheduled executing retryable)`), so no user input can reach
  # the atom table. MIGRATED FROM `.sobelow-skips` (felix-w24-bl-staleness-line-anchor):
  # a baseline row is pinned to a file:LINE, so adding the reporter-loop census
  # section to this module's moduledoc silently moved both call sites and killed
  # both waivers — the exact drift the media.ex precedent documents. An
  # annotation binds by AST adjacency to the def below and survives line moves.
  # sobelow_skip ["DOS.StringToAtom"]
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

        by_state =
          Map.new(@queue_states, fn state ->
            {String.to_atom(state), Map.get(counts, state, 0)}
          end)

        Map.put(by_state, :total, by_state |> Map.values() |> Enum.sum())
      end,
      zero_queue()
    )
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp zero_queue do
    @queue_states
    |> Map.new(fn state -> {String.to_atom(state), 0} end)
    |> Map.put(:total, 0)
  end

  # ---------------------------------------------------------------------------
  # (4) The reporter loop — unacknowledged intake rows
  # ---------------------------------------------------------------------------

  # Same `safe/2` posture as every other section: a missing table or a dark
  # plugin yields an honest empty census rather than a 500 on a health probe.
  # The zeros are distinguishable from a real quiet bridge by `db_ok`, exactly
  # as for the other sections.
  defp unacknowledged_snapshot(dataset) do
    safe(fn -> Acknowledgement.census(dataset) end, zero_unacknowledged())
  end

  defp zero_unacknowledged do
    %{total: 0, closed: 0, open: 0, no_criterion: 0, rows: []}
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
