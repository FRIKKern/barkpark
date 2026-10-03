defmodule Barkpark.Media.UploadExtensionSanitizeTest do
  @moduledoc """
  task-ce1105b1b95d421d — `Media.unique_filename/1` slugged the client BASENAME but kept
  `Path.extname/1` of the client filename verbatim. Quotes, spaces, `?`, `#`,
  `%`, control characters and Unicode bidi overrides (U+202E) rode straight
  into `media_files.path` and the public `/media/files/<path>` URL:

    * the stored name broke its own invariant — `put_blob/2`'s allowlist
      (`[A-Za-z0-9-][A-Za-z0-9._-]*` per segment) refuses it, so the blob could
      never be pushed to another instance;
    * `?` / `#` truncate the URL the API hands out (a dead asset link);
    * a U+202E in the extension renders the stored filename reversed in every
      UI that shows it (an `exe`-looking name).

  The extension is now kept only when it is `.` + 1–16 ASCII letters/digits;
  anything else is dropped (the sniffed MIME, not the extension, types the
  blob).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @blob_segment ~r/\A[A-Za-z0-9-][A-Za-z0-9._-]*\z/

  defp upload!(filename) do
    tmp = Path.join(System.tmp_dir!(), "extsan-#{System.unique_integer([:positive])}")
    File.write!(tmp, Base.decode64!(@png_b64))
    on_exit(fn -> File.rm(tmp) end)

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: tmp, filename: filename, content_type: "image/png"},
        "production"
      )

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), file.path)) end)
    file
  end

  for name <- [
        ~s(photo.p"g),
        "photo.p g",
        "photo.png?x",
        "photo.pn#g",
        "photo.p%2Fng",
        "photo." <> <<0x202E::utf8>> <> "gnp",
        "photo.png\r\n"
      ] do
    test "a hostile extension never reaches the stored path: #{inspect(name)}" do
      file = upload!(unquote(name))
      last = file.path |> String.split("/") |> List.last()

      assert last =~ @blob_segment,
             "stored name #{inspect(last)} breaks the blob-segment allowlist"
    end
  end

  test "CONTROL: an ordinary extension is kept, case and all" do
    assert upload!("Logo.PNG").path =~ ~r/logo-[0-9a-f]{8}\.PNG\z/
    assert upload!("cast.cast").path =~ ~r/cast-[0-9a-f]{8}\.cast\z/
  end
end
