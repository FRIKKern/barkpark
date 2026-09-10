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

  # Near-duplicate on purpose. The two titles differ only by trailing
  # STOPWORDS ("at it", both in DedupWall's @stopwords), so their scored token
  # sets are IDENTICAL and the pair sits at the top of the refuse band
  # (sim >= 0.55 AND shared >= 3) whatever tag fixture a given arm uses. An
  # earlier draft differed by one real word and measured 0.5333 on the
  # paper-birth arm — INSIDE the advise band, so the wall correctly declined to
  # refuse and the arm proved nothing about the lock.
  @title_a "Serialize the publish dedup path against the check insert race"
  @title_b "Serialize the publish dedup path against the check insert race at it"

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

  test "paper-birth arm — two concurrent near-dup paper births, exactly one commits" do
    # THE SECOND DOOR. `BlockOps.upsert_blocks_doc/3` births PUBLISHED rows by
    # direct Repo write, with its own AuthoringWall mount, and its per-slug
    # advisory lock gives two different slugs two different keys — so before
    # this change it carried the identical race. It takes the SAME scope key as
    # the lifecycle path, so the two doors also exclude each OTHER.
    LabelFixtures.register_tags!(@dataset)

    test_pid = self()

    Application.put_env(
      :barkpark,
      :dedup_wall_post_check_barrier,
      {@dataset, :pre_txn, fn -> park(test_pid) end}
    )

    tasks =
      for {slug, title} <- [{"paper-a", @title_a}, {"paper-b", @title_b}] do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          Content.upsert_paper(
            LabelFixtures.paper_attrs(%{
              "slug" => slug,
              "dataset" => @dataset,
              "blocks" => title_blocks(title, slug)
            })
          )
        end)
      end

    parked = for _ <- 1..2, do: assert_parked()
    Enum.each(parked, &send(&1, :release))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert length(published_ids()) == 1
    assert Enum.count(results, &match?({:ok, %Document{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:duplicate_of, _}}, &1)) == 1
  end

  test "the paper-birth broadcast fires AFTER commit, not inside the lock's transaction" do
    # THE HAZARD THE FIRST DRAFT OF THIS FIX INTRODUCED (independent review,
    # lead-api-r4). Wrapping `persist_blocks_doc/10` whole moved its tail
    # pre-commit, and `broadcast_paper_update/1` is a RAW
    # `Phoenix.PubSub.broadcast` — `Broadcast.write_atomically/1` defers and
    # flushes the QUEUED kind, it cannot defer that one. So the message went
    # out while the row was still invisible to every other connection.
    #
    # The probe is a SEPARATE process on its OWN unboxed connection: it reads
    # `documents` the instant the message lands. A pre-commit broadcast makes
    # that read miss; a post-commit one makes it hit. Nothing here inspects
    # implementation — it asks the question a real subscriber asks.
    LabelFixtures.register_tags!(@dataset)
    slug = "broadcast-order"
    test_pid = self()

    # The broadcaster keys the topic on the row's RESOLVED workspace, so the
    # probe has to subscribe to the same one. `upsert_paper` falls back to the
    # seeded Default workspace when the caller asserts no scope.
    %{rows: [[raw_ws]]} = Repo.query!("SELECT id FROM workspaces WHERE slug = 'default' LIMIT 1")
    {:ok, workspace_id} = Ecto.UUID.cast(raw_ws)
    topic = Barkpark.Content.Broadcast.paper_topic(slug, workspace_id, @dataset)

    probe =
      spawn_link(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)

        send(test_pid, :subscribed)

        receive do
          {:paper_updated, _} ->
            send(test_pid, {:visible?, Repo.exists?(row_query(slug))})
        after
          15_000 -> send(test_pid, {:visible?, :no_message})
        end
      end)

    assert_receive :subscribed, 5_000

    {:ok, _} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "blocks" => title_blocks("Broadcast ordering probe paper", slug)
        })
      )

    assert_receive {:visible?, visible}, 20_000
    Process.unlink(probe)

    assert visible == true,
           "the {:paper_updated, _} broadcast reached a subscriber before the row was committed"
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
      {@dataset, phase, fn -> park(test_pid) end}
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

  defp title_blocks(title, slug) do
    [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => title
      },
      %{
        "id" => "p1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Body for #{slug}."}]
      }
    ]
  end

  defp row_query(slug) do
    from(d in Document,
      where:
        d.doc_id == ^slug and d.dataset == ^@dataset and d.type == ^@type_name and
          d.status == "published"
    )
  end

  defp park(test_pid) do
    send(test_pid, {:parked, self()})

    receive do
      :release -> :ok
    after
      15_000 -> raise "barrier never released"
    end
  end

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

  # UNBOXED MEANS REALLY COMMITTED, so the teardown has to reach EVERY table
  # this dataset touched — not just `documents`. The first version cleaned only
  # documents and reddened three unrelated tests in
  # `after_write_listener_seam_test.exs`: their `all_enqueued/1` assertions read
  # `oban_jobs` GLOBALLY, and the FindabilityPosttest jobs these publishes really
  # enqueued were still sitting there. A sandboxed neighbour cannot see a
  # sandboxed test's rows; it sees every one of ours.
  defp purge_dataset do
    Repo.delete_all(from(d in Document, where: d.dataset == ^@dataset))

    Repo.query!("DELETE FROM oban_jobs WHERE args->>'dataset' = $1", [@dataset])
    :ok
  end
end
