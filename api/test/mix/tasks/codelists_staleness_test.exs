defmodule Mix.Tasks.Codelists.StalenessTest do
  @moduledoc """
  Phase 8 WI4 — exercises the `mix codelists.staleness` task end-to-end.

  Uses `capture_io` against the seeded book corpus and the in-memory
  registry table. Tests the two modes (`--report`, `--revalidate
  --book-id`) plus argument-validation errors.
  """

  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Content.Document
  alias Mix.Tasks.Codelists.Staleness

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)
    :ok
  end

  defp seed_book(doc_id, content) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "CL Staleness " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id <> "_#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    doc
  end

  describe "--report" do
    test "iterates books and reports drift counts in the trailing summary" do
      seed_book("rep-stale", %{
        "f" => %{"codelistId" => "onixedit:notification_type", "issue_version" => "70"}
      })

      seed_book("rep-current", %{
        "f" => %{"codelistId" => "onixedit:notification_type", "issue_version" => "73"}
      })

      output =
        capture_io(fn ->
          Staleness.run(["--report"])
        end)

      assert output =~ "codelist staleness report"
      assert output =~ "current registry issue: 73"
      assert output =~ "rep-stale"
      refute output =~ "  ~~rep-current~~"
      assert output =~ "books with drift:"
      assert output =~ "books all-current:"
      assert output =~ "total: 2"
    end

    test "prints per-book section headers + dotted paths for stale refs" do
      seed_book("rep-section", %{
        "outer" => %{
          "inner" => %{
            "codelistId" => "onixedit:contributor_role",
            "issue_version" => "70"
          }
        }
      })

      output = capture_io(fn -> Staleness.run(["--report"]) end)

      assert output =~ "book: rep-section"
      assert output =~ "outer.inner"
      assert output =~ "onixedit:contributor_role"
      assert output =~ "stale"
    end

    test "honours --current-issue override" do
      seed_book("rep-override", %{
        "f" => %{"codelistId" => "onixedit:notification_type", "issue_version" => "75"}
      })

      output =
        capture_io(fn ->
          Staleness.run(["--report", "--current-issue", "75"])
        end)

      assert output =~ "current registry issue: 75"
      # ref_issue 75 == current 75 → no drift section.
      refute output =~ "book: rep-override"
    end
  end

  describe "--revalidate --book-id" do
    test "prints a diff section for a known book" do
      seed_book("rev-known", %{
        "f" => %{"codelistId" => "onixedit:notification_type", "issue_version" => "73"}
      })

      output =
        capture_io(fn ->
          Staleness.run(["--revalidate", "--book-id", "rev-known"])
        end)

      assert output =~ "revalidate report for book: rev-known"
      assert output =~ "changed:"
      assert output =~ "removed:"
      assert output =~ "added:"
    end

    test "errors when --revalidate is given without --book-id" do
      assert_raise Mix.Error, ~r/--book-id/, fn ->
        capture_io(fn -> Staleness.run(["--revalidate"]) end)
      end
    end

    test "raises Mix.Error when --book-id refers to a missing doc" do
      assert_raise Mix.Error, ~r/book not found/i, fn ->
        capture_io(fn -> Staleness.run(["--revalidate", "--book-id", "no-such-book"]) end)
      end
    end
  end

  describe "errors" do
    test "raises Mix.Error when neither --report nor --revalidate is given" do
      assert_raise Mix.Error, ~r/missing mode/i, fn ->
        capture_io(fn -> Staleness.run([]) end)
      end
    end

    test "raises on unknown switches" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Staleness.run(["--bogus"]) end)
      end
    end
  end
end
