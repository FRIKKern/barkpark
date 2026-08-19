defmodule Barkpark.Media.RenditionsRaceProbeTest do
  @moduledoc """
  Mutation probe for the rendition delete-vs-generate race (asm-bl-rendition-
  delete-generate-race).

  RACE: `Media.delete_file` commits `Repo.delete` and then, in a deferred
  effect, `Renditions.delete_for_file` rm_rf's the rendition dir. A lazy
  `GET /media/renditions/:id/:preset` that loaded the file row BEFORE the delete
  can run its `mkdir_p! + render` AFTER that rm_rf, re-creating an orphan
  directory under a now-deleted media_files id (never served — the serve edge
  404s on the missing row — but wasted disk forever).

  GUARD: `Renditions.generate/6` re-queries `Media.get_file(file.id)` after a
  successful render. Row gone -> `File.rm_rf` the just-written dir and return
  `{:error, :parent_deleted}`, so the reap self-heals the orphan.

  This test reproduces the losing interleaving directly (persist -> generate ->
  delete row -> sweep dir like the deferred effect does -> generate again) and
  asserts no orphan survives. It REDS when the recheck is bypassed (render
  success reverts to a bare `{:ok, rel}`): the second generate would leave a
  surviving directory under the deleted id.
  """
  # async: false — toggles the global :image_backend Application env.
  use Barkpark.DataCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.MediaFile

  # Stub backend that always succeeds by writing a placeholder byte to `dest`.
  defmodule OkBackend do
    @behaviour Barkpark.Media.ImageBackend
    @impl true
    def render(_src, dest, _spec, _watermark) do
      File.write!(dest, "rendition")
      :ok
    end

    @impl true
    def available?, do: true
  end

  setup do
    original = Application.get_env(:barkpark, :image_backend)
    Application.put_env(:barkpark, :image_backend, OkBackend)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :image_backend)
        val -> Application.put_env(:barkpark, :image_backend, val)
      end
    end)

    :ok
  end

  defp persisted_png do
    token = Ecto.UUID.generate()
    rel = Path.join("test-blobs", "#{token}.png")
    abs = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "blob-bytes")

    {:ok, media_file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        mime_type: "image/png",
        path: rel,
        original_name: "x.png",
        filename: "x.png"
      })
      |> Repo.insert()

    on_exit(fn ->
      File.rm(abs)
      Renditions.delete_for_file(media_file.id)
    end)

    media_file
  end

  defp rendition_dir(%MediaFile{id: id}),
    do: Media.file_path(Path.join("_renditions", id))

  test "a generate that lands after the parent delete leaves no orphan directory" do
    png = persisted_png()

    # First generate (row still present): the recheck keeps it.
    assert {:ok, _rel} = Renditions.ensure(png, "thumb")
    assert File.dir?(rendition_dir(png))

    # The admin DELETE: Repo.delete commits, then the deferred effect sweeps the
    # rendition dir (delete_for_file). We replay both here.
    {:ok, _} = Repo.delete(png)
    Renditions.delete_for_file(png.id)
    refute File.dir?(rendition_dir(png))

    # The losing GET: a lazy generate lands AFTER the sweep. dest is gone, so
    # generate/6 re-renders — and the post-render recheck must reap it because
    # the parent row is gone.
    assert Renditions.ensure(png, "thumb") == {:error, :parent_deleted}

    # No orphan directory survives under the deleted id. This is the assertion
    # that REDS without the recheck (bare {:ok, rel} would leave the dir).
    refute File.dir?(rendition_dir(png))
  end

  test "a generate whose parent still exists is kept" do
    png = persisted_png()

    assert {:ok, rel} = Renditions.ensure(png, "thumb")
    assert File.exists?(Media.file_path(rel))
    assert File.dir?(rendition_dir(png))
  end
end
