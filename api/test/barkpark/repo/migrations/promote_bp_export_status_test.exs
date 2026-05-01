defmodule Barkpark.Repo.Migrations.PromoteBpExportStatusTest do
  @moduledoc """
  Phase 8 WI1 — verifies the bp_export_status promotion migration is
  idempotent, reversible, and default-fills missing composite fields.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260501102205_promote_bp_export_status.exs",
                    __DIR__
                  )

  setup_all do
    # Migration files are not in the regular load path; require them
    # explicitly so the test can call up/0 and down/0 directly.
    Code.require_file(@migration_file)
    :ok
  end

  alias Barkpark.Repo.Migrations.PromoteBpExportStatus

  defp seed_book(doc_id, bp_export_status) do
    content =
      case bp_export_status do
        :missing -> %{"unrelated" => "value"}
        v -> %{"bp_export_status" => v, "unrelated" => "value"}
      end

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Migration Test " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev-mig-" <> doc_id <> "-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    doc
  end

  defp bp_status_of(doc_id) do
    Repo.get_by!(Document, doc_id: doc_id, type: "book", dataset: "production")
    |> Map.get(:content)
    |> Map.get("bp_export_status")
  end

  describe "up/0" do
    test "transforms a Phase 7 JSON-encoded map into a native composite" do
      encoded =
        Jason.encode!(%{
          "state" => "polling",
          "bokbasen_submission_id" => "abc-123",
          "updated_at" => "2026-04-30T10:00:00Z"
        })

      seed_book("mig-encoded", encoded)

      PromoteBpExportStatus.apply_up(Repo)

      result = bp_status_of("mig-encoded")
      assert is_map(result)
      assert result["state"] == "polling"
      assert result["bokbasen_submission_id"] == "abc-123"
      # Default-fill: missing keys get default values.
      assert result["attempt_count"] == 0
      assert result["signed_off"] == false
    end

    test "transforms a legacy plain string into %{state: <string>} with defaults" do
      seed_book("mig-legacy", "draft")

      PromoteBpExportStatus.apply_up(Repo)

      result = bp_status_of("mig-legacy")
      assert is_map(result)
      assert result["state"] == "draft"
      assert result["attempt_count"] == 0
      assert result["signed_off"] == false
    end

    test "default-fills missing fields when value is already a native object" do
      seed_book("mig-native", %{"state" => "accepted"})

      PromoteBpExportStatus.apply_up(Repo)

      result = bp_status_of("mig-native")
      assert result["state"] == "accepted"
      assert result["attempt_count"] == 0
      assert result["signed_off"] == false
      assert Map.has_key?(result, "last_error")
    end

    test "is idempotent — running twice yields the same composite shape" do
      seed_book("mig-idem", "draft")

      PromoteBpExportStatus.apply_up(Repo)
      first = bp_status_of("mig-idem")

      PromoteBpExportStatus.apply_up(Repo)
      second = bp_status_of("mig-idem")

      assert first == second
    end

    test "leaves documents without bp_export_status untouched" do
      seed_book("mig-no-status", :missing)

      PromoteBpExportStatus.apply_up(Repo)

      doc = Repo.get_by!(Document, doc_id: "mig-no-status", type: "book", dataset: "production")

      refute Map.has_key?(doc.content, "bp_export_status")
      assert doc.content["unrelated"] == "value"
    end
  end

  describe "down/0" do
    test "round-trip: composite → up → down restores plain string of state" do
      seed_book("mig-rt", "polling")

      PromoteBpExportStatus.apply_up(Repo)
      assert is_map(bp_status_of("mig-rt"))

      PromoteBpExportStatus.apply_down(Repo)

      restored = bp_status_of("mig-rt")
      assert restored == "polling"
    end
  end
end
