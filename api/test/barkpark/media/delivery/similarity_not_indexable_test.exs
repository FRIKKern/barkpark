defmodule Barkpark.Media.Delivery.SimilarityNotIndexableTest do
  @moduledoc """
  INVERSE protective proof for the media-delivery retriever's `similarity()`
  arms (authoring-excellence D49(e) / D51).

  `Barkpark.Media.Delivery.Retriever.include_dynamic/3` fuzzy-matches media on a
  CROSS-TABLE OR: `media_files` (m.*) UNION `documents` (d.*, reached via the
  LEFT JOIN in `build_text_filter/4`). The wave-6 dedup slice (D46) taught that a
  `similarity(?, ?) > x` arm can be rewritten to the GIN-engaging `%` operator to
  ride a trgm index — so a future agent will be tempted to `%`-rewrite these arms
  and add a `gin(original_name gin_trgm_ops)` index, then "prove" the win with a
  full-path EXPLAIN. That is a VACUOUS-GREEN TRAP: the cross-table OR structurally
  defeats the index no matter the operator form.

  This test makes the failure REPRODUCIBLE and STRUCTURAL, not a missing index:

    * INVERSE — with a REAL `gin(original_name gin_trgm_ops)` index present AND
      the `%` rewrite already applied to the arm, the cross-table-OR-shaped join
      query's plan does NOT contain a Bitmap Index Scan on that media index. It is
      red-if-someone-adds-a-real-index: the day the OR is un-poisoned by a pre-join
      restructure (backlog ae-search-or-arm-restructure), this assertion flips and
      forces the guard to be revisited.

    * CONTROL — the ISOLATED `original_name % ?` arm alone (single table, no join,
      no OR) DOES ride the very same index (Bitmap Index Scan). This proves the
      index is real and usable and the inverse failure above is STRUCTURAL (the
      cross-table OR), not an absent or broken index.

  Both plans are taken under `SET LOCAL enable_seqscan = off`: at the ~3000-row
  sandbox corpus a raw seq-scan is cheaper than a trgm GIN scan (the win is
  scale-gated), so the default plan seq-scans everything and would prove nothing.
  Penalizing seq-scan reveals index ELIGIBILITY — the control reaches the index,
  the cross-table OR still cannot (it falls to a pkey scan on media_files).

  Uses a PLAIN `CREATE INDEX` (not CONCURRENTLY): plain index creation runs
  inside the test's sandbox transaction and rolls back with it, so no schema
  residue leaks. See charter D49.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "production"
  @asset_type "mediaAsset"
  @term "landscape"

  # The net-new media trgm index a naive rewriter would add. Named distinctly so
  # the plan-text assertions can look for it unambiguously.
  @media_trgm_idx "media_files_original_name_trgm_probe_idx"

  # Enough rows that the planner has a genuine seq-scan-vs-index choice.
  @seed_count 3000

  setup do
    now = DateTime.utc_now()

    media =
      for i <- 1..@seed_count do
        %{
          id: Ecto.UUID.generate(),
          filename: "file-#{i}.jpg",
          original_name: "Unrelated distinct media heading number #{i} sunset over water",
          path: "blobs/#{i}.jpg",
          mime_type: "image/jpeg",
          size: 1000 + i,
          dataset: @dataset,
          inserted_at: now,
          updated_at: now
        }
      end

    {mcount, inserted} = Repo.insert_all(MediaFile, media, returning: [:id])
    assert mcount == @seed_count

    # Joined mediaAsset documents so the LEFT JOIN has realistic cardinality —
    # the plan shape (join-then-filter) is what defeats the index, and real rows
    # give the planner honest statistics.
    docs =
      inserted
      |> Enum.with_index(1)
      |> Enum.map(fn {%{id: media_id}, i} ->
        %{
          doc_id: "asset-doc-#{i}",
          type: @asset_type,
          dataset: @dataset,
          title: "Asset document number #{i} describing the scene",
          status: "published",
          content: %{"mediaFileId" => media_id, "tags" => []},
          rev: "rev-asset-#{i}",
          inserted_at: now,
          updated_at: now
        }
      end)

    {dcount, _} = Repo.insert_all(Document, docs)
    assert dcount == @seed_count

    # A REAL trgm index on the column the cross-table OR touches — the exact
    # index a future agent would add before `%`-rewriting the arm. Plain CREATE
    # INDEX rolls back with the sandbox transaction.
    Repo.query!(
      "CREATE INDEX #{@media_trgm_idx} ON media_files USING gin (original_name gin_trgm_ops)"
    )

    Repo.query!("ANALYZE media_files")
    Repo.query!("ANALYZE documents")

    # `%` reads pg_trgm.similarity_threshold; pin it low (mirrors the D46/D50
    # SET-LOCAL floor) so the operator is meaningful. Transaction-scoped, applies
    # to every query below inside the sandbox transaction.
    Repo.query!("SET LOCAL pg_trgm.similarity_threshold = 0.1")

    :ok
  end

  # The CROSS-TABLE OR, shaped exactly like Retriever.include_dynamic/3 but with
  # the `similarity() > x` arms already REWRITTEN to `%` — i.e. the naive future
  # rewrite. If even this cannot ride the index, the arm is proven non-reachable.
  defp cross_table_or_query do
    pattern = "%" <> @term <> "%"

    asset_docs =
      from(d in Document, where: d.type == ^@asset_type and d.dataset == ^@dataset)

    MediaFile
    |> from(as: :media)
    |> join(:left, [m], d in subquery(asset_docs),
      as: :asset,
      on: fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
    )
    |> where(
      [m, d],
      ilike(m.original_name, ^pattern) or ilike(m.filename, ^pattern) or
        ilike(d.title, ^pattern) or
        fragment("? % ?", m.original_name, ^@term) or
        fragment("? % ?", m.filename, ^@term) or
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?)",
          d.content,
          ^pattern
        )
    )
    |> select([m], m.id)
  end

  # The ISOLATED arm — single table, no join, no OR. This is what the index CAN
  # accelerate; it is the control that proves the index is real.
  defp isolated_control_query do
    from(m in MediaFile,
      where: fragment("? % ?", m.original_name, ^@term),
      select: m.id
    )
  end

  test "the cross-table OR does NOT ride the media trgm index, even with `%` and a real index present" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan = Repo.explain(:all, cross_table_or_query())

    refute plan =~ @media_trgm_idx,
           "the cross-table OR must NOT engage the media trgm index — the LEFT JOIN " <>
             "over media_files ∪ documents defeats a BitmapOr on m.original_name. If " <>
             "this fires, the OR was un-poisoned (a pre-join restructure landed) and " <>
             "the WHY-LEFT comment in retriever.ex must be revisited. Plan:\n#{plan}"

    refute plan =~ ~r/Bitmap Index Scan on #{@media_trgm_idx}/,
           "no Bitmap Index Scan on the media trgm index is possible for the " <>
             "cross-table OR. Plan:\n#{plan}"
  end

  test "CONTROL: the isolated `original_name % ?` arm DOES ride the same media trgm index" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan = Repo.explain(:all, isolated_control_query())

    assert plan =~ @media_trgm_idx,
           "the isolated `original_name % ?` arm MUST engage the trgm index — this " <>
             "proves the index is real and usable, so the cross-table OR's failure " <>
             "above is STRUCTURAL (the join), not a missing index. Plan:\n#{plan}"

    assert plan =~ ~r/Bitmap Index Scan|Index Scan/,
           "expected an (Bitmap) Index Scan for the isolated `%` arm. Plan:\n#{plan}"
  end
end
