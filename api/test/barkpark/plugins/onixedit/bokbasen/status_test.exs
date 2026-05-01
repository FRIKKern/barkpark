defmodule Barkpark.Plugins.OnixEdit.Bokbasen.StatusTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status
  alias Barkpark.Repo

  defp seed_doc(content) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => "status-test-#{System.unique_integer([:positive])}",
        "type" => "book",
        "dataset" => "production",
        "title" => "Status Test",
        "status" => "draft",
        "content" => content,
        "rev" => "rev-status-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    doc
  end

  describe "read/1" do
    test "returns empty composite for nil bp_export_status" do
      doc = seed_doc(%{})
      assert Status.read(doc) == %{}
    end

    test "returns empty composite for empty-string bp_export_status (legacy)" do
      doc = seed_doc(%{"bp_export_status" => ""})
      assert Status.read(doc) == %{}
    end

    test "coerces legacy plain string to %{state: <string>}" do
      doc = seed_doc(%{"bp_export_status" => "draft"})
      assert Status.read(doc) == %{"state" => "draft"}
    end

    test "decodes Phase 7 JSON-encoded map" do
      encoded = Jason.encode!(%{"state" => "polling", "submission_id" => "sub-1"})
      doc = seed_doc(%{"bp_export_status" => encoded})

      result = Status.read(doc)
      assert result["state"] == "polling"
      assert result["submission_id"] == "sub-1"
    end

    test "returns native composite map as-is" do
      doc = seed_doc(%{"bp_export_status" => %{"state" => "accepted", "attempt_count" => 3}})

      assert Status.read(doc) == %{"state" => "accepted", "attempt_count" => 3}
    end

    test "accepts a content map (not just a Document)" do
      content = %{"bp_export_status" => %{"state" => "rejected"}}
      assert Status.read(content) == %{"state" => "rejected"}
    end
  end

  describe "write/2" do
    test "round-trip: write composite, read returns same shape (string keys)" do
      doc = seed_doc(%{})

      _ =
        Status.write(doc, %{
          "state" => "polling",
          "submission_id" => "abc",
          "attempt_count" => 2
        })

      reloaded = Repo.get!(Document, doc.id)
      result = Status.read(reloaded)

      assert result["state"] == "polling"
      assert result["submission_id"] == "abc"
      assert result["attempt_count"] == 2
      assert is_binary(result["updated_at"])
    end

    test "atom-keyed patches are stored as string keys" do
      doc = seed_doc(%{})

      _ = Status.write(doc, %{state: "staging", submission_id: "x"})

      reloaded = Repo.get!(Document, doc.id)
      result = Status.read(reloaded)

      assert result["state"] == "staging"
      assert result["submission_id"] == "x"
    end

    test "DateTime values are stored as ISO-8601 strings" do
      doc = seed_doc(%{})
      now = DateTime.utc_now()

      _ = Status.write(doc, %{"state" => "staged", "staged_at" => now})

      reloaded = Repo.get!(Document, doc.id)
      result = Status.read(reloaded)

      assert is_binary(result["staged_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(result["staged_at"])
    end

    test "merges patch over current — earlier writes' fields are preserved" do
      doc = seed_doc(%{})

      _ = Status.write(doc, %{"state" => "staging", "submitted_at" => DateTime.utc_now()})

      reloaded = Repo.get!(Document, doc.id)
      _ = Status.write(reloaded, %{"state" => "staged", "submission_id" => "sub-9"})

      final = Status.read(Repo.get!(Document, doc.id))
      assert final["state"] == "staged"
      assert final["submission_id"] == "sub-9"
      assert is_binary(final["submitted_at"])
    end

    test "derives signed_off: true when accepted_at is set" do
      doc = seed_doc(%{})

      _ = Status.write(doc, %{"state" => "accepted", "accepted_at" => DateTime.utc_now()})

      reloaded = Repo.get!(Document, doc.id)
      result = Status.read(reloaded)

      assert result["signed_off"] == true
      assert is_binary(result["accepted_at"])
    end

    test "does NOT derive signed_off when accepted_at is missing" do
      doc = seed_doc(%{})

      _ = Status.write(doc, %{"state" => "rejected"})

      reloaded = Repo.get!(Document, doc.id)
      result = Status.read(reloaded)

      refute Map.get(result, "signed_off")
    end

    test "broadcasts {:bokbasen_status_update, status} on bokbasen:document:<doc_id>" do
      doc = seed_doc(%{})

      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{doc.doc_id}")

      _ = Status.write(doc, %{"state" => "staging"})

      assert_receive {:bokbasen_status_update, %{"state" => "staging"} = status}, 1_000
      assert is_binary(status["updated_at"])
    end
  end
end
