defmodule BarkparkCloud.Repo.Migrations.AddCarrierToNotificationDeliveries do
  use Ecto.Migration

  @moduledoc """
  Wave 52 S3 (cloud-console-hardening), PART A. A `notification_deliveries` row
  reading "sent" could not answer "sent by WHAT". The stored columns are
  `[recipient, event, channel, kind, status, attempts, last_error, http_status]`
  — and `channel` is the EGRESS FAMILY (email vs discord vs slack), not the
  carrier: every email transport collapses to the literal `"email"`. So a team on
  `transport: "smtp"` whose `smtp_override/1` failed to decrypt rode the PLATFORM
  mailer and got a row byte-identical to a carried one.

  The carrier cannot be recovered after the fact, in either direction:

    * FROM THE WRITE PATH — `record_delivery/5` was not even PASSED the settings
      struct and `deliver_alert/2` returned only Swoosh's `{:ok, _} | {:error, _}`,
      so the carrier was destroyed one stack frame before the INSERT. This slice
      widens both.
    * FROM THE AUDIT LOG — `notifications.settings_changed` records
      `metadata: %{fields: Map.keys(conn.body_params)}`: FIELD NAMES ONLY, never
      values, by deliberate design. "Reconstruct the history from the audit log"
      is dead on arrival.

  ## The column

  `add :carrier, :string` — NULL-able, NO default. On PG11+ that is a
  catalog-only, rewriteless `ADD COLUMN`. NO new index: `maybe_delivery_eq/3`
  filters `event` / `channel` / `status` only, and the existing
  `(team_id, inserted_at)` index still serves the page.

  ## The backfill is an INVERTED ALLOWLIST, following 20260805210000

  `20260805210000_backfill_legacy_last_error.exs` established the doctrine:
  anything not PROVABLY a member of the closed vocabulary is legacy. Same rule
  here, in three arms:

      kind = 'transactional'  -> 'platform'   (PROVABLE FROM CODE: `Mailer`'s own
                                               moduledoc says transactional email
                                               always rides the platform, and
                                               `Transactional.deliver_test/1` is
                                               arity-1 with no override seam)
      channel <> 'email'      -> the channel   (a chat send's channel IS its carrier)
      everything else         -> 'unknown'     (a FIRST-CLASS vocabulary member,
                                               never NULL)

  ## What is DELIBERATELY not backfilled — and why (charter D362)

  A live census says every alert/email row belongs to a team currently on
  `transport = 'instance'`, which tempts a fourth arm writing `'platform'` for
  that whole population. It is NOT taken. There is no history table on
  `email_notification_settings`; exactly ONE settings row was ever updated after
  insert; and that one team owns the overwhelming majority of the corpus. "This
  team was never on SMTP" is therefore an inference from a single timestamp, not
  proof — and D362 forbids inventing a value the system cannot demonstrate. Those
  rows read `'unknown'`, which is TRUE, and `unknown` is rendered by the console
  as a sentence rather than a blank precisely so that truth is legible.

  No absolute row count is pinned anywhere in this file: the log grows a few
  hundred rows a day and nothing in `cloud/lib` or `cloud/priv/repo` reaps it, so
  a literal count would be stale before review.

  ## down/0

  Drops the column. The carrier values are not recoverable afterwards — they are
  DERIVED (from `kind` / `channel`) for legacy rows and MEASURED at the write seam
  for new ones, and nothing else on the row records them.
  """

  def up do
    alter table(:notification_deliveries) do
      add :carrier, :string
    end

    # `flush/0` so the UPDATE below sees the column in the same migration.
    flush()

    %Postgrex.Result{num_rows: filled} = repo().query!(backfill_sql(), [])

    IO.puts(
      "AddCarrierToNotificationDeliveries: classified #{filled} pre-existing delivery row(s) " <>
        "(transactional -> platform, non-email channel -> the channel, everything else -> unknown)."
    )
  end

  def down do
    alter table(:notification_deliveries) do
      remove :carrier
    end
  end

  @doc """
  The single backfill UPDATE. Public so a guard test can exercise the EXACT
  statement that ships rather than a paraphrase of it.

  `carrier IS NULL` scopes it to rows this migration has not already classified,
  so re-running it is a no-op rather than a rewrite.
  """
  @spec backfill_sql() :: String.t()
  def backfill_sql do
    """
    UPDATE notification_deliveries
       SET carrier = CASE
             WHEN kind = 'transactional' THEN 'platform'
             WHEN channel IS NOT NULL AND channel <> 'email' THEN channel
             ELSE 'unknown'
           END
     WHERE carrier IS NULL
    """
  end
end
