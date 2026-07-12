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
  Wall-compliant labels whose tag names are UNIQUE per call AND registered in
  the E3 registry — for tests that publish MANY deliberately similar-titled
  docs (typeahead corpora, A/B embed pairs). The shared `fixture-tag-N` names
  contribute identical tokens to every doc's E4 dedup token bag; on thin
  titles that alone crosses the refuse band. One unique single-token tag name
  per call keeps tag-token overlap at zero, so only the TITLES under test
  drive similarity.
  """
  def with_registered_labels(content \\ %{}, dataset, tag_count \\ 2) do
    n = System.unique_integer([:positive])
    names = for i <- 1..tag_count, do: "qz#{n}tag#{i}"
    register_tags!(dataset, names)

    tags =
      names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, i} ->
        %{
          "tag" => name,
          "strength" => 100 - i,
          "rationale" => "Unique registered fixture tag ##{i} — dedup-neutral by construction."
        }
      end)

    Map.merge(Map.put(weighted_labels(tag_count), "tags", tags), content)
  end

  @doc """
  Wall-compliant weighted labels with EXPLICIT tag names — for tests that
  assert on specific names (the dual-shape tag readers, `hasStrong` filters,
  main_tag stamping). `names` entries are either `"name"` (descending
  strengths assigned automatically: FIRST name = strongest = the main tag) or
  `{"name", strength}` used verbatim. PURE — no registry write; use
  `with_named_labels/3` when the doc must pass the E3 gate. Description
  tokens stay unique per call (the E4 token-bag rule — `weighted_labels/1`).
  """
  def named_weighted_labels(names) when is_list(names) do
    tags =
      names
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{name, strength}, _i} ->
          %{
            "tag" => name,
            "strength" => strength,
            "rationale" => "Named fixture tag '#{name}' — exercises the dual-shape tag readers."
          }

        {name, i} ->
          %{
            "tag" => name,
            "strength" => 100 - i,
            "rationale" => "Named fixture tag '#{name}' — exercises the dual-shape tag readers."
          }
      end)

    Map.put(weighted_labels(), "tags", tags)
  end

  @doc """
  `named_weighted_labels/1` + E3 registration + merge into `content` (content
  wins on clash) — one call to make a doc with SPECIFIC tag names publishable
  through the whole wall.
  """
  def with_named_labels(content \\ %{}, dataset, names) do
    labels = named_weighted_labels(names)
    register_tags!(dataset, Enum.map(labels["tags"], & &1["tag"]))
    Map.merge(labels, content)
  end

  @doc """
  Register tag names in the E3 tag registry for `dataset` — inserts PUBLISHED
  `type:tag` rows directly (the test-side spelling of "publish a tag doc",
  fast and recursion-free). Defaults to the 12 `fixture-tag-N` names
  `weighted_labels/1` emits, so a test file that publishes walled fixture
  content needs exactly one setup line:

      LabelFixtures.register_tags!(@dataset)

  Pass explicit names when a test hand-rolls its own weighted tags. Rows are
  global-scope (nil workspace), so every workspace-scoped registry read
  resolves them (the registry reads workspace-including-global).
  """
  def register_tags!(dataset, names \\ nil) do
    names = names || for(i <- 1..12, do: "fixture-tag-#{i}")
    now = DateTime.utc_now()

    rows =
      Enum.map(names, fn name ->
        %{
          doc_id: name,
          type: "tag",
          dataset: dataset,
          title: name,
          status: "published",
          content: %{"description" => "Registered by LabelFixtures for wall tests."},
          rev: Barkpark.Content.Writer.generate_rev(),
          inserted_at: now,
          updated_at: now
        }
      end)

    Barkpark.Repo.insert_all(Barkpark.Content.Document, rows, on_conflict: :nothing)
    :ok
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
