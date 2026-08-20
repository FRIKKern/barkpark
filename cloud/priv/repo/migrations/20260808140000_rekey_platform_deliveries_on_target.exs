defmodule BarkparkCloud.Repo.Migrations.RekeyPlatformDeliveriesOnTarget do
  use Ecto.Migration

  # deploy-reliability W24 (charter D422, which AMENDS D410 and supersedes it on
  # the key) — THE CROWN STOPS LOSING A ROW ON EVERY DEPLOY.
  #
  # ## The defect, measured twice
  #
  # W23 keyed this table on (sha, delivering_run_id, first_seen_at) and upserts
  # with ON CONFLICT DO NOTHING. `target` — a declared column with a two-value
  # vocabulary, "cp" and "instance" — is NOT in that key. deploy.yml's
  # `control-plane` and `instance` jobs are two jobs of ONE workflow run, so they
  # share GITHUB_RUN_ID. A writer posting both legs of one sha under one
  # run-scoped `first_seen_at` therefore DESTROYS the second leg and answers
  # HTTP 200. Against prod, one batch of two rows differing only in `target`
  # returned {"ok":true,"received":2,"recorded":1}. Posted as two separate calls
  # — the natural deploy.yml shape — the instance leg answers
  # {received: 1, recorded: 0}, byte-identical to a legitimate idempotent retry.
  # Nothing on the cloud side could tell the two apart.
  #
  # ## Why no choice of clock could have saved it
  #
  # `first_seen_at` is caller-supplied with no server default, so a writer must
  # pick one of two clocks and each loses differently. A RUN-STABLE stamp makes
  # retries idempotent and eats the instance leg. A PER-POST stamp saves both
  # legs and duplicates on retry (proven: the same delivery posted three times
  # with the stamp shifted by 1s and then by 1µs produced three rows). Only a key
  # that CONTAINS `target` and contains NO clock has both properties.
  #
  # ## The new key, and what it costs
  #
  # UNIQUE (sha, delivering_run_id, target).
  #
  # `target` STAYS NOT NULL, and that is load-bearing rather than tidy: Postgres
  # NULLs never compare equal, so a nullable column in a btree unique key
  # silently disables the constraint for every row that omits it — the collision
  # would come back as duplication instead of loss, which is not an improvement.
  #
  # `first_seen_at` stays NOT NULL as a PAYLOAD column. It is still the clock the
  # reader orders by; it is simply no longer part of the identity.
  #
  # THE NARROWING, SAID OUT LOUD rather than pretended away: a genuinely SECOND
  # delivery of the same sha, by the same run, to the same target — a blue/green
  # re-flip inside one run — now folds into the first row. That is correct: same
  # sha + same run + same target IS a retry, and the run is the unit of delivery.
  #
  # D385's load-bearing guarantee SURVIVES untouched: the same sha delivered by
  # TWO runs at the same first sighting still keeps BOTH rows, because those two
  # deliveries differ on `delivering_run_id`. That is the ~36% carried-sha
  # population this table exists to make visible.
  #
  # ## Expand-safe, with one window named honestly
  #
  # `cloud/Dockerfile` runs migrations when the IDLE slot boots WHILE THE OLD
  # SLOT STILL SERVES, so this runs against a schema the currently-serving
  # release is still reading. Dropping `carried`'s NOT NULL, and adding three
  # nullable columns, are both invisible to the old slot. Dropping the old unique
  # index is NOT: the old slot's `insert_all` infers its ON CONFLICT from
  # (sha, delivering_run_id, first_seen_at) and, between this DROP and the slot
  # flip, a post to the old slot would raise instead of upserting. That window is
  # accepted because no automated writer exists yet — the deploy-side writer is
  # dr-w24-s7 and lands AFTER this — and because the recorder's failure mode is a
  # typed, logged refusal the caller retries, never a silent success.
  #
  # ## The residue
  #
  # A W24 verifier posted an all-zeros probe row to PROD deliberately, to prove
  # the collision on the live control plane. It is deleted below: the first
  # `bp cloud deliveries` output a human ever sees must not open with a fake
  # delivery of the null commit.
  def up do
    # The probe residue, deleted before the CREATE so it can never become the row
    # that makes the new unique index fail to build.
    execute """
    DELETE FROM platform_deliveries
    WHERE sha = '0000000000000000000000000000000000000000'
      AND delivering_run_id = '0'
    """

    drop_if_exists index(:platform_deliveries, [:sha, :delivering_run_id, :first_seen_at],
                     name: :platform_deliveries_sha_run_seen_index
                   )

    create unique_index(:platform_deliveries, [:sha, :delivering_run_id, :target],
             name: :platform_deliveries_sha_run_target_index
           )

    # `carried` must be able to say UNKNOWN. It shipped NOT NULL DEFAULT false,
    # so a writer that simply does not know whether a sha rode another sha's run
    # — every box-side writer — recorded measured-FALSE, which is exactly the
    # carried-vs-caused lie this epic exists to end. NULL now means "nobody
    # measured this"; false keeps meaning "measured, and it had its own run".
    execute "ALTER TABLE platform_deliveries ALTER COLUMN carried DROP NOT NULL",
            "ALTER TABLE platform_deliveries ALTER COLUMN carried SET NOT NULL"

    execute "ALTER TABLE platform_deliveries ALTER COLUMN carried DROP DEFAULT",
            "ALTER TABLE platform_deliveries ALTER COLUMN carried SET DEFAULT false"

    alter table(:platform_deliveries) do
      # The queue, split into the three intervals an operator actually acts on:
      # how long the run waited on ITSELF (concurrency against a sibling run),
      # how long it waited to be PICKED UP by a runner, and how long it sat
      # STALLED after pickup. All three NULLABLE, carrying the existing law of
      # this table verbatim: if the producing query fails, these read UNKNOWN,
      # never 0 — a zero here would read as "the queue was instant", which is
      # the most flattering possible lie about a deploy nobody measured.
      add :queued_self_seconds, :integer
      add :queued_pickup_seconds, :integer
      add :queued_stall_seconds, :integer
    end
  end

  def down do
    alter table(:platform_deliveries) do
      remove :queued_stall_seconds
      remove :queued_pickup_seconds
      remove :queued_self_seconds
    end

    # The rollback cannot invent a measurement, so unknown becomes false — the
    # same flattening this migration exists to undo. Rolling back is therefore a
    # LOSSY operation on already-written rows, said here rather than discovered.
    execute "UPDATE platform_deliveries SET carried = false WHERE carried IS NULL"
    execute "ALTER TABLE platform_deliveries ALTER COLUMN carried SET DEFAULT false"
    execute "ALTER TABLE platform_deliveries ALTER COLUMN carried SET NOT NULL"

    drop_if_exists index(:platform_deliveries, [:sha, :delivering_run_id, :target],
                     name: :platform_deliveries_sha_run_target_index
                   )

    create unique_index(:platform_deliveries, [:sha, :delivering_run_id, :first_seen_at],
             name: :platform_deliveries_sha_run_seen_index
           )
  end
end
