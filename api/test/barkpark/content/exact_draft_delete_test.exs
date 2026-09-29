defmodule Barkpark.Content.ExactDraftDeleteTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.{Document, Revision, MutationEvent}
  import Ecto.Query

  @dataset "exact_delete_test"
  @type_name "exact_note"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "Note", "visibility" => "public", "fields" => []},
        @dataset
      )

    :ok
  end

  defp draft(id, title \\ "Original") do
    {:ok, doc} = Content.create_document(@type_name, %{"_id" => id, "title" => title}, @dataset)
    Repo.get!(Document, doc.id)
  end

  defp exact(doc, rev \\ nil, opts \\ []),
    do: Content.delete_exact_draft(doc.doc_id, @type_name, @dataset, rev || doc.rev, opts)

  defp fetched(id), do: Content.get_document(id, @type_name, @dataset)

  test "only the named draft is removed and its snapshot and event are retained" do
    draft("twins")
    {:ok, _} = Content.publish_document("twins", @type_name, @dataset)
    {:ok, published} = fetched("twins")
    d = draft("twins", "Draft body")
    assert {:ok, deleted} = exact(d)
    assert deleted.id == d.id
    assert {:error, :not_found} = fetched(d.doc_id)
    assert {:ok, ^published} = fetched("twins")

    assert Repo.exists?(
             from r in Revision,
               where: r.doc_id == "twins" and r.rev == ^d.rev and r.action == "delete"
           )

    assert Repo.exists?(
             from e in MutationEvent, where: e.doc_id == ^d.doc_id and e.mutation == "delete"
           )
  end

  test "a missing draft never falls back to its published sibling" do
    draft("published-only")
    {:ok, _} = Content.publish_document("published-only", @type_name, @dataset)
    {:ok, p} = fetched("published-only")

    assert {:error, :not_found} =
             Content.delete_exact_draft("drafts.published-only", @type_name, @dataset, p.rev)

    assert {:ok, ^p} = fetched(p.doc_id)
  end

  test "malformed identity or missing caller revision cannot authorize a delete" do
    d = draft("invalid")

    for {id, rev} <- [
          {"invalid", d.rev},
          {"drafts.", d.rev},
          {d.doc_id, nil},
          {d.doc_id, ""},
          {d.doc_id, 1}
        ] do
      assert {:error, :malformed} = Content.delete_exact_draft(id, @type_name, @dataset, rev)
    end

    assert {:ok, ^d} = fetched(d.doc_id)
  end

  test "stale caller revision and foreign scope preserve the exact row" do
    d = draft("stale")

    {:ok, newer} =
      Content.upsert_document(
        @type_name,
        %{"doc_id" => d.doc_id, "title" => "Human title"},
        @dataset
      )

    newer = Repo.get!(Document, newer.id)
    assert {:error, {:rev_mismatch, %{expected: expected, actual: actual}}} = exact(d)
    assert expected == d.rev and actual == newer.rev
    assert {:error, :not_found} = exact(newer, nil, workspace_id: Ecto.UUID.generate())
    assert {:ok, ^newer} = fetched(d.doc_id)
  end

  defmodule InterleaveHook do
    def lifecycle_hooks, do: %{before_delete: [&__MODULE__.edit/1]}

    def edit(%{doc: doc}) do
      case Process.get(:exact_delete_writer) do
        nil ->
          :ok

        writer ->
          send(writer, {:write_now, self(), doc})

          receive do
            {:human_committed, rev} ->
              Process.put(:exact_delete_human_rev, rev)
              :ok
          after
            10_000 -> raise "Human writer did not commit"
          end
      end
    end
  end

  test "a separately committed human edit between read and delete survives", ctx do
    :ok = Barkpark.PluginEnv.with_plugins([InterleaveHook], ctx)
    id = "interleaved-#{System.unique_integer([:positive])}"
    # Registered BEFORE the unboxed writes so a crash or timeout mid-test still
    # removes them. See purge_committed!/2.
    before = unboxed(&committed_counts/0)
    marks = unboxed(&committed_marks/0)
    on_exit(fn -> purge_committed!(id, marks, before) end)

    # Independent database connections: a rollback cannot make this pass by
    # rolling back the simulated human write along with the failed deletion.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      {:ok, d} =
        Content.create_document("note", %{"_id" => id, "title" => "Original"}, "production")

      writer =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            receive do
              {:write_now, caller, doc} ->
                rev = "human-#{System.unique_integer([:positive])}"

                {1, _} =
                  Repo.update_all(from(row in Document, where: row.id == ^doc.id),
                    set: [title: "Human won", rev: rev]
                  )

                send(caller, {:human_committed, rev})
            after
              10_000 -> raise "Delete did not reach its read boundary"
            end
          end)
        end)

      Process.put(:exact_delete_writer, writer.pid)

      try do
        assert {:error, {:rev_mismatch, _}} =
                 Content.delete_exact_draft(d.doc_id, "note", "production", d.rev)

        Task.await(writer, 15_000)
        current = Repo.get!(Document, d.id)
        assert current.title == "Human won"
        assert current.rev == Process.get(:exact_delete_human_rev)
        refute Repo.exists?(from r in Revision, where: r.doc_id == ^id and r.action == "delete")
      after
        Process.delete(:exact_delete_writer)
        Process.delete(:exact_delete_human_rev)
        Task.shutdown(writer, :brutal_kill)
      end
    end)
  end

  # ── unboxed teardown: every row the interleaved test COMMITTED ──────────────
  #
  # `unboxed_run/2` commits, so nothing rolls this test's writes back. Measured
  # on a fresh partition (2026-09-25): one run left 1 `documents` row
  # (drafts.interleaved-<n>, "Human won", dataset production), 1 `revisions`,
  # 1 `mutation_events`, 1 `audit_events` and 1 scheduled ProjectorWorker
  # `oban_jobs` row. Every later test in the same database then saw one extra
  # production note: studio_live_plus_press_retry_test counts notes == 1.
  #
  # The delete is exact: the documents, revisions and events are keyed by this
  # test's unique id; the id-sequenced tables are also bounded below by the
  # watermark read before the test, and the Oban row by worker + scope + type.
  # `revisions` and `audit_events` are append-only by trigger, so the purge runs
  # with `session_replication_role = replica` (same instrument as
  # cycle_fleet_test) inside one transaction, children before the document.
  # It then asserts the committed counts are back to the pre-test values.
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  @committed_tables ~w(documents revisions mutation_events audit_events oban_jobs)

  defp committed_counts do
    Map.new(@committed_tables, fn t ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{t}")
      {t, n}
    end)
  end

  defp committed_marks do
    Map.new(~w(mutation_events audit_events oban_jobs), fn t ->
      %{rows: [[n]]} = Repo.query!("SELECT coalesce(max(id), 0) FROM #{t}")
      {t, n}
    end)
  end

  defp purge_committed!(id, marks, before) do
    doc_ids = [id, "drafts." <> id]

    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!(
          "DELETE FROM revisions WHERE doc_id = ANY($1) AND type = 'note' AND dataset = 'production'",
          [doc_ids]
        )

        Repo.query!(
          "DELETE FROM mutation_events WHERE id > $1 AND doc_id = ANY($2) AND dataset = 'production'",
          [marks["mutation_events"], doc_ids]
        )

        Repo.query!("DELETE FROM audit_events WHERE id > $1 AND subject = ANY($2)", [
          marks["audit_events"],
          doc_ids
        ])

        Repo.query!(
          """
          DELETE FROM oban_jobs WHERE id > $1
            AND worker = 'Barkpark.EdgeProjector.ProjectorWorker'
            AND args ->> 'scope' = 'production' AND args -> 'types' ? 'note'
          """,
          [marks["oban_jobs"]]
        )

        Repo.query!(
          "DELETE FROM documents WHERE doc_id = ANY($1) AND type = 'note' AND dataset = 'production'",
          [doc_ids]
        )
      end)

      now = committed_counts()
      leaked = for {t, n} <- now, n != before[t], into: %{}, do: {t, n - before[t]}
      assert leaked == %{}, "the interleaved test left committed rows: #{inspect(leaked)}"
    end)
  end

  for table <- ["revisions", "mutation_events"] do
    test "#{table} insertion failure rolls the delete and evidence back" do
      d = draft("fault-#{unquote(table)}")
      before = Repo.aggregate(Revision, :count)

      Repo.query!("""
      CREATE FUNCTION exact_delete_fault() RETURNS trigger AS $fn$
      BEGIN RETURN NULL; END;
      $fn$ LANGUAGE plpgsql
      """)

      Repo.query!(
        "CREATE TRIGGER exact_delete_fault BEFORE INSERT ON #{unquote(table)} FOR EACH ROW EXECUTE FUNCTION exact_delete_fault()"
      )

      assert_raise Ecto.StaleEntryError, fn -> exact(d) end
      assert {:ok, ^d} = fetched(d.doc_id)
      assert Repo.aggregate(Revision, :count) == before
    end
  end

  test "an outer mutation failure rolls exact deletion back" do
    d = draft("batch")

    assert {:error, _} =
             Content.apply_mutations(
               [
                 %{
                   "deleteExactDraft" => %{
                     "id" => d.doc_id,
                     "type" => @type_name,
                     "ifRevisionID" => d.rev
                   }
                 },
                 %{"unknown" => %{}}
               ],
               @dataset
             )

    assert {:ok, ^d} = fetched(d.doc_id)
  end
end
