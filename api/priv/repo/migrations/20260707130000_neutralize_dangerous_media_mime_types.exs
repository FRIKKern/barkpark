defmodule Barkpark.Repo.Migrations.NeutralizeDangerousMediaMimeTypes do
  use Ecto.Migration

  @moduledoc """
  Backfill for the stored-XSS hardening (PR #1025): before the ingest changeset
  learned to `neutralize_dangerous_mime`, uploads recorded their honest
  browser-executable `mime_type` (image/svg+xml, text/html, …). Every serve path
  reads `media_files.mime_type`, so those pre-existing rows stay exploitable even
  after the code fix. Rewrite them to `application/octet-stream` at the source so
  no serve path can hand a browser an executable type.

  Base type is compared case-insensitively with any `; charset=…` parameter
  stripped, matching `MediaFile.dangerous_mime?/1`. Irreversible by design — the
  original hostile mime is not worth preserving.
  """

  @dangerous ~w(
    image/svg+xml
    text/html
    application/xhtml+xml
    text/xml
    application/xml
    application/javascript
    text/javascript
    application/x-javascript
  )

  def up do
    list = Enum.map_join(@dangerous, ",", &"'#{&1}'")

    execute("""
    UPDATE media_files
       SET mime_type = 'application/octet-stream'
     WHERE lower(trim(split_part(mime_type, ';', 1))) IN (#{list})
    """)
  end

  def down do
    :ok
  end
end
