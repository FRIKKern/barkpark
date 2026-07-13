defmodule Barkpark.Plugins.Github.ConflictsTest do
  @moduledoc """
  Wave-4 slice-1: the `github_sync_conflicts` quarantine substrate (epic D7).

  Proves the recorder INSERTS an open row, DEDUPS a repeat for the same
  `{repo, issue, kind, COALESCE(detail->>'source', '')}` into ONE open row
  (update-in-place, never a pile) while keeping co-occurring distinct-source
  problems as DISTINCT rows (D17), LISTS open rows newest-first with repo/kind
  filters, and that `resolve/1` drops a row out of the open list. DB-only — no
  `Content.*`, no `mutation_events`, no network.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Plugins.Github.{Conflict, Conflicts}
  alias Barkpark.Repo

  @repo "FRIKKern/barkpark"
  @dataset "production"

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        repo: @repo,
        issue: 42,
        doc_id: "gh-42",
        dataset: @dataset,
        kind: "out_of_band_edit",
        detail: %{"observed_fp" => 1}
      },
      overrides
    )
  end

  describe "record/1" do
    test "inserts an open row" do
      assert {:ok, %Conflict{} = c} = Conflicts.record(base())
      assert c.repo == @repo
      assert c.issue == 42
      assert c.doc_id == "gh-42"
      assert c.kind == "out_of_band_edit"
      assert c.detail == %{"observed_fp" => 1}
      assert is_nil(c.resolved_at)

      assert Repo.aggregate(Conflict, :count, :id) == 1
    end

    test "a second record for the same {repo,issue,kind} UPDATES, still ONE open row" do
      assert {:ok, first} = Conflicts.record(base(%{detail: %{"n" => 1}}))
      assert {:ok, second} = Conflicts.record(base(%{detail: %{"n" => 5}}))

      # same row, refreshed detail — not a second pile
      assert first.id == second.id
      assert second.detail == %{"n" => 5}
      assert Repo.aggregate(Conflict, :count, :id) == 1
      assert length(Conflicts.list()) == 1
    end

    test "a different kind for the same issue is a DISTINCT conflict" do
      assert {:ok, _} = Conflicts.record(base(%{kind: "out_of_band_edit"}))
      assert {:ok, _} = Conflicts.record(base(%{kind: "detached"}))
      assert Repo.aggregate(Conflict, :count, :id) == 2
    end

    test "a dedup_refused intake has no doc_id (nullable)" do
      attrs = base(%{kind: "dedup_refused", doc_id: nil, detail: %{"verdict" => "look-alike"}})
      assert {:ok, %Conflict{doc_id: nil, kind: "dedup_refused"}} = Conflicts.record(attrs)
    end

    test "accepts string-keyed attrs" do
      attrs = %{
        "repo" => @repo,
        "issue" => 7,
        "doc_id" => nil,
        "dataset" => @dataset,
        "kind" => "detached",
        "detail" => %{"reason" => "transferred"}
      }

      assert {:ok, %Conflict{issue: 7, kind: "detached"}} = Conflicts.record(attrs)
    end

    test "rejects an unknown kind" do
      assert {:error, %Ecto.Changeset{} = cs} = Conflicts.record(base(%{kind: "bogus"}))
      assert %{kind: _} = errors_on(cs)
      assert Repo.aggregate(Conflict, :count, :id) == 0
    end

    test "rejects missing required fields" do
      assert {:error, %Ecto.Changeset{} = cs} = Conflicts.record(%{issue: 1, kind: "detached"})
      errors = errors_on(cs)
      assert errors[:repo]
      assert errors[:dataset]
    end

    test "detail defaults to an empty map, never null" do
      assert {:ok, %Conflict{detail: %{}}} =
               Conflicts.record(base(%{detail: nil}))
    end

    test "a no-source human-drift record and a graphql record are DISTINCT rows (source discriminates)" do
      # First record: an out_of_band_edit carrying the observed drift fingerprint
      # + the ledger-owned GitHub fields that diverged (the MirrorJob update path).
      # Human drift carries NO detail.source.
      assert {:ok, drift} =
               Conflicts.record(
                 base(%{
                   detail: %{"observed_fp" => 7, "github_fields" => %{"title" => "hand-edited"}}
                 })
               )

      # A LATER touch on the SAME {repo,issue,kind} from a DIFFERENT source — a
      # Projects-v2 GraphQL projection error folded into the frozen
      # out_of_band_edit kind. It is a SEPARATE operator problem, NOT the same
      # conflict: it must NOT collapse onto the human-drift row (D17). Otherwise
      # one Resolve silently clears both and the operator misses one.
      assert {:ok, gql} =
               Conflicts.record(
                 base(%{detail: %{"source" => "graphql", "graphql_error" => "RATE_LIMITED"}})
               )

      # Two distinct open rows, each keeping ONLY its own detail.
      refute drift.id == gql.id
      assert Repo.aggregate(Conflict, :count, :id) == 2
      assert length(Conflicts.list()) == 2

      drift_row = Repo.get(Conflict, drift.id)
      assert drift_row.detail["observed_fp"] == 7
      assert drift_row.detail["github_fields"] == %{"title" => "hand-edited"}
      refute Map.has_key?(drift_row.detail, "source")

      assert gql.detail["source"] == "graphql"
      assert gql.detail["graphql_error"] == "RATE_LIMITED"
    end

    test "co-occurring distinct-source problems on ONE issue are DISTINCT open rows (fail-before D17)" do
      # Two of the four problems that reuse the frozen out_of_band_edit kind,
      # discriminated only by detail.source. Before the source-widened dedup key
      # they collapsed to ONE {repo,issue,kind} row — and a single Resolve cleared
      # BOTH, so the sub-issue never got linked and nobody knew. This FAILS on
      # main (count == 1) and passes after the fix (count == 2).
      assert {:ok, gql} =
               Conflicts.record(
                 base(%{detail: %{"source" => "graphql", "graphql_error" => "RATE_LIMITED"}})
               )

      assert {:ok, sub} =
               Conflicts.record(
                 base(%{detail: %{"source" => "sub_issue_rejected", "parent" => 12}})
               )

      refute gql.id == sub.id
      assert Repo.aggregate(Conflict, :count, :id) == 2
      assert length(Conflicts.list()) == 2
    end

    test "five no-source human-drift records still dedup to ONE open row (COALESCE empty-string guard)" do
      # Human drift carries NO detail.source. COALESCE(detail->>'source','') maps
      # all five to the SAME discriminator '' — a bare detail->>'source' would let
      # Postgres treat each NULL as DISTINCT and pile five rows, so the
      # empty-string coalesce is load-bearing for the five-edits-is-one-row rule.
      for n <- 1..5 do
        assert {:ok, _} = Conflicts.record(base(%{detail: %{"edit" => n}}))
      end

      assert Repo.aggregate(Conflict, :count, :id) == 1
      assert length(Conflicts.list()) == 1
    end

    test "a nil incoming detail never nulls the accumulated detail" do
      assert {:ok, first} = Conflicts.record(base(%{detail: %{"observed_fp" => 3}}))
      assert {:ok, second} = Conflicts.record(base(%{detail: nil}))

      assert first.id == second.id
      # the prior detail is preserved, not overwritten with an empty map
      assert second.detail == %{"observed_fp" => 3}
    end

    test "a numeric-string issue dedups against an integer issue (same key)" do
      assert {:ok, first} = Conflicts.record(base(%{issue: 42}))
      # a JSON/form caller handing issue as "42" must land on the SAME open row,
      # not a second un-deduped pile.
      assert {:ok, second} = Conflicts.record(base(%{issue: "42", detail: %{"n" => 9}}))

      assert first.id == second.id
      assert second.issue == 42
      assert Repo.aggregate(Conflict, :count, :id) == 1
    end
  end

  describe "open-key partial unique index (structural pile guard)" do
    test "the DB rejects a second OPEN row for the same {repo,issue,kind}" do
      assert {:ok, _} = Conflicts.record(base())

      # A direct insert that bypasses the recorder's FOR-UPDATE dedup (i.e. the
      # lost-race path) must be refused by the partial unique index, proving the
      # invariant is enforced at the DB, not just in app code.
      dup =
        %Conflict{}
        |> Conflict.changeset(base())
        |> Repo.insert()

      assert {:error, cs} = dup
      assert Enum.any?(cs.errors, fn {_f, {_m, opts}} -> opts[:constraint] == :unique end)
      assert Repo.aggregate(Conflict, :count, :id) == 1
    end

    test "a resolved row does NOT block a fresh open row for the same key" do
      {:ok, c1} = Conflicts.record(base())
      {:ok, _} = Conflicts.resolve(c1.id)

      # partial index only covers resolved_at IS NULL, so re-opening is allowed
      assert {:ok, c2} = Conflicts.record(base())
      refute c1.id == c2.id
    end
  end

  describe "list/1" do
    test "returns open rows newest-first" do
      {:ok, a} = Conflicts.record(base(%{issue: 1}))
      {:ok, b} = Conflicts.record(base(%{issue: 2}))
      {:ok, c} = Conflicts.record(base(%{issue: 3}))

      ids = Conflicts.list() |> Enum.map(& &1.id)
      assert ids == [c.id, b.id, a.id]
    end

    test "filters by kind" do
      {:ok, _} = Conflicts.record(base(%{issue: 1, kind: "out_of_band_edit"}))
      {:ok, det} = Conflicts.record(base(%{issue: 2, kind: "detached"}))

      rows = Conflicts.list(kind: "detached")
      assert Enum.map(rows, & &1.id) == [det.id]
    end

    test "filters by repo" do
      {:ok, _} = Conflicts.record(base(%{issue: 1, repo: "FRIKKern/barkpark"}))
      {:ok, other} = Conflicts.record(base(%{issue: 2, repo: "other/repo"}))

      rows = Conflicts.list(repo: "other/repo")
      assert Enum.map(rows, & &1.id) == [other.id]
    end

    test "excludes resolved rows" do
      {:ok, open} = Conflicts.record(base(%{issue: 1}))
      {:ok, done} = Conflicts.record(base(%{issue: 2}))
      {:ok, _} = Conflicts.resolve(done.id)

      assert Enum.map(Conflicts.list(), & &1.id) == [open.id]
    end
  end

  describe "resolve/1" do
    test "sets resolved_at and drops the row from list/1" do
      {:ok, c} = Conflicts.record(base())
      assert Conflicts.list() != []

      assert {:ok, resolved} = Conflicts.resolve(c.id)
      assert %DateTime{} = resolved.resolved_at
      assert Conflicts.list() == []
    end

    test "a resolved key can re-open as a fresh record" do
      {:ok, c1} = Conflicts.record(base())
      {:ok, _} = Conflicts.resolve(c1.id)

      {:ok, c2} = Conflicts.record(base(%{detail: %{"n" => 2}}))
      # a new open row, distinct from the resolved one
      refute c1.id == c2.id
      assert Enum.map(Conflicts.list(), & &1.id) == [c2.id]
      assert Repo.aggregate(Conflict, :count, :id) == 2
    end

    test "missing id returns {:error, :not_found}" do
      assert {:error, :not_found} = Conflicts.resolve(999_999)
    end

    test "re-resolving keeps the original resolved_at (idempotent)" do
      {:ok, c} = Conflicts.record(base())
      {:ok, first} = Conflicts.resolve(c.id)
      {:ok, second} = Conflicts.resolve(c.id)
      assert first.resolved_at == second.resolved_at
    end
  end

  test "recording NEVER emits a mutation_events row (no loop surface)" do
    before = Repo.one(from m in "mutation_events", select: count(m.id))
    {:ok, _} = Conflicts.record(base())
    after_count = Repo.one(from m in "mutation_events", select: count(m.id))
    assert before == after_count
  end
end
