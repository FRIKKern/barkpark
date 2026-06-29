defmodule BarkparkCloud.Repo.Migrations.AddLifecycleToSubscriptions do
  use Ecto.Migration

  # subscription-billing: extend the subscriptions row past the binary `active`
  # gate into a real lifecycle. Four lifecycle/dunning columns mirror Coolify's
  # Subscription gate columns (stripe_past_due / stripe_cancel_at_period_end /
  # stripe_refunded_at + a period-end for the grace window), and the one-active
  # partial unique index is RELAXED to one-LIVE (active OR past_due) per team —
  # a past_due subscription is still the team's live subscription, so the "one
  # live row per team" guarantee must cover it. `canceled` rows stay out of the
  # index (Coolify retains the row on cancel — data retained, access revoked) so
  # a re-subscribe after a cancel inserts a fresh `active` row without colliding.
  def change do
    alter table(:subscriptions) do
      add :past_due, :boolean, null: false, default: false
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :current_period_end, :utc_datetime_usec
      add :canceled_at, :utc_datetime_usec
      # Reserved (deferred refund seam — Coolify RefundSubscription.php).
      add :refunded_at, :utc_datetime_usec
    end

    # Lifecycle webhooks key on the gateway customer/subscription id (NOT
    # metadata — a customer.subscription.deleted event carries no team metadata
    # we control), so index those lookups.
    create index(:subscriptions, [:gateway_customer_id])
    create index(:subscriptions, [:gateway_subscription_id])

    # Relax one-active → one-live (active OR past_due) per team. The original
    # `where: "status = 'active'"` predicate is carried on the drop so Ecto's
    # auto-reverse RECREATES the PARTIAL index (not a full unique on team_id, which
    # is semantically wrong and would fail against retained canceled+active rows).
    drop unique_index(:subscriptions, [:team_id],
           where: "status = 'active'",
           name: :subscriptions_one_active_per_team_idx
         )

    create unique_index(:subscriptions, [:team_id],
             where: "status IN ('active','past_due')",
             name: :subscriptions_one_live_per_team_idx
           )
  end
end
