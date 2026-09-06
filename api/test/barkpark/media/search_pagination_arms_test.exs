defmodule Barkpark.Media.SearchPaginationArmsTest do
  @moduledoc """
  A PAGED MEDIA LISTING IS CONSISTENT WITH ITS OWN SORT, ON EVERY ARM
  (task-a00f46ef36eca19e).

  `Search.apply_sort/2` offers four orderings; `Search.paginate_ids/2` used to
  apply ONE keyset predicate — `(m.inserted_at, m.id) < (^at, ^id)` — to all
  four, unconditionally, while no arm's ORDER BY carried the `m.id` tiebreak the
  predicate compares on. Nothing raised and nothing logged; the caller just got
  a truncated or duplicated result set.

  MEASURED on the corpus below (12 rows, 3-way ties on `inserted_at`, cursor
  pages of 3, walked to exhaustion) BEFORE the fix:

      arm            walked  skipped  repeated
      created-desc     12       2        2
      created-asc       4       9        1
      updated-desc      9       6        3
      relevance         9       5        2

  So `created-desc` was NOT the "narrower" case — with ties it loses and
  duplicates rows exactly like the others.

  What this file holds down:

    * the two arms a `(inserted_at, id)` cursor CAN page — `created-desc` and
      `created-asc` — walk to exhaustion and reproduce the unpaged order
      exactly, in the correct DIRECTION (the old `<` bound run against an
      ascending sort restarted at the top of the corpus on page 2);
    * every arm, including the two that page by offset, walks to exhaustion in
      its own order — which requires the ORDER BY to be TOTAL, i.e. to end in
      `m.id`;
    * the arms whose ordering key the cursor token cannot express hand out NO
      cursor, instead of one that silently skips.

  NON-VACUITY: every walk runs through `assert_walk/4`, which refuses a corpus
  that is empty, single-page, or free of ties on the primary sort column. A
  fixture that stops generating rows fails loudly here rather than passing with
  nothing to page.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @asset_type "mediaAsset"
  @seed 12
  @page 3
  @q "sunset"

  # The arms a keyset cursor can page, and the arms that page by offset.
  @cursor_arms ["created-desc", "created-asc"]
  @offset_arms ["updated-desc", "relevance"]
  @all_arms @cursor_arms ++ @offset_arms

  setup do
    # A dataset STRING that resolves to no `datasets` row, so `build_query/2`
    # takes the legacy string filter and the corpus is not shared with the other
    # agents on this box. (A media fixture with neither a resolvable dataset nor
    # a `dataset_id` lists EMPTY — which would make every "nothing skipped"
    # assertion pass for the wrong reason. The non-vacuity floor below is what
    # catches that.)
    ds = "media-cursor-arms-#{System.unique_integer([:positive])}"
    base = ~U[2026-01-01 00:00:00.000000Z]

    media =
      for i <- 0..(@seed - 1) do
        # 4 distinct stamps, 3 rows each => deliberate TIES on the primary sort
        # column of the created-* arms.
        stamp = DateTime.add(base, div(i, 3) * 3600, :second)

        %{
          id: Ecto.UUID.generate(),
          filename: "#{@q}-#{String.pad_leading("#{i}", 2, "0")}.jpg",
          original_name: "#{@q} over water #{i}",
          path: "#{ds}/blob-#{i}.jpg",
          mime_type: "image/jpeg",
          size: 1000 + i,
          dataset: ds,
          inserted_at: stamp,
          updated_at: stamp
        }
      end

    {@seed, inserted} = Repo.insert_all(MediaFile, media, returning: [:id])

    docs =
      inserted
      |> Enum.with_index()
      |> Enum.map(fn {%{id: mid}, i} ->
        # Document stamps are shuffled relative to the media stamps AND tied
        # 3-ways, so `updated-desc` is a genuinely different ordering.
        upd = DateTime.add(base, div(rem(i * 7, 12), 3) * 3600, :second)

        %{
          doc_id: "#{ds}-asset-#{i}",
          type: @asset_type,
          dataset: ds,
          title: "#{@q} asset #{i}",
          status: "published",
          content: %{"mediaFileId" => mid, "tags" => []},
          rev: "rev-#{ds}-#{i}",
          inserted_at: upd,
          updated_at: upd
        }
      end)

    {@seed, _} = Repo.insert_all(Document, docs)

    %{ds: ds}
  end

  # ---------------------------------------------------------------- helpers

  defp search(ds, opts), do: Search.search(ds, Keyword.merge([q: @q, offset: 0], opts))

  # The unpaged truth: the same query, same ORDER BY, one page big enough to
  # hold the whole corpus.
  defp reference(ds, sort) do
    {files, total, _facets, _meta} = search(ds, sort: sort, limit: 1000)
    {Enum.map(files, & &1.id), total}
  end

  # Walk pages by following `nextCursor` exactly the way
  # `BarkparkWeb.V1.MediaController.search/2` does.
  defp cursor_walk(ds, sort) do
    Enum.reduce_while(1..40, {[], nil, 0, 0}, fn _i, {acc, cursor, seen, pages} ->
      opts = [sort: sort, limit: @page]
      opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts
      {files, total, _facets, _meta} = search(ds, opts)
      ids = Enum.map(files, & &1.id)
      seen = seen + length(ids)
      has_more = length(files) >= @page and seen < total
      next = if has_more, do: Search.next_cursor(files), else: nil

      case next do
        nil -> {:halt, {acc ++ ids, nil, seen, pages + 1}}
        c -> {:cont, {acc ++ ids, c, seen, pages + 1}}
      end
    end)
    |> then(fn {acc, _c, _seen, pages} -> {acc, pages} end)
  end

  defp offset_walk(ds, sort) do
    Enum.reduce_while(0..39, {[], 0}, fn i, {acc, pages} ->
      {files, _total, _facets, _meta} =
        search(ds, sort: sort, limit: @page, offset: i * @page)

      ids = Enum.map(files, & &1.id)

      if length(ids) < @page,
        do: {:halt, {acc ++ ids, pages + 1}},
        else: {:cont, {acc ++ ids, pages + 1}}
    end)
  end

  # THE NON-VACUITY FLOOR. Every assertion below runs through here, so a fixture
  # that stops producing rows (the empty-listing trap: a media row with neither
  # a resolvable dataset nor a `dataset_id`) fails LOUDLY instead of passing
  # with nothing to page.
  defp assert_walk(sort, ref, walked, pages) do
    assert length(ref) >= 8,
           "VACUOUS: sort=#{sort} unpaged reference has #{length(ref)} rows — " <>
             "a walk over fewer than 8 rows proves nothing about paging. " <>
             "The corpus stopped generating (or is being filtered out)."

    assert pages >= 3,
           "VACUOUS: sort=#{sort} exhausted in #{pages} page(s) at limit=#{@page} — " <>
             "a single-page walk crosses no page boundary and so cannot skip or repeat."

    assert walked == ref,
           """
           sort=#{sort}: the paged walk is NOT its own sort.

           skipped:  #{inspect(ref -- walked)}
           repeated: #{inspect(walked -- Enum.uniq(walked))}

           unpaged:  #{inspect(ref)}
           walked:   #{inspect(walked)}
           """

    assert walked == Enum.uniq(walked), "sort=#{sort}: the walk repeated rows"
  end

  # ------------------------------------------------------------------ tests

  test "the corpus really does carry ties on the primary sort column", %{ds: ds} do
    {files, _total, _facets, _meta} = search(ds, sort: "created-desc", limit: 1000)
    stamps = Enum.map(files, & &1.inserted_at)

    assert length(files) == @seed
    assert length(Enum.uniq(stamps)) < length(stamps),
           "VACUOUS FIXTURE: no two rows share an `inserted_at`, so the cursor's " <>
             "`id` tiebreak is never exercised and criterion 2 is untested."
  end

  test "a cursor walk pages each cursorable arm to exhaustion, in its own order", %{ds: ds} do
    for sort <- @cursor_arms do
      {ref, _total} = reference(ds, sort)
      {walked, pages} = cursor_walk(ds, sort)
      assert_walk(sort, ref, walked, pages)
    end
  end

  test "an offset walk pages EVERY arm to exhaustion, in its own order", %{ds: ds} do
    for sort <- @all_arms do
      {ref, _total} = reference(ds, sort)
      {walked, pages} = offset_walk(ds, sort)
      assert_walk(sort, ref, walked, pages)
    end
  end

  test "an arm the cursor token cannot express hands out NO cursor", %{ds: ds} do
    for sort <- @cursor_arms do
      {files, _total, _facets, _meta} = search(ds, sort: sort, limit: @page)
      assert is_binary(Search.next_cursor(files)), "sort=#{sort} should mint a cursor"
    end

    for sort <- @offset_arms do
      {files, _total, _facets, _meta} = search(ds, sort: sort, limit: @page)
      assert length(files) == @page

      refute Search.next_cursor(files),
             """
             sort=#{sort} minted a keyset cursor. Its ordering key is not the
             `(inserted_at, id)` tuple the token carries — `updated-desc` orders
             by the LEFT-JOINed document's `updated_at` (nullable, not unique per
             media row) and `relevance` by a computed score that is not a column.
             Following such a token skipped 6 and 5 rows respectively on this
             corpus. `nil` is the honest answer; the caller pages by offset.
             """
    end
  end

  test "every arm's ORDER BY is total — the same page comes back every time", %{ds: ds} do
    for sort <- @all_arms do
      runs = for _ <- 1..5, do: elem(reference(ds, sort), 0)

      assert length(Enum.uniq(runs)) == 1,
             "sort=#{sort} returned different orders across identical unpaged reads — " <>
               "the ORDER BY is not total (missing the `m.id` tiebreak)."

      assert length(hd(runs)) == @seed
    end
  end
end
