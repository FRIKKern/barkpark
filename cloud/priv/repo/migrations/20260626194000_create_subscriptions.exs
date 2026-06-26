defmodule BarkparkCloud.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  # A Team's billing subscription (cloud-5) — the persisted result of subscribing
  # through the configured Billing gateway. Belongs to a Team. `plan` is one of
  # the roadmap's five tiers; `status` is active/canceled/past_due. The
  # `gateway_*_id` columns hold the gateway's OPAQUE references (deterministic
  # `*_stub_*` ids under StubGateway, real Stripe `cus_*` / `sub_*` ids once a
  # human wires live keys in cloud-17) — never card data. A partial unique index
  # enforces at-most-one ACTIVE subscription per team.
  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :plan, :string, null: false
      add :status, :string, null: false, default: "active"
      add :gateway_customer_id, :string
      add :gateway_subscription_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subscriptions, [:team_id])

    # At most one ACTIVE subscription per team — `active_subscription/1` reads it.
    create unique_index(:subscriptions, [:team_id],
             where: "status = 'active'",
             name: :subscriptions_one_active_per_team_idx
           )
  end
end
