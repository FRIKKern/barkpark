defmodule Barkpark.ContentEnvelopeIdTest do
  @moduledoc """
  from_envelope id handling — the mixed-shape footgun.

  A create that mixes the Sanity-style top-level `_id` with a nested legacy
  `content` map used to silently DROP the supplied id (the legacy branch
  passed attrs through untranslated, so create_document fell back to a
  generated id). Every doc example that later referenced the supplied id was
  broken. Pins: mixed shape honors `_id`; an explicit `doc_id` still wins;
  the flat Sanity shape is unchanged.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "production"

  test "mixed shape (top-level _id + nested content) honors the supplied _id" do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "_id" => "envelope-mixed-1",
          "title" => "Mixed-shape create",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset
      )

    assert doc.doc_id == "drafts.envelope-mixed-1"
  end

  test "explicit doc_id wins over _id in the mixed shape" do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "envelope-docid-1",
          "_id" => "envelope-ignored",
          "title" => "doc_id wins",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset
      )

    assert doc.doc_id == "drafts.envelope-docid-1"
  end

  test "flat Sanity shape still folds fields into content and honors _id" do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "_id" => "envelope-flat-1",
          "title" => "Flat create",
          "kind" => "task",
          "lifecycle_status" => "open",
          "priority" => 2
        },
        @dataset
      )

    assert doc.doc_id == "drafts.envelope-flat-1"
    assert doc.content["kind"] == "task"
    assert doc.content["priority"] == 2
  end
end
