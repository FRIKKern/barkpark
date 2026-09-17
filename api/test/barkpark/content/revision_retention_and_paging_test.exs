defmodule Barkpark.Content.RevisionRetentionAndPagingTest do
  @moduledoc """
  loop-low-history-offset-retention — the two halves of the revision-history
  contract that had never been written down, let alone pinned.

  1. PAGINATION. `list_revisions/4` took only `:limit` (the HTTP surface capped
     it at 200), so revision 201 of a long trail was unreachable through the
     API: `restore` could still bring it back, but only if you already knew the
     UUID that this listing is the sole publisher of. `:offset` surfaces it —
     and the ordering key had to become TOTAL (`{inserted_at, id}`) first,
     because `inserted_at` ties are real and an OFFSET over a non-total order
     may hand the same row to two pages and never hand over another.

  2. RETENTION. Nothing prunes revisions. That is now the written policy, and
     these arms are what makes it a policy rather than an accident: the source
     enumeration (with a control that proves the detector can see a pruner),
     the document-delete arm, and the cascade migration that IS the one
     documented removal path.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Revision
  alias Barkpark.Repo

  @repo_query_event [:barkpark, :repo, :query]

  defp scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    [workspace_id: ws.id, project_id: proj.id]
  end

  # Write revisions DIRECTLY so the arm controls the exact `inserted_at` it is
  # testing. `Revision.changeset/2` does not cast `inserted_at`, so the struct
  # path is the only way to manufacture a tie on purpose.
  defp insert_rev!(doc_id, opts, attrs) do
    Repo.insert!(%Revision{
      doc_id: doc_id,
      type: "post",
      dataset: "production",
      title: attrs[:title],
      status: "published",
      content: attrs[:content] || %{},
      action: attrs[:action] || "update",
      workspace_id: opts[:workspace_id],
      project_id: opts[:project_id],
      inserted_at: attrs[:inserted_at] || DateTime.utc_now()
    })
  end

  defp page(doc_id, opts, limit, offset) do
    Content.list_revisions(doc_id, "post", "production", [limit: limit, offset: offset] ++ opts)
  end

  # Bounded on purpose: an offset that stops advancing would otherwise spin
  # forever instead of failing, and a hang is a much worse test than a red.
  defp page_all(doc_id, opts, limit) do
    0..50
    |> Enum.map(&(&1 * limit))
    |> Enum.reduce_while([], fn offset, acc ->
      case page(doc_id, opts, limit, offset) do
        [] -> {:halt, acc}
        rows -> {:cont, acc ++ rows}
      end
    end)
  end

  describe "offset pagination" do
    test "paging with :offset walks the WHOLE trail exactly once, no row twice, none lost" do
      opts = scope()
      base = ~U[2026-01-01 00:00:00.000000Z]

      written =
        for n <- 1..7 do
          insert_rev!("p-page", opts,
            title: "V#{n}",
            inserted_at: DateTime.add(base, n, :second)
          )
        end

      walked = page_all("p-page", opts, 3)

      assert length(walked) == 7
      assert Enum.map(walked, & &1.id) |> Enum.uniq() |> length() == 7
      assert MapSet.new(walked, & &1.id) == MapSet.new(written, & &1.id)

      # Newest first, across the page boundary — not only within a page.
      assert Enum.map(walked, & &1.title) == ~w(V7 V6 V5 V4 V3 V2 V1)
    end

    test "an offset PAST the end is an empty page, not a wrapped or last page" do
      opts = scope()
      insert_rev!("p-past", opts, title: "only")

      assert page("p-past", opts, 10, 5) == []
    end

    test "a NEGATIVE offset clamps to the first page instead of inverting the window" do
      opts = scope()
      insert_rev!("p-neg", opts, title: "only")

      assert [rev] = page("p-neg", opts, 10, -4)
      assert rev.title == "only"
    end

    # THE ARM THAT THE TOTAL ORDER EXISTS FOR — read the note on the SQL-shape
    # oracle below before trusting this one. Six revisions sharing ONE
    # microsecond, which a single mutation batch really does produce.
    #
    # MEASURED CAVEAT (not a hedge — it was run): this arm passes on the
    # PRE-FIX code too. Postgres is FREE to reorder tied rows between two
    # OFFSET queries; on a table this small it does not exercise that freedom,
    # so the duplicate never appears here. Keep it as a smoke arm for a future
    # regression that breaks paging outright — but the oracle below, not this
    # test, is what pins the tiebreak.
    test "revisions that TIE on inserted_at still page without duplicates or losses" do
      opts = scope()
      tied = ~U[2026-02-02 12:00:00.000000Z]

      written =
        for n <- 1..6 do
          insert_rev!("p-tie", opts, title: "T#{n}", inserted_at: tied)
        end

      walked = page_all("p-tie", opts, 2)
      ids = Enum.map(walked, & &1.id)

      assert length(ids) == 6, "paged #{length(ids)} of 6 tied revisions"
      assert Enum.uniq(ids) |> length() == 6, "a tied row was handed out twice"
      assert MapSet.new(ids) == MapSet.new(written, & &1.id), "a tied row was never handed out"
    end

    # THE REAL DETECTOR for the tiebreak. The hazard is a PERMISSION Postgres
    # holds, not a behaviour it always exhibits, so it cannot be observed
    # deterministically from ExUnit — what CAN be asserted is that the query we
    # send makes the permission unusable. This reds the moment `desc: r.id`
    # leaves `list_revisions/4`, which the behavioural arm above does not.
    test "the emitted ORDER BY is TOTAL — inserted_at AND id, both DESC" do
      opts = scope()
      insert_rev!("p-sql", opts, title: "one")

      sql =
        capture_sql(fn ->
          Content.list_revisions("p-sql", "post", "production", [limit: 2, offset: 0] ++ opts)
        end)
        |> Enum.find(&(&1 =~ ~r/FROM "revisions"/))

      assert sql, "no revisions SELECT was captured — the oracle measured nothing"

      assert sql =~ ~r/ORDER BY\s+\S*"inserted_at" DESC,\s*\S*"id" DESC/,
             "the revision listing's ORDER BY is not total, so OFFSET may duplicate or drop a tied row: #{sql}"

      assert sql =~ ~r/\bOFFSET\b/, "the listing emitted no OFFSET clause"
    end

    test "the same tied trail is STABLE — two identical walks agree row for row" do
      opts = scope()
      tied = ~U[2026-03-03 09:00:00.000000Z]
      for n <- 1..6, do: insert_rev!("p-stable", opts, title: "S#{n}", inserted_at: tied)

      assert Enum.map(page_all("p-stable", opts, 2), & &1.id) ==
               Enum.map(page_all("p-stable", opts, 2), & &1.id)
    end

    test "a revision reachable ONLY beyond page one is still restorable" do
      opts = scope()
      base = ~U[2026-04-04 08:00:00.000000Z]

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "p-restore", "title" => "current"},
          "production",
          opts
        )

      # The oldest of seven — off page one at limit 3, and the only copy of the
      # content we are about to restore.
      oldest =
        insert_rev!("p-restore", opts,
          title: "ancient",
          content: %{"body" => "the old words"},
          inserted_at: DateTime.add(base, -100, :second)
        )

      for n <- 1..6 do
        insert_rev!("p-restore", opts,
          title: "V#{n}",
          inserted_at: DateTime.add(base, n, :second)
        )
      end

      page_one = page("p-restore", opts, 3, 0)
      refute oldest.id in Enum.map(page_one, & &1.id), "fixture broken: oldest sits on page one"

      walked = page_all("p-restore", opts, 3)
      assert oldest.id in Enum.map(walked, & &1.id)

      {:ok, restored} = Content.restore_revision(oldest.id, "post", "production", opts)
      assert restored.content["body"] == "the old words"
    end
  end

  describe "retention" do
    test "deleting the DOCUMENT keeps its revisions listable and restorable" do
      opts = scope()

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "p-del", "title" => "alive", "content" => %{"body" => "keep me"}},
          "production",
          opts
        )

      before_delete = Content.list_revisions("p-del", "post", "production", opts)
      assert before_delete != [], "fixture broken: no revision to survive the delete"

      {:ok, _} = Content.delete_document("p-del", "post", "production", opts)

      after_delete = Content.list_revisions("p-del", "post", "production", opts)

      assert MapSet.subset?(
               MapSet.new(before_delete, & &1.id),
               MapSet.new(after_delete, & &1.id)
             ),
             "a document delete discarded revisions that existed before it"

      survivor = Enum.find(after_delete, &(&1.content["body"] == "keep me"))
      assert survivor, "the pre-delete content snapshot is gone"
      assert {:ok, _} = Content.restore_revision(survivor.id, "post", "production", opts)
    end

    test "an ancient revision is not swept — retention is indefinite" do
      opts = scope()

      old =
        insert_rev!("p-ancient", opts,
          title: "from 2019",
          inserted_at: ~U[2019-01-01 00:00:00.000000Z]
        )

      assert [found] = Content.list_revisions("p-ancient", "post", "production", opts)
      assert found.id == old.id
    end

    # THE ENUMERATION. "Nothing prunes revisions" is an absence claim, so it is
    # made by listing every delete call site in api/lib and checking each one's
    # statement for the revisions table — never by having failed to notice one.
    test "no delete site in api/lib targets the revisions table (with a control)" do
      hits =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file -> scan_for_revision_deletes(File.read!(file), file) end)

      assert hits == [],
             "a delete site now targets revisions — the INDEFINITE retention doc is stale: #{inspect(hits)}"

      # CONTROL — and it is TWO shapes on purpose. The first version of this
      # test planted only the `from(r in Revision, ...)` form, the control went
      # green, and a pruner planted into lib/ in the PIPE form sailed straight
      # past the scan: the fixture encoded a syntax the codebase does not
      # actually favour. Both shapes now, and the run that caught it is why.
      planted = [
        {"query-expression form",
         """
         defp sweep(cutoff) do
           from(r in Revision, where: r.inserted_at < ^cutoff)
           |> Repo.delete_all()
         end
         """},
        {"pipe form",
         """
         def prune_old_revisions(cutoff) do
           Revision
           |> where([r], r.inserted_at < ^cutoff)
           |> Repo.delete_all()
         end
         """},
        {"raw table form",
         """
         defp sweep(cutoff) do
           from(r in "revisions", where: r.inserted_at < ^cutoff) |> Repo.delete_all()
         end
         """}
      ]

      for {shape, source} <- planted do
        assert scan_for_revision_deletes(source, "planted.ex") != [],
               "the detector cannot see a revision pruner in #{shape} — the absence claim above is vacuous for that shape"
      end
    end

    test "the cascade migration still names all three revisions scope FKs" do
      body =
        File.read!("priv/repo/migrations/20260527160000_cascade_content_on_scope_delete.exs")

      for col <- ~w(workspace_id project_id dataset_id) do
        assert body =~ ~s({"revisions", "#{col}",),
               "revisions.#{col} left the documented cascade — the one removal path changed"
      end
    end
  end

  # Collect every SQL statement THIS process emits while `fun` runs. Ecto emits
  # its query telemetry synchronously in the calling process, so filtering on
  # `self()` keeps this safe under `async: true`.
  defp capture_sql(fun) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, metadata, ^test_pid ->
          if self() == test_pid, do: send(test_pid, {:sql, metadata[:query]})
          :ok
        end,
        test_pid
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql} -> drain_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A delete site is `Repo.delete_all` / `Repo.delete`; its statement is the
  # window of lines around it (Ecto pipes the query in from ABOVE as often as
  # it passes it inline, so the window looks both ways).
  defp scan_for_revision_deletes(source, file) do
    lines = String.split(source, "\n")
    total = length(lines)

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _i} -> line =~ ~r/Repo\.delete(_all)?[\s(]/ end)
    |> Enum.filter(fn {_line, i} ->
      lines
      |> Enum.slice(max(i - 5, 0), min(11, total))
      |> Enum.join("\n")
      |> then(&(&1 =~ ~r/\bRevision\b|"revisions"|:revisions\b/))
    end)
    |> Enum.map(fn {line, i} -> "#{file}:#{i + 1}: #{String.trim(line)}" end)
  end
end
