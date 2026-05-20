defmodule Barkpark.Plugins.OnixEdit.Tasks.BokbasenStatusTest do
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Content.Document
  alias Mix.Tasks.Bokbasen.Status

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)
    :ok
  end

  defp seed_book(doc_id, bp_status_map) do
    content =
      case bp_status_map do
        nil -> %{}
        m -> %{"bp_export_status" => Jason.encode!(m)}
      end

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Status Test " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  describe "--book-id <known>" do
    test "prints fields for an accepted submission" do
      _doc =
        seed_book("st-1", %{
          "state" => "accepted",
          "bokbasen_submission_id" => "sub-xyz",
          "updated_at" => "2026-04-30T10:11:12.000000Z"
        })

      output =
        capture_io(fn ->
          Status.run(["--book-id", "st-1"])
        end)

      assert output =~ "doc_id"
      assert output =~ "st-1"
      assert output =~ "state"
      assert output =~ "accepted"
      assert output =~ "submission_id"
      assert output =~ "sub-xyz"
      assert output =~ "last_action_at"
      assert output =~ "2026-04-30T10:11:12.000000Z"
    end

    test "shows last_error envelope when present" do
      _doc =
        seed_book("st-err", %{
          "state" => "failed",
          "last_error" => %{"type" => "auth", "summary" => "AuthError"}
        })

      output = capture_io(fn -> Status.run(["--book-id", "st-err"]) end)

      assert output =~ "auth"
      assert output =~ "AuthError"
    end
  end

  describe "summary" do
    test "renders all 9 state labels with counts" do
      seed_book("a", %{"state" => "accepted"})
      seed_book("b", %{"state" => "failed"})
      seed_book("c", %{"state" => "failed"})
      seed_book("d", %{"state" => "pending"})

      output = capture_io(fn -> Status.run([]) end)

      for s <-
            ~w(pending staging staged polling accepted rejected failed cancelled cannot_cancel) do
        assert output =~ s, "expected summary to mention #{s}"
      end

      assert output =~ "total"
    end
  end

  describe "errors" do
    test "raises Mix.Error when --book-id refers to a missing doc" do
      assert_raise Mix.Error, ~r/book not found/i, fn ->
        capture_io(fn -> Status.run(["--book-id", "missing-x"]) end)
      end
    end

    test "raises on unknown switches" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Status.run(["--bogus"]) end)
      end
    end
  end
end
