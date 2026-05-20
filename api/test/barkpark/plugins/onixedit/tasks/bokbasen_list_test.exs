defmodule Barkpark.Plugins.OnixEdit.Tasks.BokbasenListTest do
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Content.Document
  alias Mix.Tasks.Bokbasen.List, as: ListTask

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)
    :ok
  end

  defp seed_book(doc_id, state, opts \\ []) do
    sub = Keyword.get(opts, :submission_id)
    updated_at = Keyword.get(opts, :updated_at, "2026-04-30T10:00:00.000000Z")

    bp =
      %{"state" => state, "updated_at" => updated_at}
      |> then(fn m -> if sub, do: Map.put(m, "bokbasen_submission_id", sub), else: m end)

    content = %{"bp_export_status" => Jason.encode!(bp)}

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "List " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  describe "--status <state>" do
    test "filters to matching state only" do
      seed_book("l-fail-1", "failed", submission_id: "s1")
      seed_book("l-fail-2", "failed", submission_id: "s2")
      seed_book("l-ok-1", "accepted", submission_id: "s3")

      output = capture_io(fn -> ListTask.run(["--status", "failed"]) end)

      assert output =~ "l-fail-1"
      assert output =~ "l-fail-2"
      refute output =~ "l-ok-1"
    end
  end

  describe "--limit" do
    test "truncates output to N rows" do
      for i <- 1..10 do
        seed_book("limit-#{i}", "accepted", submission_id: "s#{i}")
      end

      output = capture_io(fn -> ListTask.run(["--limit", "3"]) end)

      lines =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "limit-"))

      assert length(lines) <= 3
    end
  end

  describe "errors" do
    test "raises Mix.Error and lists valid states on invalid --status" do
      seed_book("any", "accepted")

      assert_raise Mix.Error, ~r/invalid status/i, fn ->
        capture_io(fn -> ListTask.run(["--status", "invalid_state"]) end)
      end

      output =
        capture_io(:stderr, fn ->
          try do
            ListTask.run(["--status", "still_invalid"])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "valid states" or output =~ "invalid"
    end

    test "raises on unknown switches" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> ListTask.run(["--bogus"]) end)
      end
    end
  end

  describe "no rows" do
    test "prints friendly message when no submissions exist" do
      output = capture_io(fn -> ListTask.run([]) end)
      assert output =~ "no matching submissions"
    end
  end
end
