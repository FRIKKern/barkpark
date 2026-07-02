defmodule Barkpark.Content.StatusPrefixCoherenceTest do
  @moduledoc """
  The status-vs-prefix two-truth invariant: a row's `drafts.`-prefix and its
  `status` column must never disagree.

    (a) The write chokepoints (`create_document` / `upsert_document`, and the
        `create` mutation that rides them) force the id to `drafts.<id>`, so a
        caller-supplied `"status":"published"` is coerced to `"draft"` — no
        incoherent draft-prefixed/published row can ever be stored.
    (b) Belt-and-braces on the read side: even if such an incoherent row exists
        (raw-inserted here), the D5 `published_only: true` wikilink gate
        prefix-conjuncts it out, so it never resolves into an anonymous chip.
    (c) The `patch` mutation drops `status` (server-owned) from `set` — a
        contract lock so state only changes via publish/unpublish.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "status_prefix_coherence_test"

  defp raw_row(doc_id, type),
    do: Repo.get_by(Document, doc_id: doc_id, type: type, dataset: @dataset)

  describe "(a) write chokepoint coerces status=published to draft" do
    test "create_document with status=published stores a drafts.-prefixed draft row" do
      {:ok, doc} =
        Content.create_document(
          "post",
          %{"_id" => "c-pub", "title" => "Sneaky", "status" => "published"},
          @dataset
        )

      assert doc.doc_id == "drafts.c-pub"
      assert doc.status == "draft"
    end

    test "upsert_document with status=published stores a drafts.-prefixed draft row" do
      {:ok, doc} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "u-pub", "title" => "Sneaky", "status" => "published"},
          @dataset
        )

      assert doc.doc_id == "drafts.u-pub"
      assert doc.status == "draft"
    end

    test "the `create` mutation rides the same coercion" do
      mutation = %{
        "create" => %{
          "_id" => "m-pub",
          "_type" => "post",
          "title" => "Sneaky",
          "status" => "published"
        }
      }

      {:ok, {_tx, [_result]}} = Content.apply_mutations([mutation], @dataset, [])

      row = raw_row("drafts.m-pub", "post")
      assert row.doc_id == "drafts.m-pub"
      assert row.status == "draft"
    end

    test "a non-published caller status is preserved (only the incoherent value is touched)" do
      # `active` is a valid workflow status (Document.changeset inclusion); it is
      # NOT the incoherent `published` value, so it passes through untouched.
      {:ok, doc} =
        Content.create_document(
          "post",
          %{"_id" => "c-active", "title" => "Work", "status" => "active"},
          @dataset
        )

      assert doc.status == "active"
    end
  end

  describe "(b) read-side prefix conjunct fails closed on an incoherent row" do
    test "a raw drafts.-prefixed status=published row is invisible to published_only" do
      # Bypass the chokepoint to fabricate the incoherent state the belt guards.
      {:ok, _} =
        %Document{}
        |> Document.changeset(%{
          "doc_id" => "drafts.leaky",
          "type" => "post",
          "dataset" => @dataset,
          "title" => "Leaky Draft",
          "status" => "published",
          "rev" => "r1"
        })
        |> Repo.insert()

      # Authorized surface (no gate): the row resolves.
      assert [%Document{doc_id: "drafts.leaky"}] =
               Content.resolve_docs_by_titles_or_aliases(["Leaky Draft"], [], "post", @dataset)

      # Anonymous surface (published_only): the drafts.-prefix conjunct hides it,
      # despite the status column reading "published".
      assert Content.resolve_docs_by_titles_or_aliases(
               ["Leaky Draft"],
               [],
               "post",
               @dataset,
               published_only: true
             ) == []
    end
  end

  describe "(c) patch drops the server-owned status field" do
    test "a patch set: %{status: ...} leaves the stored status untouched" do
      {:ok, doc} =
        Content.create_document(
          "post",
          %{"_id" => "p-lock", "title" => "Locked", "status" => "draft"},
          @dataset
        )

      assert doc.status == "draft"

      mutation = %{
        "patch" => %{
          "id" => "p-lock",
          "type" => "post",
          "set" => %{"status" => "published", "title" => "Renamed"}
        }
      }

      {:ok, {_tx, [_result]}} = Content.apply_mutations([mutation], @dataset, [])

      row = raw_row("drafts.p-lock", "post")
      # status is protected/dropped; only the promoted title changed.
      assert row.status == "draft"
      assert row.title == "Renamed"
    end
  end
end
