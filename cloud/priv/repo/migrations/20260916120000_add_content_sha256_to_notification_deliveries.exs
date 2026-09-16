defmodule BarkparkCloud.Repo.Migrations.AddContentSha256ToNotificationDeliveries do
  use Ecto.Migration

  @moduledoc """
  dr-w34 — THE RECEIPT THAT CANNOT SAY WHAT IT CARRIED.

  `notification_deliveries` had THIRTEEN columns and not one of them is content:
  `id, team_id, recipient, event, channel, kind, status, attempts, last_error,
  http_status, carrier, inserted_at, updated_at`. (The filing row said TWELVE —
  it was written before `20260904120000_add_carrier_to_notification_deliveries`
  landed. The count moved; the defect did not.) A row proves an address, a
  transport verdict and a mechanism. It has never been able to prove a SENTENCE.

  The consequence was measured, not imagined: the only fleet digest ever
  delivered (2026-08-09T06:00:00Z) was produced by commit `026c5b1d7`, and the
  only way anyone could establish what that mail SAID was a prod git reflog. The
  fallback sinks are dead by construction too — `cloud-postfix-1` is recreated on
  every control-plane deploy (`dr-w26-bl-postfix-recreate-destroys-delivery-proof`).

  ## The decision: a HASH, not a body (dr-w34 c0)

  `add :content_sha256, :string` — the SHA-256 of the rendered subject + bodies
  of the message handed to the transport, hex, 64 characters. NOT the body
  itself, and this is a retention choice made deliberately:

    * A digest body NAMES THINGS — site names, environments, instance counts,
      per-team deploy volume. `deliver_fleet_digest/1`'s own tenancy ruling
      partitions that payload per team precisely so one team cannot read
      another's. Storing every rendered body in a table that the cross-team
      operator route `/v1/operator/deliveries` reads would re-open that exact
      disclosure from behind, in the one table designed to be read by admins.
    * A hash answers dr-w34's question — "can this receipt prove what it said?" —
      in full, because the claimant holds the render. Anyone asserting "the
      digest carried N" re-renders, hashes, and compares. A mismatch is a REFUTED
      claim; equality is proof the bytes that went to the transport are the bytes
      being quoted.
    * What a hash cannot do is reconstruct a body nobody kept. That is a real
      limit and it is the price of not retaining the content. It is stated here
      rather than discovered later.

  NOTHING NEW IS RETAINED IN PLAINTEXT. The column adds a 64-character digest
  per row and no readable prose, so this migration does not widen what Barkpark
  keeps about its users.

  ## Shape

  NULL-able, no default, no backfill, no index. On PG11+ that is a catalog-only,
  rewriteless `ADD COLUMN` — no existing row is read, rewritten or destroyed.

  NULL IS THE HONEST VALUE FOR EVERY EXISTING ROW and for every send this
  version does not fingerprint. It is not `unknown`-the-word (the precedent set
  by `carrier`) because there is nothing to distinguish: a row written before
  this column existed has no content to hash and no derivation could invent one
  (charter D362). `Delivery.content_proof_meaning/1` is the sentence a reader
  gets for the NULL, so the absence is legible rather than blank.

  ## down/0

  Drops the column. Reversible. The digests are not recoverable afterwards, but
  they are DERIVED from a render, so a re-run of the sends re-derives them; no
  other column depends on this one and no row is deleted in either direction.
  """

  def up do
    alter table(:notification_deliveries) do
      add :content_sha256, :string
    end
  end

  def down do
    alter table(:notification_deliveries) do
      remove :content_sha256
    end
  end
end
