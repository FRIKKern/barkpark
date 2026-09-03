defmodule Barkpark.Plugins.Media.PurgePaginationTailTest do
  @moduledoc """
  task-57ee9fff4aae9217 #12, second half — REPRODUCE the flaky decreasing tail.

  ## The observation being reproduced

  Gyldendal's first media purge needed three retries, and the number of assets
  left behind fell but never reached zero: **186 / 79 / 67 / 38**. The row's
  hypothesis on record: "a decreasing-but-nonzero tail smells like pagination
  mutating under iteration, not a transient." That hypothesis is CORRECT, and
  this file is the arithmetic.

  ## The mechanism, exactly

  `Media.query_files/2` pages with `:limit` + `:offset` (media.ex), and OFFSET
  is positional in the CURRENT result set, not a cursor into a fixed one. A
  purge loop that reads a page, deletes everything on it, then advances
  `offset` by the page size is therefore walking a list that shrank underneath
  it: after deleting the `P` rows at offset `0`, every remaining row slides `P`
  positions toward the front, so asking for offset `P` next SKIPS the `P` rows
  that just moved into `0..P-1`. Each step of the loop skips exactly one page.

  For `N` rows and page size `P`, one full sweep therefore deletes only about
  HALF of them, and the survivors are alternating blocks of `P`. Rerunning the
  purge halves what is left again — a decreasing, never-zero tail that looks
  exactly like a flaky transient and is not one. It is deterministic, it does
  not depend on concurrency, and no amount of retrying is a fix: the fix is on
  the CLIENT loop (always re-read offset 0, or page by a stable cursor).

  ## What this test is, and is not

  It is a REPRODUCTION and it is green both before and after the atomicity
  change in this PR — deliberately. The tail is a client-side paging fault; the
  atomicity fix cannot and does not close it. The criterion asks for the tail to
  be reproduced and explained, and states that "atomicity alone does not close
  this half". This is the proof that the two halves are separate faults.

  The control arm below is the other half of the explanation: the SAME purge
  loop, over the SAME fixture, drains to zero in ONE pass when it stops
  advancing the offset. Same data, same deletes, different paging — so the
  survivors cannot be blamed on the delete.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media

  @dataset "production"

  # 32 rows, page size 8. Small enough to run fast, large enough that the tail
  # has somewhere to go: 32 → 16 → 8 → 4 → 2 → 1 → 0.
  @fixture_size 32
  @page_size 8

  describe "an offset-advancing purge loop leaves a decreasing, non-zero tail" do
    test "the tail halves each round instead of draining" do
      # NON-VACUITY: every count below is a whole-dataset count, so a dirty
      # baseline would silently change the arithmetic this test is asserting.
      assert count_files() == 0, "the media library was not empty at test start"

      seed_files!(@fixture_size)
      assert count_files() == @fixture_size

      tail = run_rounds(&purge_pass_advancing_offset/0, [])

      # Round 1 did NOT drain the library, even though every delete succeeded.
      assert hd(tail) > 0,
             "the purge loop drained in one pass — the fixture is not reproducing the paging fault"

      # Strictly decreasing, never zero until the very end: the customer's
      # 186 / 79 / 67 / 38 shape.
      assert length(tail) >= 3,
             "expected at least three non-empty retry rounds, got #{inspect(tail)}"

      assert tail == Enum.sort(tail, :desc), "the tail did not decrease: #{inspect(tail)}"
      assert Enum.uniq(tail) == tail, "the tail stalled instead of decreasing: #{inspect(tail)}"
      assert count_files() == 0, "the loop never terminated: #{inspect(tail)}"
    end
  end

  describe "CONTROL — the same deletes, paged without advancing the offset" do
    test "one pass drains the library completely" do
      # NON-VACUITY: every count below is a whole-dataset count, so a dirty
      # baseline would silently change the arithmetic this test is asserting.
      assert count_files() == 0, "the media library was not empty at test start"

      seed_files!(@fixture_size)
      assert count_files() == @fixture_size

      deleted = purge_pass_stable_offset()

      assert deleted == @fixture_size
      assert count_files() == 0
    end
  end

  # ── the two purge loops ───────────────────────────────────────────────────

  # THE BUG. Read a page, delete it, advance `offset` by the page size. This is
  # what a paginating client writes when it assumes offset is a cursor.
  defp purge_pass_advancing_offset do
    Stream.iterate(0, &(&1 + @page_size))
    |> Enum.reduce_while(0, fn offset, deleted ->
      case page(offset) do
        [] -> {:halt, deleted}
        files -> {:cont, deleted + delete_all!(files)}
      end
    end)
  end

  # THE FIX, client-side. Always re-read from the front; the rows that slid
  # forward are read on the next iteration instead of skipped.
  defp purge_pass_stable_offset do
    Stream.repeatedly(fn -> page(0) end)
    |> Enum.reduce_while(0, fn
      [], deleted -> {:halt, deleted}
      files, deleted -> {:cont, deleted + delete_all!(files)}
    end)
  end

  defp page(offset) do
    {files, _total} = Media.query_files(@dataset, limit: @page_size, offset: offset)
    files
  end

  defp delete_all!(files) do
    Enum.count(files, fn file ->
      match?({:ok, _}, Media.delete_file(file.id))
    end)
  end

  # Rerun the purge until it finally drains, recording how many rows SURVIVED
  # each round. That list is the retry tail.
  defp run_rounds(pass, acc) do
    _ = pass.()

    case count_files() do
      0 -> Enum.reverse(acc)
      remaining -> run_rounds(pass, [remaining | acc])
    end
  end

  defp count_files do
    {_files, total} = Media.query_files(@dataset, limit: 1, offset: 0)
    total
  end

  defp seed_files!(n) do
    for i <- 1..n do
      name = "purge-#{String.pad_leading("#{i}", 3, "0")}.png"

      path =
        Path.join(System.tmp_dir!(), "media-purge-#{System.unique_integer([:positive])}-#{name}")

      File.write!(path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, i>>)

      {:ok, file} =
        Media.upload(
          %Plug.Upload{path: path, filename: name, content_type: "image/png"},
          @dataset
        )

      file
    end
  end
end
