defmodule Barkpark.Media.Sha1BackfillTest do
  @moduledoc """
  `Barkpark.Media.Sha1Backfill`, the paged backfill behind
  `POST /v1/admin/media/sha1-backfill`: the dry run counts per dataset and
  reads nothing, a page hashes up to its limit, a missing blob is listed with
  its reason and stays NULL, and following `next_after` visits every row once.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Media, Repo}
  alias Barkpark.Media.{Blobstore, Sha1Backfill}
  alias Barkpark.Media.Storage.MediaFile

  defp unhashed_file!(dataset \\ "production") do
    bytes = "sha1 backfill page #{System.unique_integer([:positive])} #{:rand.uniform()}"
    path = Path.join(System.tmp_dir!(), "sbp-#{System.unique_integer([:positive])}.txt")
    File.write!(path, bytes)
    {:ok, file} = Media.upload(%Plug.Upload{path: path, filename: "sbp.txt"}, dataset)
    Repo.update_all(where(MediaFile, [m], m.id == ^file.id), set: [sha1: nil])
    {file, Base.encode16(:crypto.hash(:sha, bytes), case: :lower)}
  end

  defp sha1_of(id), do: Repo.one(from(m in MediaFile, where: m.id == ^id, select: m.sha1))

  test "plan counts the rows with no sha1 per dataset and writes nothing" do
    {a, _} = unhashed_file!("production")
    {b, _} = unhashed_file!("staging")

    plan = Sha1Backfill.plan()

    assert plan.unhashed >= 2
    assert plan.unhashed == Enum.sum(Enum.map(plan.datasets, & &1.unhashed))
    assert Enum.any?(plan.datasets, &(&1.dataset == "production" and &1.unhashed >= 1))
    assert Enum.any?(plan.datasets, &(&1.dataset == "staging" and &1.unhashed >= 1))
    assert sha1_of(a.id) == nil
    assert sha1_of(b.id) == nil
  end

  test "a page hashes up to its limit and hands back the cursor" do
    files = for _ <- 1..3, do: unhashed_file!()
    before = Sha1Backfill.plan().unhashed

    page = Sha1Backfill.run(limit: 2)

    assert page.hashed == 2
    assert page.failed == []
    assert is_binary(page.next_after)
    assert page.unhashed == before - 2

    rest = Sha1Backfill.run(after: page.next_after, limit: 500)
    assert rest.next_after == nil
    assert rest.unhashed == 0

    for {file, want} <- files, do: assert(sha1_of(file.id) == want)
  end

  test "a missing blob is listed with its reason, stays NULL, and the walk passes it" do
    {gone, _} = unhashed_file!()
    {kept, want} = unhashed_file!()
    {:ok, local} = Blobstore.ensure_local(gone)
    File.rm!(local)

    page = Sha1Backfill.run(limit: 500)

    assert page.next_after == nil
    assert [%{id: id, dataset: "production", reason: "blob_not_found"}] = page.failed
    assert id == gone.id
    assert page.unhashed == 1
    assert sha1_of(gone.id) == nil
    assert sha1_of(kept.id) == want
  end

  test "a spent budget still hashes one row, so every page makes progress" do
    for _ <- 1..2, do: unhashed_file!()

    page = Sha1Backfill.run(limit: 500, budget_ms: 0)

    assert page.hashed == 1
    assert is_binary(page.next_after)
  end

  test "a row that already has a sha1 is never rewritten" do
    {file, _} = unhashed_file!()
    Repo.update_all(where(MediaFile, [m], m.id == ^file.id), set: [sha1: "keep"])

    page = Sha1Backfill.run(limit: 500)

    assert page.hashed == 0
    assert sha1_of(file.id) == "keep"
  end
end
