defmodule Barkpark.Content.DedupPublishToctouTest do
  @moduledoc """
  THE CROSS-doc_id CHECK→INSERT RACE ON THE PUBLISH PATH
  (task `acrc-dedup-toctou-serialize`).

  Two publishes, two DIFFERENT doc_ids, near-duplicate titles, same
  (type, workspace, dataset). Each excludes its OWN id from the E4 candidate
  scan (`where: d.doc_id != ^incumbent`) and neither is committed when the
  other looks, so under snapshot isolation BOTH pass the wall and BOTH commit —
  a duplicate PAIR the wall exists to refuse.

  Nothing already in the tree can see this:

    * `Lifecycle.lock_published_row/2` (#17244) takes `FOR UPDATE` on the
      INCUMBENT row. In this race neither publish HAS an incumbent.
    * `BlockOps.upsert_blocks_doc/3`'s non-paper leg takes a PER-SLUG advisory
      lock. Two different slugs hash to two different keys.
    * The live unique index is exact `[:doc_id, :type, :dataset_id]`
      (migration 20260527134000). The wall's verdict is a fuzzy
      trigram+Jaccard predicate no unique index can express.

  ## Why this file does not use the SQL sandbox

  The sandbox gives every process ONE connection inside ONE uncommitted
  transaction. That defeats the entire scenario twice over: two "concurrent"
  publishes would serialize onto one connection, and neither could ever OBSERVE
  the other's commit because neither ever commits. So both tasks — and the
  setup — check out UNBOXED connections (`Sandbox.checkout(Repo, sandbox: false)`),
  write for real, and the fixtures are deleted by doc-id in `on_exit`. `async:
  false` for the same reason: the rows are really there while the test runs.

  ## The rendezvous

  A serial test cannot produce the interleaving. `DedupWall`'s test-only
  `{dataset, phase, fun}` barrier seam parks both publishes at the same point
  and this process releases them together — see `DedupWall`'s
  `post_check_barrier/3` for why each arm needs a DIFFERENT phase.

  ## RED / GREEN

  Both arms live here. `red arm` disables the scope lock
  (`:dedup_publish_scope_lock`, the control documented in `DedupWall`) and
  observes TWO published rows; `green arm` leaves it on and observes exactly
  one, with the loser refused in the ordinary `{:duplicate_of, _}` shape. A
  lock is the one kind of fix whose absence no single-process test can see, so
  the RED arm is not a commit-message anecdote — it runs in CI beside the
  GREEN one.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{DedupWall, Document}
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import Ecto.Query, only: [from: 2]

  @dataset "dedup_toctou_race"
  @type_name "paper"

  # Near-duplicate on purpose: 8 shared tokens, one extra word apart — far
  # above the wall's refuse band (sim >= 0.55 AND shared >= 3).
  @title_a "Serialize the publish dedup path against the check insert race"
  @title_b "Serialize the publish dedup path against the check insert race window"

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    purge_dataset()

    Content.upsert_schema(
      %{"name" => @type_name, "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    on_exit(fn ->
      Application.delete_env(:barkpark, :dedup_wall_post_check_barrier)
      Application.delete_env(:barkpark, :dedup_publish_scope_lock)
      :ok = Sandbox.checkout(Repo, sandbox: false)
      purge_dataset()
    end)

    :ok
  end

  test "red arm — with the scope lock DISABLED, both near-dup publishes commit" do
    Application.put_env(:barkpark, :dedup_publish_scope_lock, false)

    # `:in_txn`: park both AFTER the in-transaction re-check and BEFORE either
    # commits. Legal only because the lock is off — with it on, the parked
    # holder would be the one the other is waiting for.
    results = race(:in_txn)

    assert [{:ok, _}, {:ok, _}] = Enum.sort_by(results, &elem(&1, 0))

    assert published_ids() == ["race-a", "race-b"],
           "expected the UNSERIALIZED path to persist BOTH near-duplicates"
  end

  test "green arm — with the scope lock ON, exactly one commits and the other 409s" do
    # Control on the control: the flag must be at its shipped default here, or
    # this arm proves nothing about what prod does.
    assert Application.get_env(:barkpark, :dedup_publish_scope_lock, true) != false

    # `:pre_txn`: park both AFTER E4 passed and BEFORE either opens its
    # transaction, so the scope lock is the only thing between them.
    results = race(:pre_txn)

    assert published_ids() |> length() == 1,
           "expected the scope lock to admit exactly ONE of the two near-duplicates"

    assert Enum.count(results, &match?({:ok, %Document{}}, &1)) == 1
    refusals = Enum.filter(results, &match?({:error, {:duplicate_of, _}}, &1))
    assert length(refusals) == 1

    [{:error, {:duplicate_of, payload}}] = refusals
    survivor = hd(published_ids())

    assert payload.duplicate_of == survivor
    assert is_list(payload.similar)
  end

  test "the scope lock key is disjoint from the task/session families" do
    key = DedupWall.publish_scope_lock_key("paper", @dataset, nil)
    assert key == "dedup:paper:global:#{@dataset}"

    assert DedupWall.publish_scope_lock_key("task", "production", "ws-1") ==
             "dedup:task:ws-1:production"

    refute String.starts_with?(key, Barkpark.Tasks.LockKey.task(""))
    refute String.starts_with?(key, "session:")
    refute key == Barkpark.Tasks.LockKey.resources()
  end

  # ── harness ────────────────────────────────────────────────────────────────

  # Two drafts, committed. Two tasks, each on its OWN unboxed connection,
  # publishing concurrently, both parked at `phase` until this process has seen
  # BOTH arrive and releases them together.
  defp race(phase) do
    seed_draft!("race-a", @title_a)
    seed_draft!("race-b", @title_b)

    test_pid = self()

    Application.put_env(
      :barkpark,
      :dedup_wall_post_check_barrier,
      {@dataset, phase,
       fn ->
         send(test_pid, {:parked, self()})

         receive do
           :release -> :ok
         after
           15_000 -> flunk_async("barrier never released")
         end
       end}
    )

    tasks =
      for doc_id <- ["race-a", "race-b"] do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          Content.publish_document(doc_id, @type_name, @dataset)
        end)
      end

    parked = for _ <- 1..2, do: assert_parked()
    Enum.each(parked, &send(&1, :release))

    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp assert_parked do
    receive do
      {:parked, pid} -> pid
    after
      20_000 -> raise "only one publish reached the dedup barrier — the race never set up"
    end
  end

  defp flunk_async(msg), do: raise(msg)

  defp seed_draft!(doc_id, title) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => doc_id, "title" => title}
        |> Map.merge(LabelFixtures.with_registered_labels(%{}, @dataset)),
        @dataset
      )

    :ok
  end

  defp published_ids do
    from(d in Document,
      where: d.dataset == ^@dataset and d.type == ^@type_name and d.status == "published",
      select: d.doc_id,
      order_by: d.doc_id
    )
    |> Repo.all()
  end

  defp purge_dataset do
    Repo.delete_all(from(d in Document, where: d.dataset == ^@dataset))
  end
end
