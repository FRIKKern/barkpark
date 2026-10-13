defmodule Barkpark.ReleaseMediaSha1BackfillTest do
  @moduledoc """
  `bin/barkpark eval 'Barkpark.Release.backfill_media_sha1()'` — the release
  twin of `mix barkpark.media.backfill_sha1` (task-b6e57c37f6928344). The
  one-shot boot is injected as a no-op here: the test repo is already running.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Barkpark.{Media, Release, Repo}
  alias Barkpark.Media.Storage.MediaFile

  defp unhashed_file! do
    bytes = "release backfill #{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "rb-#{System.unique_integer([:positive])}.txt")
    File.write!(path, bytes)
    {:ok, file} = Media.upload(%Plug.Upload{path: path, filename: "rb.txt"}, "production")
    Repo.update_all(where(MediaFile, [m], m.id == ^file.id), set: [sha1: nil])
    {file, Base.encode16(:crypto.hash(:sha, bytes), case: :lower)}
  end

  test "dry_run counts the NULL rows and writes nothing" do
    {file, _} = unhashed_file!()

    out =
      capture_io(fn ->
        send(self(), Release.backfill_media_sha1(boot: fn -> :ok end, dry_run: true))
      end)

    assert_received %{hashed: 0, remaining: remaining}
    assert remaining >= 1
    assert out =~ "media sha1 backfill"
    assert {:ok, %MediaFile{sha1: nil}} = Media.get_file(file.id)
  end

  test "a real run hashes the row born before the column" do
    {file, want} = unhashed_file!()

    capture_io(fn -> send(self(), Release.backfill_media_sha1(boot: fn -> :ok end)) end)
    assert_received %{hashed: hashed}
    assert hashed >= 1
    assert {:ok, %MediaFile{sha1: ^want}} = Media.get_file(file.id)
  end
end
