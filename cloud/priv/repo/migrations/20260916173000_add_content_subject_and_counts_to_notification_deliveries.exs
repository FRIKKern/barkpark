defmodule BarkparkCloud.Repo.Migrations.AddContentSubjectAndCountsToNotificationDeliveries do
  use Ecto.Migration

  @moduledoc """
  dr-w29 — THE RECEIPT LEARNS THE SENTENCE, NOT THE ESSAY.

  `20260916120000_add_content_sha256_to_notification_deliveries` gave the row a
  FINGERPRINT of what a send carried. A fingerprint settles a dispute and cannot
  start one: it answers "is this the body?" and can never answer "what did it
  say?" to somebody who does not already hold a candidate render. dr-w29's
  criterion asks for the two narrowest things that CAN be read directly —

    * `content_subject` (text, null) — the `Subject:` header of the message
      handed to the transport, VERBATIM or not at all;
    * `content_counts` (jsonb, null) — the NUMERIC BLOCK, parsed back out of
      that rendered subject, integer values under a CLOSED key vocabulary.

  ## The retention decision, restated where a DBA will find it

  THE BODY IS STILL NOT STORED, and dr-w34's reason is unchanged: a digest body
  names site names, environments, per-window deploy volume and failure rates,
  and `notification_deliveries` is read cross-team by `GET
  /v1/operator/deliveries`. Storing bodies there re-opens from behind the
  disclosure `deliver_fleet_digest/1` partitions its payload per team to
  prevent.

  The subject clears the bar the body does not, and the difference is measured
  rather than asserted. `DigestEmail.subject/1` renders `"Your Barkpark
  instances — <n> current / <n> behind / <n> unmeasured / <n> paused"`: the
  recipient team's OWN rung counts and nothing else. No site name, no
  environment, no release string, no address, no other team's numbers. The
  counts already belong to the team whose `team_id` is stamped on the same row.

  Two fences bind this in the schema, not merely in the writer:

    * `content_subject` is stored VERBATIM OR ABSENT — over 512 bytes nothing is
      stored, because a truncated sentence reads as a whole one;
    * `content_counts` is refused by `Delivery.changeset/2` unless every key is
      in `Delivery.content_count_words/0` and every value is an integer. The
      column cannot become a prose sink by a future writer's forgetfulness.

  Audience is UNCHANGED. The two routes that read these rows already read them:
  `/v1/notifications/deliveries` (team-scoped; a non-admin member is further
  fenced to their own address) and `/v1/operator/deliveries` (platform operator,
  already cross-team for recipient addresses). Nothing here widens who can read
  a delivery row. Retention is the life of the row; there is no sweeper over
  this table today and that is stated rather than implied.

  ## Shape

  Both NULL-able, no default, no backfill, no index, no constraint. On PG11+
  that is a catalog-only rewriteless `ADD COLUMN` twice — no existing row is
  read, rewritten or destroyed. NULL is the honest value for every row written
  before this and for every send whose caller does not hand the receipt its
  rendered message, which today is every caller except
  `deliver_fleet_digest/1`. `Delivery.content_block_meaning/2` is the sentence a
  reader gets for the NULL, so the absence is legible rather than blank.

  ## down/0

  Drops both columns. Reversible and non-destructive in both directions: no
  other column depends on these, nothing is deleted, and the values are DERIVED
  from a render, so a re-run of the sends re-derives them.
  """

  def up do
    alter table(:notification_deliveries) do
      add :content_subject, :text
      add :content_counts, :map
    end
  end

  def down do
    alter table(:notification_deliveries) do
      remove :content_subject
      remove :content_counts
    end
  end
end
