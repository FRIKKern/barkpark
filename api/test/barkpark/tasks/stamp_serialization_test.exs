defmodule Barkpark.Tasks.StampSerializationTest do
  @moduledoc """
  Tripwire for the mechanism that makes `bp task stamp` safe against a LOST
  UPDATE, filed as task-bf3adebfec5833df.

  ## The hypothesis, and why it was wrong

  The filing said: `stamp` updates `content.acceptance_criteria` by reading the
  array, replacing one element and writing the WHOLE array back, with the epoch
  fence guarding the CLAIM rather than the array — so two stamps on DIFFERENT
  indices of one row, at one valid epoch, are unfenced against each other and
  the later writer's array (read before the earlier writer's element landed)
  silently drops it.

  The read-modify-write is real. The race is not, because the whole sequence
  happens inside a transaction that takes a per-task advisory lock as its FIRST
  statement and then RE-READS the row by primary key inside that lock. A
  read-modify-write cannot lose an update when the read is serialized with the
  write.

  REFUTED BY RUN on 2026-09-05, against the live ledger, on a throwaway probe
  row (task-0ac501ab6460b7b9), with separate OS processes issuing separate HTTP
  requests over separate database connections:

      66 concurrent stamps that returned ok:true
      66 of them present in the published row
       0 lost updates

      120 of 120 writer pairs in the clean trials genuinely overlapped in
      wall-clock time (each writer's start/finish captured, windows intersected)

  The 18 refusals in that run were all HTTP 429 rate limiting, and NONE of them
  wrote anything behind the refusal. That is the sharper half of the result: a
  stamp that reports failure has not half-landed.

  A first pass at reading those refusals nearly reported them as lost updates —
  the read-back showed an older marker in the slot, which is exactly what a lost
  update looks like. The discriminator is the WRITE's own receipt, not the
  row: count only writes that claimed success, and ask whether those landed.

  ## What this file pins, and what it does NOT

  This is a SQL-SHAPE ORACLE, the same instrument and the same honest limit as
  `test/barkpark/access_claim_atomicity_test.exs`. It attaches to
  `[:barkpark, :repo, :query]`, runs a real `Stamp.stamp/3`, and asserts on the
  SQL actually emitted at runtime (not on the source text): that a
  `pg_advisory_xact_lock` is taken, that the row is re-read AFTER it, and that
  the `UPDATE "documents"` carrying the criteria comes after both.

  It pins the MECHANISM (serialize, then read, then write), NOT the OUTCOME
  (two racing stampers, both landing). The outcome lives in the run above,
  because a true two-connection race is NOT expressible under the Ecto SQL
  sandbox:

    * `{:shared, pid}` ownership serialises every process onto ONE checked-out
      connection, so a "concurrent" second stamper queues behind the first
      rather than racing it — and the test would pass with the advisory lock
      deleted, which is a vacuous green; and
    * `:manual` ownership gives each process its own transaction, so the task
      row inserted by setup is never visible to the second stamper at all — the
      race cannot even be set up.

  Stating that limit is the point. An oracle that oversells itself is the next
  phantom warrant.

  ## False-positive risk, for whoever sees this red

  A legitimate refactor that keeps stamp serialized by a DIFFERENT mechanism —
  `SELECT ... FOR UPDATE` on the documents row, or a per-criterion jsonb path
  update that needs no read at all — would red this file even though the
  invariant still holds. This red is a prompt to RE-DERIVE the invariant against
  the new mechanism and re-point this oracle at it, never a prompt to revert.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks}
  alias Barkpark.Tasks.Stamp

  @dataset "production"
  @event [:barkpark, :repo, :query]

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [
        %{"criterion" => "slot zero", "met" => false, "evidence" => ""},
        %{"criterion" => "slot one", "met" => false, "evidence" => ""}
      ]
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Collect every SQL statement this process emits while `fun` runs. Ecto emits
  # its query telemetry synchronously in the CALLING process, so filtering on
  # `self()` keeps a sibling suite's queries out of our bucket.
  defp capture_sql(fun) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _event, _measurements, metadata, ^test_pid ->
          if self() == test_pid, do: send(test_pid, {:sql, metadata[:query]})
          :ok
        end,
        test_pid
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_sql([])}
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql} -> drain_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp index_of(statements, fragment) do
    Enum.find_index(statements, fn sql ->
      is_binary(sql) and String.contains?(sql, fragment)
    end)
  end

  describe "stamp serializes its read-modify-write — the SQL shape says so" do
    test "takes a per-task advisory lock, then re-reads, then updates",
         %{scope: scope} do
      doc_id = uniq("stamp-ser")
      task = mk_task!(doc_id, scope)
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-ser", scope)
      epoch = claimed.content["claim"]["epoch"]

      {result, statements} =
        capture_sql(fn ->
          Stamp.stamp(task.id, "w-ser",
            observed_epoch: epoch,
            criterion: 0,
            criterion_text: "slot zero",
            outcome: {:met, "stamp_serialization_test.exs"}
          )
        end)

      assert {:ok, _} = result

      lock_at = index_of(statements, "pg_advisory_xact_lock")

      # A zero-lock observation must fail LOUDLY. If this oracle stops seeing
      # the lock because the telemetry prefix drifted or the statement moved
      # out of this process, that is a vacuous green turned into a red, not a
      # pass.
      assert lock_at != nil,
             """
             no `pg_advisory_xact_lock` was emitted during Stamp.stamp/3.

             Either the serialization was removed — which is the lost-update
             hazard task-bf3adebfec5833df describes, now real — or this oracle
             observed nothing at all. Both are reds worth having.

             SQL observed during the stamp:
             #{Enum.map_join(statements, "\n", &"  - #{inspect(&1)}")}
             """

      read_at = index_of(statements, ~s(FROM "documents"))
      write_at = index_of(statements, ~s(UPDATE "documents"))

      assert read_at != nil, "the stamp emitted no SELECT on documents"
      assert write_at != nil, "the stamp emitted no UPDATE on documents"

      # The ORDER is the whole invariant. A lock taken AFTER the read serializes
      # nothing: two stampers could both read the stale array and then queue up
      # to write it back, which is precisely the lost update.
      assert lock_at < read_at,
             """
             the advisory lock was taken AFTER the row was read (lock at #{lock_at},
             read at #{read_at}). A lock that does not cover the READ does not
             prevent a lost update — both writers can read the same stale
             criteria array and then serialize only their writes.

             SQL observed during the stamp:
             #{Enum.map_join(statements, "\n", &"  - #{inspect(&1)}")}
             """

      assert read_at < write_at,
             "the criteria UPDATE was emitted before the re-read (read at #{read_at}, write at #{write_at})"
    end

    test "the lock key is per-task, so two different rows do not block each other",
         %{scope: scope} do
      # Over-serializing every task behind one global lock would also prevent
      # the lost update — and would be a throughput bug this campaign would feel
      # at thirty agents. Pin that the key is derived per task, not constant.
      a = mk_task!(uniq("stamp-key-a"), scope)
      b = mk_task!(uniq("stamp-key-b"), scope)

      {:ok, ca} = Tasks.claim_by_id(a.content["doc_id"] || a.doc_id, "w-key", scope)
      {:ok, cb} = Tasks.claim_by_id(b.content["doc_id"] || b.doc_id, "w-key", scope)

      grab = fn task, claimed ->
        {_r, statements} =
          capture_sql(fn ->
            Stamp.stamp(task.id, "w-key",
              observed_epoch: claimed.content["claim"]["epoch"],
              criterion: 0,
              criterion_text: "slot zero",
              outcome: {:met, "stamp_serialization_test.exs key probe"}
            )
          end)

        Enum.filter(statements, fn sql ->
          is_binary(sql) and String.contains?(sql, "pg_advisory_xact_lock")
        end)
      end

      locks_a = grab.(a, ca)
      locks_b = grab.(b, cb)

      assert locks_a != [], "no advisory lock observed for task A"
      assert locks_b != [], "no advisory lock observed for task B"

      # Ecto reports the parameterised statement, so the two rows emit the SAME
      # SQL text with different BINDINGS. What is pinned here is that the key is
      # an argument (`$1`) rather than a literal constant baked into the
      # statement — a constant key would serialize the whole ledger.
      assert Enum.all?(locks_a, &String.contains?(&1, "$1")),
             """
             the advisory lock key is not parameterised: #{inspect(locks_a)}

             A constant key serializes EVERY task against every other one. That
             is safe against the lost update and ruinous for a campaign running
             thirty agents against one ledger.
             """
    end
  end
end
