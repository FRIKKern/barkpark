defmodule Barkpark.Tasks.AdvisoryLockKeyConvergenceTest do
  @moduledoc """
  task-eal-bl-lock-key-convergence — one `task:<uuid>` advisory-lock family.

  ## What was actually wrong, and what the filing got wrong

  The filing said claim_by_id, the TTL sweeper and the compactor lock
  `hashtext('task:' || doc_id)` on the SLUG while close/release/move/fence/
  mutations lock `task:<uuid>`.

  Half of that was a VARIABLE-NAME ILLUSION. `TtlSweeper.reap_one/3`,
  `TtlSweeper.lapse_one/2` and `Compactor.compact_one/2` took a parameter
  spelled `doc_id`, but every call site binds it from `%Document{id: doc_id}` —
  the uuid PRIMARY KEY — and the very next statement is `Repo.get(Document,
  doc_id)`, a by-PK read. Those two modules were ALREADY in the uuid family,
  and their "SAME key as `Tasks.close/3`" comments were TRUE. Only their
  spelling (`'task:' || doc_id`) was false.

  The divergence the filing missed is `Pulse.pulse/4` and `Renew.renew/2`.
  Both are handed the uuid, both then did a pre-lock read purely to fetch the
  `doc_id` SLUG, and both locked `task:<doc_id>` — a different integer from the
  one close/release/stage/stamp/sweeper/compactor take. A pulse and a close on
  one row did not exclude each other.

  claim_by_id's slug lock is real and is KEPT: before the row is fetched there
  is no uuid to key on. It now takes `task:<uuid>` as well, after it resolves
  the slug and BEFORE it takes the `FOR UPDATE` row lock — advisory-before-row
  everywhere, so a claim and a close cannot deadlock by acquiring the pair in
  opposite orders.

  ## The two instruments here

  1. A SOURCE INVENTORY (`describe "inventory"`) that enumerates every
     `pg_advisory_xact_lock` call site under `lib/barkpark/tasks`, refuses any
     whose key argument is not a `Barkpark.Tasks.LockKey` function, and pins
     the exact per-file classification. A new call site that inlines
     `"task:\#{something}"` reds it by file and line. This is a source oracle
     and says so: it proves the KEYS are built in one place, not that the
     locks block.

  2. A TWO-CONNECTION RACE (`describe "two-connection race"`) on real,
     unboxed Postgres connections. A holder connection takes the converged key
     and signals; the test connection then drives a REAL production writer
     under `SET lock_timeout`, and the writer must abort with 55P03
     (`lock_not_available`) — which it can only do if it waited on the SAME
     key the holder is holding. The ordering is asserted, not assumed: the
     holder's `:task_lock_held` message is received BEFORE the attempt, and
     `:release` is sent only in the `after` block, so the holder provably still
     held the lock when the contender hit it. A non-vacuity arm drives the same
     writer against a DIFFERENT row and requires it NOT to abort.

  Sandbox note: `{:shared, pid}` puts every process on ONE connection, so a
  "concurrent" second writer queues rather than races and the test would pass
  with the lock deleted. That is why this runs `unboxed_run`, on its own
  workspace, torn down in an `after` block — the same posture and the same
  reasoning as `test/barkpark/cycle_fleet_test.exs`'s authority-lock tests.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Claim
  alias Barkpark.Tasks.Compactor
  alias Barkpark.Tasks.LockKey
  alias Barkpark.Tenancy

  @dataset "production"
  @lock_sql "SELECT pg_advisory_xact_lock(hashtext($1))"

  # ── The inventory ─────────────────────────────────────────────────────────
  #
  # {relative source path, the exact key expression that call site passes}.
  #
  # EVERY entry whose key is `LockKey.task(...)` is the converged per-task
  # family. The three non-`task/1` entries are the documented exceptions and
  # are listed here so that adding a fourth is a decision someone has to make
  # in this file, not a diff nobody reads.
  @expected_sites [
    {"lib/barkpark/tasks/claim.ex", "LockKey.task_doc_id(doc_id)"},
    {"lib/barkpark/tasks/claim.ex", "LockKey.resources()"},
    {"lib/barkpark/tasks/claim.ex", "LockKey.task(task_uuid)"},
    {"lib/barkpark/tasks/close.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/close.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/compactor.ex", "LockKey.task(task_uuid)"},
    {"lib/barkpark/tasks/compactor.ex", "LockKey.task(task_uuid)"},
    {"lib/barkpark/tasks/discharge.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/fence.ex", "LockKey.task(child_uuid)"},
    {"lib/barkpark/tasks/fleet.ex", "LockKey.listener(logical_id)"},
    {"lib/barkpark/tasks/landed.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/move.ex", "LockKey.task(task_uuid)"},
    {"lib/barkpark/tasks/mutations.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/mutations.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/pulse.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/release.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/renew.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/stage.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/stamp.ex", "LockKey.task(task_id)"},
    {"lib/barkpark/tasks/ttl_sweeper.ex", "LockKey.task(task_uuid)"},
    {"lib/barkpark/tasks/ttl_sweeper.ex", "LockKey.task(task_uuid)"}
  ]

  # The ONLY keys allowed to be something other than `LockKey.task/1`, each
  # with the reason it is not in the converged family.
  @documented_exceptions %{
    "LockKey.task_doc_id(doc_id)" =>
      "Claim.claim_by_id/3's PRE-RESOLUTION guard — the uuid is not known yet. " <>
        "It excludes claim-vs-claim only; the same transaction takes LockKey.task/1 " <>
        "as soon as it has the uuid.",
    "LockKey.resources()" => "The global --resources overlap guard. Not per-task by design.",
    "LockKey.listener(logical_id)" =>
      "Fleet listener beats — a different domain that happens to live under Tasks."
  }

  defp lock_sites do
    root = Path.expand("../../..", __DIR__)

    Path.wildcard(Path.join(root, "lib/barkpark/tasks/**/*.ex"))
    |> Kernel.++(Path.wildcard(Path.join(root, "lib/barkpark/tasks.ex")))
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, root)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} ->
        String.contains?(line, "pg_advisory_xact_lock") and String.contains?(line, "Repo.query!")
      end)
      |> Enum.map(fn {line, n} -> {rel, n, key_expression(path, n, line)} end)
    end)
  end

  # The key is the second argument to Repo.query!/2. It is either on the same
  # line (`, [KEY])`) or, when the line was wrapped by the formatter, on the
  # following line. Both shapes are read; anything else comes back as the raw
  # line so the failure message shows what could not be parsed.
  defp key_expression(path, n, line) do
    same_line = Regex.run(~r/,\s*\[([^\]]+)\]\)/, line)

    next_line =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.at(n)
      |> Kernel.||("")
      |> String.trim()

    cond do
      is_list(same_line) -> same_line |> List.last() |> String.trim()
      next_line != "" and not String.starts_with?(next_line, "#") -> next_line
      true -> String.trim(line)
    end
  end

  describe "inventory — every task advisory-lock call site" do
    test "the inventory is non-empty and names the files it covers" do
      sites = lock_sites()

      files = sites |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert length(sites) > 0,
             """
             ZERO advisory-lock call sites found under lib/barkpark/tasks.

             This oracle greps source. An empty result is not a pass — it means
             the grep stopped matching (the SQL string changed, the files moved),
             and every assertion below would then be vacuously true.
             """

      assert length(sites) == length(@expected_sites),
             """
             The number of task advisory-lock call sites changed.

             found #{length(sites)}, expected #{length(@expected_sites)}

             files covered:
             #{Enum.map_join(files, "\n", &("  " <> &1))}

             sites found:
             #{Enum.map_join(sites, "\n", fn {f, n, k} -> "  #{f}:#{n}  #{k}" end)}

             Adding a lock site is fine — add it to @expected_sites, and say in
             the PR which family it joins.
             """
    end

    test "every key is built by Barkpark.Tasks.LockKey — no inlined key strings" do
      inlined =
        lock_sites()
        |> Enum.reject(fn {_f, _n, key} -> String.starts_with?(key, "LockKey.") end)

      assert inlined == [],
             """
             A task advisory lock built its key INLINE instead of through
             Barkpark.Tasks.LockKey:

             #{Enum.map_join(inlined, "\n", fn {f, n, k} -> "  #{f}:#{n}  #{k}" end)}

             The whole mutex is the string. A call site that spells its own key
             can diverge from every other writer without a single test failing
             and without Postgres complaining — it just takes a different lock.
             Route it through LockKey.
             """
    end

    test "every post-resolution writer takes LockKey.task/1 — the uuid family" do
      sites = lock_sites()

      actual = sites |> Enum.map(fn {f, _n, k} -> {f, k} end) |> Enum.sort()
      expected = Enum.sort(@expected_sites)

      assert actual == expected,
             """
             The task advisory-lock inventory diverged from the pinned one.

             missing (pinned but not found):
             #{Enum.map_join(expected -- actual, "\n", fn {f, k} -> "  #{f}  #{k}" end)}

             unexpected (found but not pinned):
             #{Enum.map_join(actual -- expected, "\n", fn {f, k} -> "  #{f}  #{k}" end)}
             """

      divergent =
        sites
        |> Enum.reject(fn {_f, _n, k} ->
          String.starts_with?(k, "LockKey.task(") or
            Map.has_key?(@documented_exceptions, k)
        end)

      assert divergent == [],
             """
             A task advisory lock uses a key family that is neither the
             converged LockKey.task/1 nor one of the documented exceptions:

             #{Enum.map_join(divergent, "\n", fn {f, n, k} -> "  #{f}:#{n}  #{k}" end)}

             documented exceptions:
             #{Enum.map_join(@documented_exceptions, "\n", fn {k, why} -> "  #{k} — #{why}" end)}
             """
    end

    test "the queue-claim path takes no per-task advisory lock — flagged, not tolerated silently" do
      root = Path.expand("../../..", __DIR__)
      claim = File.read!(Path.join(root, "lib/barkpark/tasks/claim.ex"))

      # `Claim.claim/2` (the ready-QUEUE path) selects with FOR UPDATE SKIP
      # LOCKED and calls do_claim with NO per-task advisory lock at all. That is
      # out of scope for this row ("not wave-1: rev-CAS keeps it safe today"),
      # and this assertion exists so the omission is a recorded fact rather than
      # a gap the inventory silently passes over. It reds if someone adds an
      # advisory lock there — at which point the site belongs in @expected_sites
      # and this test's premise needs re-deriving.
      assert claim =~ "FOR UPDATE SKIP LOCKED",
             "the queue-claim path no longer uses FOR UPDATE SKIP LOCKED — re-derive what serializes it"

      queue_claim_region =
        claim
        |> String.split("def claim_by_id")
        |> hd()

      refute queue_claim_region =~ "pg_advisory_xact_lock",
             """
             The ready-QUEUE claim path now takes an advisory lock.

             It did not when task-eal-bl-lock-key-convergence was written; the
             row deliberately left it alone because the FOR UPDATE SKIP LOCKED
             row lock plus rev-CAS keep it safe. If a lock was added, add the
             site to @expected_sites and delete this test's premise.
             """
    end
  end

  describe "two-connection race — the converged key actually blocks" do
    @tag :slow
    test "close, claim and the compaction restore all wait on the key a holder holds" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        suffix = System.unique_integer([:positive])
        workspace = Barkpark.TenancyFixtures.create_workspace!("lockconv-#{suffix}")
        project = Barkpark.TenancyFixtures.create_project!(workspace, "lockconv-#{suffix}")

        try do
          scope = [workspace_id: workspace.id, project_id: project.id]
          {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)

          for schema_def <- Tasks.schema_definitions(@dataset) do
            attrs =
              schema_def
              |> Map.from_struct()
              |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
              |> Map.new(fn {k, v} -> {to_string(k), v} end)

            {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
          end

          held = mk_task!("lockconv-held-#{suffix}", scope)
          other = mk_task!("lockconv-other-#{suffix}", scope)

          parent = self()

          # ── Connection A: hold the converged key, and say so ──────────────
          holder =
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                Repo.transaction(fn ->
                  Repo.query!(@lock_sql, [LockKey.task(held.id)])
                  send(parent, :task_lock_held)

                  receive do
                    :release -> :ok
                  after
                    30_000 -> :timeout
                  end
                end)
              end)
            end)

          # THE ORDERING ASSERTION. A race test that does not prove the first
          # lock was HELD when the second attempted is vacuous: the second
          # could have run entirely before the first, or after it committed,
          # and "it did not block" would look identical.
          assert_receive :task_lock_held, 10_000

          # `:release` is sent ONLY in the after-block below, so between this
          # line and there the holder is provably still inside its transaction
          # holding the lock. Nothing in between can release it.
          refute_received :holder_released

          try do
            # SET, not SET LOCAL: SET LOCAL outside a transaction is a no-op,
            # and each writer below opens its OWN transaction. RESET in the
            # after-block — the GUC persists on the pooled connection.
            Repo.query!("SET lock_timeout = '750ms'")

            # ── claim-vs-close ────────────────────────────────────────────
            # THE convergence-sensitive arm. Before this change claim_by_id
            # locked ONLY `task:<doc_id>`, which hashes elsewhere, so it sailed
            # straight past a held `task:<uuid>` and returned an ordinary
            # refusal. It must now WAIT — and therefore abort at 750ms.
            claim_error =
              assert_raise Postgrex.Error, fn ->
                Claim.claim_by_id(held.doc_id, "lockconv-worker", scope)
              end

            assert claim_error.postgres.pg_code == "55P03",
                   "claim did not abort on the lock: #{inspect(claim_error.postgres)}"

            assert Process.alive?(holder.pid),
                   "the holder died before the contender was measured — the block proves nothing"

            # ── close ─────────────────────────────────────────────────────
            close_error =
              assert_raise Postgrex.Error, fn ->
                Tasks.close(held.id, "lockconv-worker", observed_epoch: 1)
              end

            assert close_error.postgres.pg_code == "55P03"

            # ── background-writer-vs-close ────────────────────────────────
            # Compactor.restore/2 is a background/maintenance writer and its
            # FIRST statement is the advisory lock, before it looks the
            # revision up — so a bogus revision id still exercises the lock.
            restore_error =
              assert_raise Postgrex.Error, fn ->
                Compactor.restore(held.id, Ecto.UUID.generate())
              end

            assert restore_error.postgres.pg_code == "55P03"

            # ── NON-VACUITY: a DIFFERENT row must NOT block ───────────────
            # Without this, a global stall (an exhausted pool, a table lock, a
            # 750ms timeout that fires on anything) would satisfy every
            # assertion above while proving nothing about the KEY.
            assert {:error, _} = Tasks.close(other.id, "lockconv-worker", observed_epoch: 1)

            assert Process.alive?(holder.pid),
                   "the holder must still be holding when the non-vacuity arm runs"
          after
            Repo.query!("SET lock_timeout = 0")
            send(holder.pid, :release)
            Task.await(holder, 30_000)
          end
        after
          {:ok, _} = Tenancy.delete_workspace(workspace)
        end
      end)
    end
  end

  defp mk_task!(doc_id, scope) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "in_progress",
      "acceptance_criteria" => [
        %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
      ],
      "claim" => %{
        "worker" => "lockconv-holder",
        "epoch" => 1,
        "ts_iso" => DateTime.to_iso8601(DateTime.utc_now())
      }
    }

    {:ok, %Document{} = doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end
end
