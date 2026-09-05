defmodule Barkpark.Repo.Migrations.DropTokenFromShareLinks do
  use Ecto.Migration

  @moduledoc """
  RETIRE the plaintext ShareLink token column — the CONTRACT half of
  `arpss-w8-bl-share-link-raw-token-at-rest`. RULED by team-lead 2026-09-02:
  "RETIRE the plaintext token column. links.ex:20 stores both the hash and the
  cleartext, and the migration's LAN premise is void on a shared install."

  This reverses `20260609150000_add_token_to_share_links.exs`, whose tradeoff
  was argued from "a self-hosted/LAN context — anyone who can read this column
  can already read the shared content directly". That premise is exactly what a
  multi-tenant install voids: on a shared install the column's readers are not
  the shared content's readers, so the row was a LIVE CREDENTIAL at rest and
  every read path that serialised one handed out working access. Killing the
  column closes that disclosure CLASS structurally — a future tenancy
  regression on this surface cannot leak a credential that is no longer there.
  The raw token is now returned in ONE place only, the mint 201, exactly as
  `Barkpark.Auth.ApiToken` already works.

  THE DATA-LOSS CONSEQUENCE, stated plainly because it is user-visible:

    * Existing links KEEP WORKING. `Links.resolve/1` has always matched on
      `token_hash`, never on this column, and the hash and its unique index are
      untouched. No `/s/<token>` URL already in someone's hands stops serving.
    * Their URLs can no longer be RE-DISPLAYED. The P7 "Google-Docs-style,
      the popover shows it every time" affordance is gone: `GET /v1/shares/links`
      and the Studio popover can list, label and REVOKE a link, but they cannot
      reconstruct its URL. An operator who has lost the URL regenerates —
      revoke, mint again, copy the fresh link from the mint response.
    * The plaintext in this column is DROPPED and UNRECOVERABLE. That is the
      point of the change, not a side effect.

  DOWN IS LOSSY (intentional). The reversal re-adds a nullable `:string`
  column; every pre-existing row gets NULL, which the code reads as the honest
  "no URL to re-display" state. There is no backfill and none is possible —
  the plaintext cannot be derived from the SHA256 digest.

  Slow-migration law: the column is nullable, has no default, no index and no
  constraint (the unique index is on `token_hash`), so DROP COLUMN is a
  metadata-only catalog edit — instant, no table rewrite, no row migration.
  """

  def change do
    alter table(:share_links) do
      remove :token, :string
    end
  end
end
