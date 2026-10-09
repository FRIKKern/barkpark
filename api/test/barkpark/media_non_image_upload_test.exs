defmodule Barkpark.MediaNonImageUploadTest do
  @moduledoc """
  task-681df8da723386b8 — a `file` field's whole point is uploading a
  NON-image asset (a PDF attachment, a doc) to Barkpark media. Confirms the
  upload pipeline already accepts it: `media.ex`'s `allowed_mime_types`
  config defaults to `[]` (allow-all), so a PDF upload was never actually
  blocked server-side — the gap this task closes is schema/validation
  support for the `file` field type (see `validation_file_subfields_test.exs`
  and `schema_definition_test.exs`), not the upload door itself.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Media

  test "a non-image file (PDF) uploads and stores a real mime_type + size" do
    tmp_path =
      Path.join(System.tmp_dir!(), "attachment-#{System.unique_integer([:positive])}.pdf")

    # Minimal, but non-empty and PDF-sniffable: `%PDF-` is the magic header
    # Probe.sniff_mime/2 (and most mime sniffers) key on.
    File.write!(tmp_path, "%PDF-1.4\n%%EOF\n")
    on_exit(fn -> File.rm(tmp_path) end)

    upload = %Plug.Upload{path: tmp_path, filename: "report.pdf", content_type: "application/pdf"}

    assert {:ok, file} = Media.upload(upload, "production")
    assert file.mime_type == "application/pdf"
    assert file.size > 0
    assert file.original_name == "report.pdf"
  end
end
