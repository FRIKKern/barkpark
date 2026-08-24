defmodule Barkpark.Plugins.Github.HealthTest do
  @moduledoc """
  Wave-6 slice-1: the pure LOCAL-READ sync-health aggregate (epic observability).

  Proves `Health.snapshot/1`:

    * is TOTAL and fully-shaped with the plugin DARK and the DB empty (zeros,
      never a raise — it is called from a LiveView mount AND a controller);
    * buckets open conflicts by the fixed 3-kind set, counts `total`, and hands
      the newest rows as plain maps capped at ~50 (D7 visible quarantine);
    * filters conflicts to the configured repo, and scans repo-wide when dark;
    * reports per-dataset cursor / head / lag / pending over the EXACT wave-2
      Outbox drain window, flagging `pending_capped` at the 500 cap;
    * counts `github_mirror` Oban queue depth by state, ignoring other queues
      and terminal states;
    * surfaces `active`/`repo` for the console header.

  DB-only — no `Auth`, no `Client`, no GraphQL, no network anywhere.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Conflict, Conflicts, Cursor, Health}
  alias Barkpark.Repo

  @config_key Barkpark.Plugins.Github
  @dataset "production"

  # --- helpers ---------------------------------------------------------------

  # Set the plugin's app-env creds for a case, restoring on exit. Env wins in the
  # Settings resolver, so this drives active?/repo/datasets without a DB row.
  defp put_config(kw) do
    prev = Application.get_env(:barkpark, @config_key)
    Application.put_env(:barkpark, @config_key, kw)
    on_exit(fn -> restore_config(prev) end)
  end

  defp restore_config(nil), do: Application.delete_env(:barkpark, @config_key)
  defp restore_config(prev), do: Application.put_env(:barkpark, @config_key, prev)

  defp full_creds(extra \\ []) do
    Keyword.merge(
      [
        repo: "FRIKKern/barkpark",
        app_id: "123",
        installation_id: "456",
        private_key: "-----BEGIN KEY-----\nx\n-----END KEY-----",
        webhook_secret: "shh"
      ],
      extra
    )
  end

  defp insert_event!(dataset, doc_id, source \\ "api", type \\ "task") do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: type,
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => type},
      source: source,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp record_conflict!(overrides) do
    attrs =
      Map.merge(
        %{
          repo: "FRIKKern/barkpark",
          issue: System.unique_integer([:positive]),
          doc_id: "gh-1",
          dataset: @dataset,
          kind: "out_of_band_edit",
          detail: %{}
        },
        Map.new(overrides)
      )

    {:ok, c} = Conflicts.record(attrs)
    c
  end

  defp insert_job!(queue, state) do
    %{"doc_id" => "gh-1", "dataset" => @dataset}
    |> Oban.Job.new(worker: "Barkpark.Plugins.Github.MirrorJob", queue: queue)
    |> Ecto.Changeset.put_change(:state, state)
    |> Ecto.Changeset.put_change(:scheduled_at, DateTime.utc_now())
    |> Repo.insert!()
  end

  # --- totality / dark plugin ------------------------------------------------

  describe "dark plugin, empty DB" do
    test "returns a fully-shaped, all-zero snapshot without raising" do
      restore_config(nil)

      snap = Health.snapshot()

      assert %{
               active: false,
               repo: nil,
               conflicts: %{
                 out_of_band_edit: 0,
                 detached: 0,
                 dedup_refused: 0,
                 total: 0,
                 open: []
               },
               datasets: [
                 %{
                   dataset: "production",
                   cursor: 0,
                   head: 0,
                   lag: 0,
                   pending: 0,
                   pending_capped: false
                 }
               ],
               queue: %{available: 0, scheduled: 0, executing: 0, retryable: 0, total: 0},
               unacknowledged: %{total: 0, closed: 0, open: 0, no_criterion: 0, rows: []}
             } = snap
    end

    test "snapshot/1 accepts opts and is always a map" do
      restore_config(nil)
      assert is_map(Health.snapshot(foo: :bar))
    end

    test "db_ok is true against a live DB (the snapshot liveness bit)" do
      restore_config(nil)

      # The one field that separates a genuinely healthy zero-snapshot from the
      # all-zeros a dead DB would silently produce. In the test sandbox the DB is
      # up, so the `SELECT 1` round-trip succeeds → true. A DB outage would raise
      # inside `safe/2` and degrade this to false while the rest of the snapshot
      # still totals (never a raise to the caller).
      assert Health.snapshot().db_ok == true
    end
  end

  # --- the reporter loop -----------------------------------------------------

  describe "unacknowledged census (the reporter loop)" do
    test "an unanswered intake row reaches the snapshot an operator reads" do
      restore_config(nil)

      %Barkpark.Content.Document{}
      |> Ecto.Changeset.change(%{
        doc_id: "gh-9531",
        type: "task",
        dataset: @dataset,
        title: "UserNotifier hardcodes the transactional From address",
        status: "draft",
        content: %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "github" => %{
            "repo" => "FRIKKern/barkpark",
            "issue" => 9531,
            "state" => "intake"
          }
        },
        rev: Ecto.UUID.generate()
      })
      |> Repo.insert!()

      census = Health.snapshot().unacknowledged

      assert census.total == 1
      assert census.open == 1
      assert census.no_criterion == 1
      assert [%{doc_id: "gh-9531", issue: 9531, state: "intake"}] = census.rows
    end

    test "the dataset pin narrows the census the same way it narrows conflicts (D18)" do
      restore_config(nil)

      for {ds, number} <- [{@dataset, 9531}, {"staging", 8100}] do
        %Barkpark.Content.Document{}
        |> Ecto.Changeset.change(%{
          doc_id: "gh-#{number}",
          type: "task",
          dataset: ds,
          title: "outsider ##{number}",
          status: "draft",
          content: %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "github" => %{"repo" => "FRIKKern/barkpark", "issue" => number, "state" => "intake"}
          },
          rev: Ecto.UUID.generate()
        })
        |> Repo.insert!()
      end

      assert Health.snapshot(@dataset).unacknowledged.total == 1
      assert Health.snapshot("staging").unacknowledged.total == 1
      assert Health.snapshot().unacknowledged.total == 2
    end
  end

  # --- active / repo header --------------------------------------------------

  describe "active + repo header" do
    test "active? true and repo surface when fully provisioned" do
      put_config(full_creds())

      snap = Health.snapshot()

      assert snap.active == true
      assert snap.repo == "FRIKKern/barkpark"
    end

    test "half-provisioned plugin is inactive (fail-closed) but still totals" do
      put_config(full_creds(private_key: nil))

      snap = Health.snapshot()

      assert snap.active == false
      # repo is still resolvable even when the gate is closed
      assert snap.repo == "FRIKKern/barkpark"
    end
  end

  # --- conflicts -------------------------------------------------------------

  describe "conflicts bucketing" do
    test "buckets open conflicts by the fixed 3 kinds and totals them" do
      restore_config(nil)

      record_conflict!(%{kind: "out_of_band_edit", issue: 1})
      record_conflict!(%{kind: "out_of_band_edit", issue: 2})
      record_conflict!(%{kind: "detached", issue: 3})
      record_conflict!(%{kind: "dedup_refused", issue: 4})

      c = Health.snapshot().conflicts

      assert c.out_of_band_edit == 2
      assert c.detached == 1
      assert c.dedup_refused == 1
      assert c.total == 4
      assert length(c.open) == 4
    end

    test "resolved conflicts drop out of the counts" do
      restore_config(nil)

      keep = record_conflict!(%{kind: "detached", issue: 10})
      drop = record_conflict!(%{kind: "detached", issue: 11})
      {:ok, _} = Conflicts.resolve(drop.id)

      c = Health.snapshot().conflicts

      assert c.detached == 1
      assert c.total == 1
      assert [%{id: id}] = c.open
      assert id == keep.id
    end

    test "open rows are plain maps, newest-first" do
      restore_config(nil)

      _older = record_conflict!(%{kind: "out_of_band_edit", issue: 100})
      newer = record_conflict!(%{kind: "detached", issue: 101})

      [first | _] = Health.snapshot().conflicts.open

      assert is_map(first)
      refute match?(%Conflict{}, first)
      assert first.id == newer.id
      assert Map.has_key?(first, :kind)
      assert Map.has_key?(first, :issue)
      assert Map.has_key?(first, :detail)
    end

    test "open list is capped at 50 while total counts all scanned rows" do
      restore_config(nil)

      for i <- 1..60, do: record_conflict!(%{kind: "out_of_band_edit", issue: 1000 + i})

      c = Health.snapshot().conflicts

      assert c.total == 60
      assert length(c.open) == 50
    end

    test "conflicts are filtered to the configured repo" do
      put_config(full_creds(repo: "FRIKKern/barkpark"))

      record_conflict!(%{repo: "FRIKKern/barkpark", kind: "detached", issue: 5})
      record_conflict!(%{repo: "other/elsewhere", kind: "detached", issue: 6})

      c = Health.snapshot().conflicts

      assert c.detached == 1
      assert c.total == 1
      assert [%{repo: "FRIKKern/barkpark"}] = c.open
    end
  end

  # --- datasets: cursor / head / lag / pending -------------------------------

  describe "dataset lag + pending" do
    test "reports cursor, head, lag and pending over the outbox window" do
      restore_config(nil)

      _e1 = insert_event!(@dataset, "a")
      e2 = insert_event!(@dataset, "b")
      e3 = insert_event!(@dataset, "c")

      # cursor sits at e2 → e3 is the one un-mirrored task event
      Cursor.put(@dataset, e2.id)

      [ds] = Health.snapshot().datasets

      assert ds.dataset == @dataset
      assert ds.cursor == e2.id
      assert ds.head == e3.id
      assert ds.lag == e3.id - e2.id
      assert ds.pending == 1
      assert ds.pending_capped == false
    end

    test "github-origin and non-task events are NOT counted as pending" do
      restore_config(nil)

      insert_event!(@dataset, "local", "api", "task")
      insert_event!(@dataset, "intaken", "github", "task")
      insert_event!(@dataset, "a-post", "api", "post")

      [ds] = Health.snapshot().datasets

      # only the local task counts toward pending (loop-cut #2 + task-only window)
      assert ds.pending == 1
    end

    test "pending_capped flags when the drain window hits the 500 cap" do
      restore_config(nil)

      now = DateTime.utc_now()

      rows =
        for i <- 1..500 do
          %{
            dataset: @dataset,
            type: "task",
            doc_id: "bulk-#{i}",
            mutation: "create",
            rev: "r-bulk-#{i}",
            document: %{"_id" => "bulk-#{i}", "_type" => "task"},
            source: "api",
            inserted_at: now
          }
        end

      {500, _} = Repo.insert_all(MutationEvent, rows)

      [ds] = Health.snapshot().datasets

      assert ds.pending == 500
      assert ds.pending_capped == true
    end

    test "multiple configured datasets each get a row" do
      put_config(full_creds(github_mirror_datasets: ["production", "staging"]))

      names = Health.snapshot().datasets |> Enum.map(& &1.dataset)
      assert names == ["production", "staging"]
    end
  end

  # --- queue depth -----------------------------------------------------------

  describe "queue depth" do
    test "counts github_mirror jobs by live state, ignoring other queues/terminal" do
      restore_config(nil)

      insert_job!("github_mirror", "available")
      insert_job!("github_mirror", "available")
      insert_job!("github_mirror", "scheduled")
      insert_job!("github_mirror", "executing")
      insert_job!("github_mirror", "retryable")
      # ignored: terminal state
      insert_job!("github_mirror", "completed")
      # ignored: a different queue
      insert_job!("default", "available")

      q = Health.snapshot().queue

      assert q.available == 2
      assert q.scheduled == 1
      assert q.executing == 1
      assert q.retryable == 1
    end

    test "empty queue is all zeros" do
      restore_config(nil)

      assert Health.snapshot().queue == %{
               available: 0,
               scheduled: 0,
               executing: 0,
               retryable: 0,
               total: 0
             }
    end
  end

  # --- dataset-scoped snapshot (D18) -----------------------------------------

  describe "dataset-pinned snapshot (D18)" do
    test "a pinned dataset narrows conflicts + datasets; snapshot(A) differs from snapshot(B)" do
      # Dark plugin → no repo filter, so the isolation on show is PURELY the
      # dataset filter (not a repo coincidence).
      restore_config(nil)

      record_conflict!(%{dataset: "alpha", kind: "detached", issue: 201})
      record_conflict!(%{dataset: "beta", kind: "detached", issue: 202})
      record_conflict!(%{dataset: "beta", kind: "out_of_band_edit", issue: 203})

      a = Health.snapshot("alpha")
      b = Health.snapshot("beta")

      # conflicts filtered to the pinned dataset — the other dataset is invisible
      assert a.conflicts.total == 1
      assert a.conflicts.detached == 1
      assert a.conflicts.out_of_band_edit == 0
      assert Enum.map(a.conflicts.open, & &1.dataset) == ["alpha"]

      assert b.conflicts.total == 2
      assert b.conflicts.detached == 1
      assert b.conflicts.out_of_band_edit == 1
      assert a.conflicts.open |> Enum.map(& &1.dataset) |> Enum.uniq() == ["alpha"]
      assert b.conflicts.open |> Enum.map(& &1.dataset) |> Enum.uniq() == ["beta"]

      # per-dataset lag rows narrowed to exactly the pinned dataset
      assert Enum.map(a.datasets, & &1.dataset) == ["alpha"]
      assert Enum.map(b.datasets, & &1.dataset) == ["beta"]

      # the two snapshots genuinely differ (the whole-fleet leak is closed)
      refute a.conflicts == b.conflicts
    end

    test "a pinned dataset the plugin does not configure still yields its OWN one row" do
      # Settings.datasets/0 lists only production/staging, but a token scoped to
      # a third dataset must see its OWN row (zeros), never the configured fleet.
      put_config(full_creds(github_mirror_datasets: ["production", "staging"]))

      snap = Health.snapshot("gamma")

      assert Enum.map(snap.datasets, & &1.dataset) == ["gamma"]
    end

    test "blank / non-binary filter is the whole-fleet view (legacy behavior held)" do
      put_config(full_creds(github_mirror_datasets: ["production", "staging"]))

      record_conflict!(%{
        repo: "FRIKKern/barkpark",
        dataset: "production",
        kind: "detached",
        issue: 301
      })

      record_conflict!(%{
        repo: "FRIKKern/barkpark",
        dataset: "staging",
        kind: "detached",
        issue: 302
      })

      fleet = Health.snapshot()

      assert fleet.conflicts.total == 2
      assert Enum.map(fleet.datasets, & &1.dataset) == ["production", "staging"]

      # a blank string trims to "" → whole-fleet, identical to the no-arg call
      assert Health.snapshot("   ") == fleet
    end
  end
end
