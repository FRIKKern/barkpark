defmodule Barkpark.LabelFixtures do
  @moduledoc """
  Label-spine-compliant content fixtures for the publish wall
  (authoring-excellence). The wall (`Barkpark.Content.Lifecycle`
  `@walled_types`) requires every published paper/task to carry a non-trivial
  `description` and 1–12 weighted tags with distinct strengths and ≥20-char
  rationales — tests that publish those types merge `weighted_labels/1` into
  the doc's content.

  Kept OUT of individual test files so the label model has ONE test-side
  spelling: when the model evolves, this module moves with it.
  """

  @doc """
  A compliant `%{"description" => …, "tags" => …}` map to merge into a doc's
  content before publishing. `tag_count` defaults to 2 (inside the 2–4 norm so
  no advisory warning is emitted); pass 1 or 5..12 to deliberately exercise
  the norm advisory.
  """
  def weighted_labels(tag_count \\ 2) do
    tags =
      for i <- 1..tag_count do
        %{
          "tag" => "fixture-tag-#{i}",
          "strength" => 100 - i,
          "rationale" => "Fixture tag ##{i}: satisfies the publish wall in tests."
        }
      end

    # The description's tokens are UNIQUE per call. Tasks.Dedup guards task
    # CREATE with 0.7·Jaccard(title+description tokens) and a 3-shared-token
    # refuse floor — a byte-identical fixture description across every task in
    # a test file would trip the duplicate_task 409 (found live: the edge
    # projector suite). Two shared tokens ("label", "fixture") stay under both
    # the floor and the advise band.
    n = System.unique_integer([:positive])

    %{
      "description" => "Label fixture zq#{n}a zq#{n}b zq#{n}c zq#{n}d zq#{n}e.",
      "tags" => tags
    }
  end

  @doc "Merge compliant labels into an existing content map (content wins on clash)."
  def with_labels(content \\ %{}, tag_count \\ 2) do
    Map.merge(weighted_labels(tag_count), content)
  end

  @doc """
  Seed exemption-ledger rows for the given published doc ids — the test-side
  spelling of what the `authoring_exemptions` migration seeds at deploy time.

  For tests whose docs deliberately carry LEGACY content shapes (flat string
  tags, no description) because the feature under test reads that shape
  (`docs_with_tag`, `search_tags_for_type`, …): exempting them mirrors prod
  reality — every pre-wall doc IS in the ledger — without perturbing the
  content the test is about. `Barkpark.Content.Exemptions` itself stays
  DELETE-only; this insert exists only in test support.
  """
  def exempt!(doc_ids, dataset, type \\ "paper") do
    rows =
      doc_ids
      |> List.wrap()
      |> Enum.map(fn id ->
        %{doc_id: id, dataset: dataset, type: type, exempted_at: DateTime.utc_now()}
      end)

    Barkpark.Repo.insert_all("authoring_exemptions", rows, on_conflict: :nothing)
    :ok
  end
end
