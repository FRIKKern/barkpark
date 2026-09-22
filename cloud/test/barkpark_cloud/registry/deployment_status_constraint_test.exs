defmodule BarkparkCloud.Registry.DeploymentStatusConstraintTest do
  @moduledoc """
  deploy-reliability W16 backlog: `deployments.status` is a CLOSED vocabulary IN
  THE DATABASE, not merely in a changeset.

  Until the `deployments_status_check` migration, the only thing standing
  between the census and an unnamed status was
  `validate_inclusion(:status, @statuses)` on the Deployment changesets — and
  `status` is not in the create changeset's cast list, so any writer that
  reaches the column another way (`insert_all`, `update_all`, a repair script,
  psql) could seat a word `BarkparkCloud.DeployLedger.classify/1` has never
  seen. Its catch-all answers `nil`, which is the same answer a SUCCESSFUL
  deploy gets, so the row would enter every failure numerator as a silent
  success.

  These tests deliberately BYPASS the changeset — they issue raw SQL — because
  the claim under test is about the database, and a changeset test cannot
  distinguish "Ecto refused" from "Postgres refused".

  The drift arm is the one that keeps this honest over time: it reads the live
  constraint definition out of `pg_constraint` and compares it against
  `Deployment.statuses()`. Adding a status to the module attribute without
  cutting a follow-up migration reds it.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment

  @constraint "deployments_status_check"

  defp site_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # A raw INSERT, no changeset anywhere in the path — the only shape that can
  # prove WHO refused.
  defp raw_insert(site_id, status) do
    Repo.query(
      """
      INSERT INTO deployments (id, site_id, status, claim_epoch, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, 0, now(), now())
      """,
      [Ecto.UUID.bingenerate(), Ecto.UUID.dump!(site_id), status]
    )
  end

  describe "MUTATION PROOF — the database refuses an unknown status" do
    test "a raw insert of a status outside @statuses is rejected by Postgres" do
      site = site_fixture()

      assert {:error, %Postgrex.Error{postgres: pg}} = raw_insert(site.id, "succeeded")

      assert pg.code == :check_violation
      assert pg.constraint == @constraint

      # The whole point of the row: `succeeded` is a word the taxonomy has never
      # seen, and `classify/1` would have answered `nil` for it — the same answer
      # a `live` row gets. The database is now the thing that says no.
      assert BarkparkCloud.DeployLedger.classify(%{
               status: "succeeded",
               stage: nil,
               failure_reason: nil
             }) == nil
    end
  end

  describe "the constraint stays QUIET for the real vocabulary" do
    test "every status in Deployment.statuses() inserts through raw SQL" do
      # One site PER status: the partial unique index
      # `deployments_active_site_env_index` allows only one non-terminal
      # (queued|building|pushing) production deployment per site, so a single
      # site would fail this loop for a reason that has nothing to do with the
      # CHECK constraint under test.
      ids =
        for status <- Deployment.statuses() do
          site = site_fixture()

          assert {:ok, %{num_rows: 1}} = raw_insert(site.id, status),
                 "expected the database to accept the declared status #{inspect(status)}"

          site.id
        end

      assert length(Deployment.statuses()) ==
               Repo.one!(from(d in Deployment, where: d.site_id in ^ids, select: count()))
    end
  end

  describe "DRIFT GUARD — the constraint and @statuses are the same vocabulary" do
    test "pg_constraint's definition lists exactly Deployment.statuses()" do
      %{rows: [[definition]]} =
        Repo.query!(
          """
          SELECT pg_get_constraintdef(oid)
            FROM pg_constraint
           WHERE conrelid = 'deployments'::regclass
             AND conname = $1
          """,
          [@constraint]
        )

      in_db =
        Regex.scan(~r/'([a-z-]+)'/, definition)
        |> Enum.map(fn [_, value] -> value end)
        |> MapSet.new()

      assert in_db == MapSet.new(Deployment.statuses()),
             """
             deployments_status_check and Deployment.@statuses have drifted.

             constraint: #{inspect(Enum.sort(in_db))}
             @statuses:  #{inspect(Enum.sort(Deployment.statuses()))}

             Widening @statuses is only half the change — the database holds the
             other half. Cut a migration that drops and re-adds the constraint.
             """
    end

    test "the constraint is VALIDATED, not merely NOT VALID" do
      # A NOT VALID constraint guards new writes but certifies nothing about the
      # rows already there; the migration validates it, and a half-applied
      # migration would leave convalidated false.
      assert %{rows: [[true]]} =
               Repo.query!(
                 """
                 SELECT convalidated
                   FROM pg_constraint
                  WHERE conrelid = 'deployments'::regclass
                    AND conname = $1
                 """,
                 [@constraint]
               )
    end
  end
end
