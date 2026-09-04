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

  ## Nondeterminism class: SHARED STATE — whole-table counts in one shared DB

  **Specimen (2026-09-03).** Running the whole `api/test/barkpark/plugins`
  directory, this module reddened TWICE, on two different assertions: `"dataset
  lag + pending…"` and `"empty DB returns a fully-shaped, all-zero snapshot"`.
  Neither reproduced in isolation. Both were WHOLE-DATABASE counting assertions:
  they asserted on `Health.snapshot()` — the unpinned, whole-fleet view — while
  the rows they created lived in the well-known shared dataset `"production"`.
  Every agent on this box and every CI job share ONE test database
  (`MIX_TEST_PARTITION` is unset), so ONE `github_sync_conflicts` row, ONE
  `mutation_events` row in `"production"`, ONE `github_mirror` Oban job or ONE
  `gh-<num>` intake document committed by anybody else lands inside the count and
  reds an assertion about rows this test never wrote. Same class as
  `TasksMergeGateNagTest` (PR #15763) and the value-audit F7 census modules.

  **The fix, and why it is the honest one.** `Health.snapshot/1` ALREADY takes a
  dataset filter (D18) that narrows the per-dataset rows, the open-conflict read
  AND the unacknowledged census. So production code needed no change: every test
  here now writes into its OWN per-test dataset (`ctx.ds`, unique per test) and
  asserts on `Health.snapshot(ctx.ds)`. A foreign row in `"production"` is then
  structurally invisible, rather than merely unlikely.

  **The one section that cannot be scoped: `queue`.** Oban queue depth is
  plugin-global by design (`@queue "github_mirror"`, no dataset column in the
  read), and narrowing it would change what `Health` reports in production. So
  the queue assertions are RELATIVE instead: read the depth before, insert, read
  after, assert the DELTA. That is robust to every foreign job that already
  exists; it is NOT robust to a foreign job committed inside the microseconds
  between the two reads, and that residual is stated here rather than hidden.

  **The plant (the permanent proof).** `setup` calls `plant_foreign_rows!/0`
  BEFORE every test body: a foreign `mutation_events` row, a foreign open
  conflict, a foreign `github_mirror` Oban job and a foreign `gh-<num>` intake
  document, all in `"production"` — exactly the four shapes another agent's suite
  commits. Every assertion below holds with those rows present. Revert the
  dataset pinning and the two 2026-09-03 assertions red again, naming the planted
  row's contribution.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Conflict, Conflicts, Cursor, Health}
  alias Barkpark.Repo

  @config_key Barkpark.Plugins.Github

  # The well-known dataset every OTHER agent's suite writes into. This module
  # never asserts on it — it only PLANTS into it, so "a foreign row exists" is a
  # permanent precondition of every test rather than an occasional accident.
  @shared_dataset "production"

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
          dataset: @shared_dataset,
          kind: "out_of_band_edit",
          detail: %{}
        },
        Map.new(overrides)
      )

    {:ok, c} = Conflicts.record(attrs)
    c
  end

  defp insert_job!(queue, state) do
    %{"doc_id" => "gh-1", "dataset" => @shared_dataset}
    |> Oban.Job.new(worker: "Barkpark.Plugins.Github.MirrorJob", queue: queue)
    |> Ecto.Changeset.put_change(:state, state)
    |> Ecto.Changeset.put_change(:scheduled_at, DateTime.utc_now())
    |> Repo.insert!()
  end

  # A `gh-<num>` intake row — what `Intake` births from an outsider's issue and
  # what `Acknowledgement.census/2` counts as unanswered.
  defp insert_intake_doc!(dataset, number, title \\ "an outsider's issue") do
    %Barkpark.Content.Document{}
    |> Ecto.Changeset.change(%{
      doc_id: "gh-#{number}",
      type: "task",
      dataset: dataset,
      title: title,
      status: "draft",
      content: %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "github" => %{
          "repo" => "FRIKKern/barkpark",
          "issue" => number,
          "state" => "intake"
        }
      },
      rev: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  # THE PLANT. One row of each shape another agent's suite writes into the
  # SHARED dataset, so every assertion below is proven against a database that
  # already holds rows this test does not own. Called from `setup` (so it lands
  # BEFORE every test body) and again, inside the two 2026-09-03 specimen tests,
  # AFTER their own rows — the strictly harder case, where the foreign row also
  # carries the higher `mutation_events.id`.
  defp plant_foreign_rows! do
    n = System.unique_integer([:positive])

    insert_event!(@shared_dataset, "foreign-#{n}")
    record_conflict!(%{dataset: @shared_dataset, kind: "detached", issue: n, doc_id: "gh-f#{n}"})
    insert_job!("github_mirror", "available")
    insert_intake_doc!(@shared_dataset, 900_000 + rem(n, 90_000), "foreign intake #{n}")

    :ok
  end

  setup do
    plant_foreign_rows!()

    # Every test owns a dataset nobody else can write to. This is the fix: the
    # snapshot is read PINNED to it (D18), so foreign rows cannot enter a count.
    {:ok, ds: "health-test-#{System.unique_integer([:positive])}"}
  end

  # --- totality / dark plugin ------------------------------------------------

  describe "dark plugin, empty DB" do
    test "returns a fully-shaped, all-zero snapshot without raising", %{ds: ds} do
      restore_config(nil)

      snap = Health.snapshot(ds)

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
                   dataset: ^ds,
                   cursor: 0,
                   head: 0,
                   lag: 0,
                   pending: 0,
                   pending_capped: false
                 }
               ],
               unacknowledged: %{total: 0, closed: 0, open: 0, no_criterion: 0, rows: []}
             } = snap

      # `queue` is the ONE section with no dataset scope (Oban depth is
      # plugin-global by design), so its zeros were never a property of the code
      # — they were a property of an empty shared database, which is precisely
      # what reddened here on 2026-09-03. What IS a property of the code is that
      # the section is fully shaped and internally consistent.
      assert %{available: a, scheduled: s, executing: x, retryable: r, total: t} = snap.queue
      assert Enum.all?([a, s, x, r, t], &(is_integer(&1) and &1 >= 0))
      assert t == a + s + x + r
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
    test "an unanswered intake row reaches the snapshot an operator reads", %{ds: ds} do
      restore_config(nil)

      insert_intake_doc!(
        ds,
        9531,
        "UserNotifier hardcodes the transactional From address"
      )

      census = Health.snapshot(ds).unacknowledged

      assert census.total == 1
      assert census.open == 1
      assert census.no_criterion == 1
      assert [%{doc_id: "gh-9531", issue: 9531, state: "intake"}] = census.rows
    end

    test "the dataset pin narrows the census the same way it narrows conflicts (D18)", %{ds: ds} do
      restore_config(nil)

      other = ds <> "-b"

      insert_intake_doc!(ds, 9531, "outsider #9531")
      insert_intake_doc!(other, 8100, "outsider #8100")

      assert Health.snapshot(ds).unacknowledged.total == 1
      assert Health.snapshot(other).unacknowledged.total == 1

      # Unpinned is the WHOLE FLEET, which in a shared database also holds the
      # planted foreign row — so the fleet claim is stated as containment (both
      # of mine are visible without a pin), never as a whole-table count.
      fleet_ids = Health.snapshot().unacknowledged.rows |> Enum.map(& &1.doc_id) |> MapSet.new()
      assert MapSet.member?(fleet_ids, "gh-9531")
      assert MapSet.member?(fleet_ids, "gh-8100")
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
    test "buckets open conflicts by the fixed 3 kinds and totals them", %{ds: ds} do
      restore_config(nil)

      record_conflict!(%{dataset: ds, kind: "out_of_band_edit", issue: 1})
      record_conflict!(%{dataset: ds, kind: "out_of_band_edit", issue: 2})
      record_conflict!(%{dataset: ds, kind: "detached", issue: 3})
      record_conflict!(%{dataset: ds, kind: "dedup_refused", issue: 4})

      c = Health.snapshot(ds).conflicts

      assert c.out_of_band_edit == 2
      assert c.detached == 1
      assert c.dedup_refused == 1
      assert c.total == 4
      assert length(c.open) == 4
    end

    test "resolved conflicts drop out of the counts", %{ds: ds} do
      restore_config(nil)

      keep = record_conflict!(%{dataset: ds, kind: "detached", issue: 10})
      drop = record_conflict!(%{dataset: ds, kind: "detached", issue: 11})
      {:ok, _} = Conflicts.resolve(drop.id)

      c = Health.snapshot(ds).conflicts

      assert c.detached == 1
      assert c.total == 1
      assert [%{id: id}] = c.open
      assert id == keep.id
    end

    test "open rows are plain maps, newest-first", %{ds: ds} do
      restore_config(nil)

      _older = record_conflict!(%{dataset: ds, kind: "out_of_band_edit", issue: 100})
      newer = record_conflict!(%{dataset: ds, kind: "detached", issue: 101})

      [first | _] = Health.snapshot(ds).conflicts.open

      assert is_map(first)
      refute match?(%Conflict{}, first)
      assert first.id == newer.id
      assert Map.has_key?(first, :kind)
      assert Map.has_key?(first, :issue)
      assert Map.has_key?(first, :detail)
    end

    test "open list is capped at 50 while total counts all scanned rows", %{ds: ds} do
      restore_config(nil)

      for i <- 1..60, do: record_conflict!(%{dataset: ds, kind: "out_of_band_edit", issue: 1000 + i})

      c = Health.snapshot(ds).conflicts

      assert c.total == 60
      assert length(c.open) == 50
    end

    test "conflicts are filtered to the configured repo", %{ds: ds} do
      put_config(full_creds(repo: "FRIKKern/barkpark"))

      record_conflict!(%{dataset: ds, repo: "FRIKKern/barkpark", kind: "detached", issue: 5})
      record_conflict!(%{dataset: ds, repo: "other/elsewhere", kind: "detached", issue: 6})

      c = Health.snapshot(ds).conflicts

      assert c.detached == 1
      assert c.total == 1
      assert [%{repo: "FRIKKern/barkpark"}] = c.open
    end
  end

  # --- datasets: cursor / head / lag / pending -------------------------------

  describe "dataset lag + pending" do
    test "reports cursor, head, lag and pending over the outbox window", %{ds: ds} do
      restore_config(nil)

      _e1 = insert_event!(ds, "a")
      e2 = insert_event!(ds, "b")
      e3 = insert_event!(ds, "c")

      # THE 2026-09-03 SPECIMEN, made permanent and made HARDER than the
      # original race: this foreign `"production"` event is inserted AFTER e3, so
      # it carries the higher `mutation_events.id`. Read unpinned, it becomes
      # `head` and reds `ds.head == e3.id`. Read pinned to `ds`, it does not
      # exist.
      plant_foreign_rows!()

      # cursor sits at e2 → e3 is the one un-mirrored task event
      Cursor.put(ds, e2.id)

      [row] = Health.snapshot(ds).datasets

      assert row.dataset == ds
      assert row.cursor == e2.id
      assert row.head == e3.id
      assert row.lag == e3.id - e2.id
      assert row.pending == 1
      assert row.pending_capped == false
    end

    test "github-origin and non-task events are NOT counted as pending", %{ds: ds} do
      restore_config(nil)

      insert_event!(ds, "local", "api", "task")
      insert_event!(ds, "intaken", "github", "task")
      insert_event!(ds, "a-post", "api", "post")

      [row] = Health.snapshot(ds).datasets

      # only the local task counts toward pending (loop-cut #2 + task-only window)
      assert row.pending == 1
    end

    test "pending_capped flags when the drain window hits the 500 cap", %{ds: ds} do
      restore_config(nil)

      now = DateTime.utc_now()

      rows =
        for i <- 1..500 do
          %{
            dataset: ds,
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

      [row] = Health.snapshot(ds).datasets

      assert row.pending == 500
      assert row.pending_capped == true
    end

    test "multiple configured datasets each get a row" do
      # Config-driven, not DB-driven: `Settings.datasets/0` decides the row set,
      # so no foreign row can reach this assertion.
      put_config(full_creds(github_mirror_datasets: ["production", "staging"]))

      names = Health.snapshot().datasets |> Enum.map(& &1.dataset)
      assert names == ["production", "staging"]
    end
  end

  # --- queue depth -----------------------------------------------------------

  describe "queue depth" do
    # Oban depth is plugin-global (no dataset scope in `Health`, and adding one
    # would change what production reports), so these two assert on the DELTA a
    # test's own jobs produce — the count-after-minus-count-before shape. That
    # holds no matter how many foreign `github_mirror` jobs already sit in the
    # shared database, including the one `setup` plants.
    test "counts github_mirror jobs by live state, ignoring other queues/terminal" do
      restore_config(nil)

      before = Health.snapshot().queue

      insert_job!("github_mirror", "available")
      insert_job!("github_mirror", "available")
      insert_job!("github_mirror", "scheduled")
      insert_job!("github_mirror", "executing")
      insert_job!("github_mirror", "retryable")

      q = Health.snapshot().queue

      assert q.available - before.available == 2
      assert q.scheduled - before.scheduled == 1
      assert q.executing - before.executing == 1
      assert q.retryable - before.retryable == 1
      assert q.total - before.total == 5
    end

    test "terminal states and other queues add nothing to the depth" do
      restore_config(nil)

      before = Health.snapshot().queue

      # ignored: terminal state
      insert_job!("github_mirror", "completed")
      # ignored: a different queue
      insert_job!("default", "available")

      q = Health.snapshot().queue

      assert q.available - before.available == 0
      assert q.scheduled - before.scheduled == 0
      assert q.executing - before.executing == 0
      assert q.retryable - before.retryable == 0
      assert q.total - before.total == 0
    end
  end

  # --- dataset-scoped snapshot (D18) -----------------------------------------

  describe "dataset-pinned snapshot (D18)" do
    test "a pinned dataset narrows conflicts + datasets; snapshot(A) differs from snapshot(B)",
         %{ds: ds} do
      # Dark plugin → no repo filter, so the isolation on show is PURELY the
      # dataset filter (not a repo coincidence).
      restore_config(nil)

      alpha = ds <> "-alpha"
      beta = ds <> "-beta"

      record_conflict!(%{dataset: alpha, kind: "detached", issue: 201})
      record_conflict!(%{dataset: beta, kind: "detached", issue: 202})
      record_conflict!(%{dataset: beta, kind: "out_of_band_edit", issue: 203})

      a = Health.snapshot(alpha)
      b = Health.snapshot(beta)

      # conflicts filtered to the pinned dataset — the other dataset is invisible
      assert a.conflicts.total == 1
      assert a.conflicts.detached == 1
      assert a.conflicts.out_of_band_edit == 0
      assert Enum.map(a.conflicts.open, & &1.dataset) == [alpha]

      assert b.conflicts.total == 2
      assert b.conflicts.detached == 1
      assert b.conflicts.out_of_band_edit == 1
      assert a.conflicts.open |> Enum.map(& &1.dataset) |> Enum.uniq() == [alpha]
      assert b.conflicts.open |> Enum.map(& &1.dataset) |> Enum.uniq() == [beta]

      # per-dataset lag rows narrowed to exactly the pinned dataset
      assert Enum.map(a.datasets, & &1.dataset) == [alpha]
      assert Enum.map(b.datasets, & &1.dataset) == [beta]

      # the two snapshots genuinely differ (the whole-fleet leak is closed)
      refute a.conflicts == b.conflicts
    end

    test "a pinned dataset the plugin does not configure still yields its OWN one row", %{ds: ds} do
      # Settings.datasets/0 lists only production/staging, but a token scoped to
      # a third dataset must see its OWN row (zeros), never the configured fleet.
      put_config(full_creds(github_mirror_datasets: ["production", "staging"]))

      snap = Health.snapshot(ds)

      assert Enum.map(snap.datasets, & &1.dataset) == [ds]
    end

    test "blank / non-binary filter is the whole-fleet view (legacy behavior held)", %{ds: ds} do
      put_config(full_creds(github_mirror_datasets: ["production", "staging"]))

      mine = [
        record_conflict!(%{
          repo: "FRIKKern/barkpark",
          dataset: ds,
          kind: "detached",
          issue: 301
        }),
        record_conflict!(%{
          repo: "FRIKKern/barkpark",
          dataset: ds <> "-b",
          kind: "detached",
          issue: 302
        })
      ]

      fleet = Health.snapshot()

      # Containment, not a whole-table count: BOTH of mine are visible without a
      # pin (that is what "whole fleet" means), while the planted foreign row is
      # free to be in there too.
      fleet_ids = fleet.conflicts.open |> Enum.map(& &1.id) |> MapSet.new()
      assert Enum.all?(mine, &MapSet.member?(fleet_ids, &1.id))
      assert Enum.map(fleet.datasets, & &1.dataset) == ["production", "staging"]

      # a blank string trims to "" → whole-fleet, identical to the no-arg call
      assert Health.snapshot("   ") == fleet
    end
  end
end
