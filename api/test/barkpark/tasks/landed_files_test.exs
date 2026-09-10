defmodule Barkpark.Tasks.LandedFilesTest do
  @moduledoc """
  task-726717ba693eb424 — THE PATHS A LANDING CHANGED, and the flip that has to
  overlap the row it seals.

  ## What was measured (2026-09-10, gates-w3r4, on PR #17345 b2e2b80ce)

  `Tasks.Internal`'s `@landed_keys` has listed `files` since the close family
  started sharing one merge rule, so a `files` key POSTed to
  `/v1/tasks/:id/landed` was ACCEPTED by the schema and then never written:
  `Landed.record/2` built its whole write from `digest(commit, pr, note)`. The
  caller got a 2xx. The paths reached the ledger only inside the `notes`
  SENTENCE — prose, which no reader can query — and the one shape a writer must
  never be handed is a success that says the data landed when it did not.

  And the `--criterion` flip asked only whether the criterion was merge-SHAPED
  and merge-DISCHARGED. Neither question is "which merge". A PR touching only
  `cloud/` could seal a row whose every named path is under
  `api/lib/barkpark/tasks/`, with a landing sentence in which every word is
  TRUE — which is exactly why nothing downstream catches it.

  ## The two arms, and where each guard lives

    1. `put_files/2` in `Barkpark.Tasks.Landed` — up to `@files_verbatim_limit`
       (40) paths stored verbatim under `landed.files` and read back verbatim;
       past it, `landed.file_digests` carries the COUNT and the SORTED
       top-level dirs, under a DIFFERENT key so a reader tells a verbatim list
       from a summary by which key is present, never by inspecting elements.
       `check_files/1` refuses anything that is not a list of strings, at both
       doors, naming the field.
    2. `files_overlap/3` — the flip is refused when nothing the landing changed
       shares a top-level area with any path the row's title, description or
       criteria name. Coarse on purpose: a false refusal is a loud wall in
       front of a legitimate merge, a false permit is a silent fabricated done.

  ## Mutation proof

    * Neuter `put_files/2` to `defp put_files(map, _files), do: map` — the
      "stores the list" and "past 40" tests red by name; every overlap test
      stays green (it reads the caller's list, not the stored one).
    * Neuter `files_overlap/3` to `def files_overlap(_doc, _files, _pr), do: :ok`
      — "refuses a flip whose files overlap nothing the row names" reds, and
      BOTH positive controls (overlapping files, and no files at all) stay
      green. That is the pair that says the guard discriminates rather than
      simply refusing.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Landed

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
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

  # The fixture row NAMES a fence, the way a real row does: a path token in the
  # title and another in the description. Both are under `api/`, so `api/…` is
  # the row's area and `cloud/…` is not.
  defp task!(scope, content_extra \\ %{}, title \\ nil) do
    doc_id = uniq("landed-files")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => title || "landed drops files — api/lib/barkpark/tasks/landed.ex",
          "content" =>
            Map.merge(
              %{
                "kind" => "task",
                "description" =>
                  "the write path is api/lib/barkpark/tasks/landed.ex and its test is " <>
                    "api/test/barkpark/tasks/landed_test.exs",
                "acceptance_criteria" => [
                  %{
                    "criterion" => "MERGE-GATED: the PR merged to main",
                    "merge_gate" => true,
                    "met" => false,
                    "evidence" => ""
                  }
                ],
                "lifecycle_status" => "open"
              },
              content_extra
            )
        },
        @dataset,
        scope
      )

    doc
  end

  defp reload(doc), do: Repo.get!(Document, doc.id)
  defp landed(doc), do: reload(doc).content["landed"]
  defp criteria(doc), do: reload(doc).content["acceptance_criteria"]

  # ── ARM (a): the files a landing changed are STORED and read back ─────────

  describe "content.landed.files — stored, not dropped" do
    test "a posted files list is stored verbatim and reads back verbatim", %{scope: scope} do
      doc = task!(scope)

      files = ["api/lib/barkpark/tasks/landed.ex", "api/test/barkpark/tasks/landed_test.exs"]

      assert {:ok, _} =
               Tasks.record_landing(doc.id, pr: "17454", commit: "b2e2b80", files: files)

      # THE WHOLE DEFECT IN ONE ASSERTION: before the fix this key was absent
      # and the call still returned {:ok, _}.
      assert landed(doc)["files"] == files
    end

    test "a second landing ACCUMULATES files rather than clobbering, and dedupes",
         %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} = Tasks.record_landing(doc.id, pr: "1", files: ["api/a.ex", "api/b.ex"])
      assert {:ok, _} = Tasks.record_landing(doc.id, pr: "2", files: ["api/b.ex", "api/c.ex"])

      assert landed(doc)["files"] == ["api/a.ex", "api/b.ex", "api/c.ex"]
    end

    test "past 40 entries the digest is the COUNT plus the SORTED top-level dirs",
         %{scope: scope} do
      doc = task!(scope)

      files =
        Enum.map(1..30, &"api/lib/f#{&1}.ex") ++
          Enum.map(1..30, &"docs/d#{&1}.md") ++ ["README.md"]

      assert length(files) == 61

      assert {:ok, _} = Tasks.record_landing(doc.id, pr: "17454", files: files)

      stored = landed(doc)

      # The verbatim key is ABSENT — the two shapes are told apart by which key
      # is present, never by inspecting a list's elements.
      refute Map.has_key?(stored, "files")

      assert stored["file_digests"] == [
               %{"count" => 61, "dirs" => [".", "api", "docs"]}
             ]
    end

    test "exactly 40 is still verbatim — the boundary is inclusive", %{scope: scope} do
      doc = task!(scope)
      files = Enum.map(1..40, &"api/lib/f#{&1}.ex")

      assert {:ok, _} = Tasks.record_landing(doc.id, pr: "1", files: files)
      assert landed(doc)["files"] == files
      refute Map.has_key?(landed(doc), "file_digests")
    end

    test "a files value that is not a list of strings is REFUSED, never dropped",
         %{scope: scope} do
      doc = task!(scope)

      for bad <- [["api/a.ex", 5], "api/a.ex", %{"path" => "api/a.ex"}, 7] do
        assert {:error, :invalid_files} =
                 Tasks.record_landing(doc.id, pr: "1", note: "merged", files: bad),
               "expected #{inspect(bad)} to be refused"
      end

      # NOTHING WAS WRITTEN — the refusal precedes the transaction, so the
      # landing sentence did not sneak in without its paths.
      assert is_nil(landed(doc))
    end

    test "check_files/1 names the FIELD in the sentence the HTTP door renders" do
      assert {:error, message} = Landed.check_files("api/a.ex")
      assert message =~ "files"
      assert message =~ "LIST OF STRINGS"

      assert {:ok, nil} = Landed.check_files(nil)
      assert {:ok, nil} = Landed.check_files([])
      assert {:ok, nil} = Landed.check_files(["  "])
      assert {:ok, ["api/a.ex"]} = Landed.check_files([" api/a.ex ", "api/a.ex", ""])
    end
  end

  # ── ARM (b): a flip must overlap the row it seals ────────────────────────

  describe "the --criterion flip and the paths the row names" do
    test "REFUSES a flip whose files overlap nothing the row names, naming row, PR and paths",
         %{scope: scope} do
      doc = task!(scope)
      before = criteria(doc)

      assert {:error, {:landing_files_outside_row, message}} =
               Tasks.record_landing(doc.id,
                 pr: "17345",
                 commit: "b2e2b80",
                 note: "merged to main",
                 criterion: 0,
                 files: ["cloud/lib/barkpark_cloud/oauth.ex", "js/sdk/src/index.ts"]
               )

      # NAMES THE ROW …
      assert message =~ doc.doc_id
      assert message =~ "landed drops files"
      # … THE PR …
      assert message =~ "17345"
      # … AND BOTH SIDES OF THE COMPARISON.
      assert message =~ "cloud/lib/barkpark_cloud/oauth.ex"
      assert message =~ "js/sdk/src/index.ts"
      assert message =~ "api/lib/barkpark/tasks/landed.ex"

      # NOTHING WAS WRITTEN — the flip and the landing sentence ride one CAS.
      assert criteria(doc) == before
      assert is_nil(landed(doc))
    end

    test "POSITIVE CONTROL — overlapping files still flip a merge_gate:true criterion",
         %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 pr: "17345",
                 commit: "b2e2b80",
                 note: "merged to main as b2e2b80",
                 criterion: 0,
                 files: ["api/lib/barkpark/tasks/landed.ex"]
               )

      assert [%{"met" => true, "evidence" => "merged to main as b2e2b80"}] = criteria(doc)
      assert landed(doc)["files"] == ["api/lib/barkpark/tasks/landed.ex"]
    end

    test "POSITIVE CONTROL — a top-level AREA match is enough (api/test vs api/lib)",
         %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 pr: "1",
                 note: "merged to main",
                 criterion: 0,
                 files: ["api/lib/barkpark_web/controllers/tasks_controller.ex"]
               )

      assert [%{"met" => true}] = criteria(doc)
    end

    test "POSITIVE CONTROL — a landing with NO files keeps today's behaviour",
         %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 pr: "17345",
                 note: "merged to main",
                 criterion: 0
               )

      assert [%{"met" => true}] = criteria(doc)
    end

    test "a row that names NO path permits — the guard never asserts what it did not measure",
         %{scope: scope} do
      doc =
        task!(
          scope,
          %{"description" => "route it to the tasks owner, not the gates fence"},
          "the merge-shaped criterion flip has no overlap check"
        )

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 pr: "17345",
                 note: "merged to main",
                 criterion: 0,
                 files: ["cloud/lib/barkpark_cloud/oauth.ex"]
               )

      assert [%{"met" => true}] = criteria(doc)
    end

    test "the guard NEVER fires without a criterion — a landing sentence is not a flip",
         %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} =
               Tasks.record_landing(doc.id, pr: "1", files: ["cloud/lib/x.ex"])

      assert landed(doc)["files"] == ["cloud/lib/x.ex"]
      assert [%{"met" => false}] = criteria(doc)
    end
  end

  # ── The report the response carries ──────────────────────────────────────

  describe "overlap_report/3 — the guard says what it did" do
    test "no criterion → nothing to report", %{scope: scope} do
      doc = reload(task!(scope))
      assert Landed.overlap_report(doc, ["api/a.ex"], nil) == %{}
    end

    test "a fileless flip reports checked:false and WHY", %{scope: scope} do
      doc = reload(task!(scope))
      assert %{overlap: %{checked: false, reason: reason}} = Landed.overlap_report(doc, nil, 0)
      assert reason =~ "no files"
      refute Map.has_key?(Landed.overlap_report(doc, nil, 0).overlap, :files)
    end

    test "a checked flip reports both sides", %{scope: scope} do
      doc = reload(task!(scope))

      assert %{overlap: %{checked: true, files: ["api/a.ex"], row_paths: paths}} =
               Landed.overlap_report(doc, ["api/a.ex"], 0)

      assert "api/lib/barkpark/tasks/landed.ex" in paths
    end

    test "a row naming no path reports checked:false for the OTHER reason", %{scope: scope} do
      doc = reload(task!(scope, %{"description" => "no paths here"}, "no paths in the title"))

      assert %{overlap: %{checked: false, reason: reason, files: ["api/a.ex"]}} =
               Landed.overlap_report(doc, ["api/a.ex"], 0)

      assert reason =~ "no path-shaped token"
    end
  end
end
