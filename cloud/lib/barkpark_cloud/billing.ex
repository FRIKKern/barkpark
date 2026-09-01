defmodule BarkparkCloud.Billing do
  @moduledoc """
  The billing context — the pay-once go-live path, built and tested at €0 spend.

  Every payment side effect routes through a config-selected
  `BarkparkCloud.Billing.Gateway`: `StubGateway` in dev/test (in-memory,
  deterministic, no network), the real Stripe gateway in prod (its HTTP transport
  is wired; live keys + price ids remain the cloud-17 human gate). The context
  never names a provider — it calls
  `gateway()` and the behaviour. This is the same config-driven-adapter seam as
  `Registry.Vault`'s key source.

  Scope is deliberately narrow (YAGNI). What ships:

    * `checkout/2`           — resolve a plan's price id and open a hosted
      Checkout Session so the customer pays in a browser. "free"/unknown/unpriced
      → `{:error, :plan_invalid}`.
    * `handle_webhook/2`     — verify a Stripe-signed webhook over the RAW body
      and dispatch it: an ACTIVATING event marks the team's subscription active;
      a LIFECYCLE event (payment failed / sub deleted / invoice paid) drives the
      status state machine past `active` (→ `past_due` / `canceled` / recovery).
      Idempotent; a forged event grants nothing.
    * `subscribe/2`          — create a gateway customer, open a subscription on
      a plan, and PERSIST a `Subscription` row in one go.
    * `charge_go_live/2`     — the one-off pay-once charge (legacy; the launch
      gate now requires ENTITLEMENT instead).
    * `live_subscription/1`  — a Team's live subscription (active OR past_due).
    * `entitled?/1`          — is the team entitled to managed resources right
      now? Active, or past_due within its grace window.
    * `active_subscription/1` — a Team's current active subscription, or nil.
    * `mark_past_due/1` · `cancel_subscription/1` · `recover_subscription/1` —
      the status transitions the webhook lifecycle drives. The cancel transition
      SUSPENDS the team's managed instances; recovery RESUMES them.
    * `billing_portal_url/2` — open a Stripe Customer Portal session for a team.
    * `request_cancel/2`     — customer-initiated cancel (grace or immediate).

  NOT here (still deferred): invoices, proration / quantity changes, refunds, and
  per-tier quotas. The nightly reconciliation sweep is NOT among them — it is
  decided against (charter D657) — grace is enforced synchronously at request time
  by `entitled?/1`; nothing needs to wake up for it to end. Nor was it ever blocked
  on a missing substrate: Oban is supervised in `application.ex` and 17 modules
  under `cloud/lib` already `use Oban.Worker`.

  The plan tiers (`free` / `supporter` / `support_plus`) are a `validate_inclusion`
  list on `Subscription`, not a pricing engine — real prices/price-ids are the
  human task cloud-17.
  """
  import Ecto.Query, warn: false
  require Logger

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.{Events, Registry}

  # The currency the control plane bills in. Single value (not a per-team
  # setting) — multi-currency is out of scope (YAGNI).
  @currency "usd"

  # The dunning grace window: how long a `past_due` team stays entitled after a
  # failed payment. What elapse costs the team is ISOLATION, not a stop: it flips
  # `entitled?/1`, whose only lib call site outside this module is `router.ex`'s
  # `entitled_or_trial_started?/1` go-live gate — so the team cannot LAUNCH A NEW
  # INSTANCE. Nothing running stops, nothing is deleted, the deploy pipeline is
  # untouched, and Hetzner and Stripe keep billing. Anchored deterministically at
  # `mark_past_due` time (the Stripe Invoice object carries no period end), so the
  # grace is payload-shape-independent (Coolify keeps a past_due team running ~3 days).
  @grace_days 3

  # The self-serve free-trial window (dwb-13): a team is granted a `trial`
  # subscription entitled for this many days, after which it lapses (entitlement
  # enforced against `current_period_end`) and the user must subscribe to a paid
  # tier. No gateway/charge — €0, no card. The default is 14 days; runtime.exs
  # overrides it from the `TRIAL_DAYS` env (read at call time via `trial_days/0`,
  # so ops can retune without a code change — mirrors `prices` / `limits`).
  @default_trial_days 14

  # Plans that NEVER open a checkout session: `free` is the no-charge signup
  # tier and `trial` is granted with no card. Subtracted from the schema's plan
  # enumeration to derive `checkout_plans/0` — so a new tier added to
  # `Subscription` is checkout-eligible by default rather than silently absent.
  @never_checkout_plans ~w(free trial)

  @doc """
  The configured billing gateway module. Resolved at call time (not compile
  time) so runtime.exs's prod override is honoured — mirrors `Registry.Vault`'s
  config-at-call-time key resolution. Defaults to `StubGateway` so a missing
  config never silently routes money anywhere.
  """
  @spec gateway() :: module()
  def gateway do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:gateway, BarkparkCloud.Billing.StubGateway)
  end

  # The Registry module `reconcile_plan_limit/1` writes through. Resolved at
  # call time and swappable ONLY via the same `Application.get_env(:barkpark_cloud,
  # __MODULE__, [])` keyword this file already uses for `gateway/0` — real code
  # always gets the real `Registry`; the `:registry` key exists purely so a test
  # can force ONE barkpark's suspend/unsuspend to fail and prove the per-row
  # isolation below actually holds (see billing_reconcile_isolation_test.exs).
  @spec registry() :: module()
  defp registry do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:registry, Registry)
  end

  @doc "The currency the control plane bills in (ISO-4217, lower-case)."
  @spec currency() :: String.t()
  def currency, do: @currency

  @doc """
  Open a hosted Checkout Session for `team` on `plan` — the customer-initiated
  subscription path (the browser pays). Resolves the plan's gateway-side price
  id from config, then calls the gateway's `create_checkout_session/3` with the
  team's id (the AUTHED team — the caller passes a `%Team{}`/id it already
  authorized, never a client value), the plan, and the resolved price id.

  Returns `{:ok, checkout_url}` or `{:error, :plan_invalid}` for "free", an
  unknown plan, or a plan with no configured price (`free` needs no checkout;
  an unpriced plan can't open one). The actual subscription is marked active
  later, when Stripe posts a signed `checkout.session.completed` webhook that
  `subscribe/2` lands.

  PRE-FLIGHT REFUSAL (D553). A resolved price is NOT enough to open a session.
  With prices wired but no webhook signing secret, `checkout_capability/0` is
  `:unverifiable`: a REAL hosted session opens and the card is charged, while
  `StripeGateway.verify_webhook/2` returns `{:error, :no_secret}` forever, so the
  activation event can never land and the customer pays for nothing. This
  function therefore consults `checkout_capability/0` and returns
  `{:error, :billing_not_configured}` BEFORE `create_checkout_session/3` is ever
  called. The check sits AFTER the price resolution so an unknown/"free" plan
  keeps its existing `:plan_invalid` answer — the new refusal fires exactly in
  the hole where a price resolves but the money could never be honoured.
  """
  @spec checkout(Team.t() | binary(), Subscription.plan() | atom() | String.t()) ::
          {:ok, BarkparkCloud.Billing.Gateway.checkout_url()}
          | {:error, :plan_invalid | :billing_not_configured | term}
  def checkout(team, plan) do
    plan = to_string(plan)

    case price_id(plan) do
      nil ->
        {:error, :plan_invalid}

      price_id ->
        if checkout_capability() == :available do
          gateway().create_checkout_session(team_id(team), plan, price_id: price_id)
        else
          {:error, :billing_not_configured}
        end
    end
  end

  @doc """
  The configured gateway-side price id for `plan`, or nil. "free" and any plan
  without a configured price resolve to nil (no checkout). Read at call time so
  runtime.exs's env-fed prices win.
  """
  @spec price_id(String.t()) :: String.t() | nil
  def price_id(plan) when is_binary(plan) do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:prices, %{})
    |> Map.get(plan)
  end

  ## Usage limits / quotas (usage-limits-quotas) ------------------------------
  #
  # The QUOTA half of go-live: how many managed Barkpark instances a team may
  # hold under its plan — Coolify's `Team::serverLimit`/`serverLimitReached`. The
  # ENTITLEMENT half (active-or-not, the 402 gate) is separate and already exists.
  # The ceiling is a per-plan config map (mirroring `prices`); the count is a live
  # `count()` (no denormalised counter, exactly like Coolify). The RECONCILER
  # (`reconcile_plan_limit/1`) enforces a lowered ceiling reversibly, keyed on the
  # `"quota_exceeded"` suspension reason so it never collides with the billing
  # suspension axis (`"billing_lapsed"` / `"billing_past_due"`) that main's
  # subscription lifecycle owns.

  # Fallback ceilings used only when no `:limits` map is configured. Prod values
  # come from runtime.exs; config.exs sets the dev/test defaults.
  @default_limits %{
    "free" => 1,
    "trial" => 1,
    "supporter" => 3,
    "support_plus" => 10,
    "forever" => 1_000_000,
    "none" => 0
  }

  # The suspension reason the quota reconciler stamps. Kept DISTINCT from the
  # billing-lapse reasons so a quota reconcile can never restore a box a billing
  # lapse suspended, and vice-versa (the two enforcement axes never cross-talk).
  @quota_suspended_reason "quota_exceeded"

  @doc "The suspension reason the quota reconciler stamps. For the registry/tests."
  @spec quota_suspended_reason() :: String.t()
  def quota_suspended_reason, do: @quota_suspended_reason

  @doc """
  The maximum number of managed Barkpark instances `team` may hold under its
  current plan — the quota half of go-live (Coolify's `Team::serverLimit`).

  Resolves the team's ACTIVE subscription plan against the configured `:limits`
  map. A team with NO active subscription resolves to the `"none"` ceiling (0) —
  it is already 402-blocked at go-live, and 0 keeps the internal register path
  honest. Read at call time (not a module attr) so runtime.exs's prod numbers win.
  """
  @spec barkpark_limit(Team.t() | binary()) :: non_neg_integer()
  def barkpark_limit(team) do
    case active_subscription(team) do
      %Subscription{plan: plan} -> Map.get(limits(), plan, Map.get(limits(), "none", 0))
      nil -> Map.get(limits(), "none", 0)
    end
  end

  @doc """
  Whether `team` is AT or OVER its instance ceiling — the create-time QUOTA guard
  for a MAIN (Coolify's `serverLimitReached`, inclusive `>=`). Counts ALL of the
  team's instance rows, INCLUDING reconciler-suspended ones (a suspended overflow
  box is still "held", re-enabled on re-upgrade) AND fleet supports, so a
  downgraded team can never create around its own suspended overflow. `>=` because
  at-limit blocks the NEXT create.

  This guard fires on the MAIN create path (`Registry.register_barkpark/2`). It is
  NOT consulted for fleet SUPPORT inserts: PDF-D86 makes supports quota-exempt, so
  `Registry.register_support_barkpark/2` inserts directly and never calls this
  function. A support therefore rides past a saturated ceiling, while a MAIN at
  the ceiling is still blocked — the exception is role-scoped to support inserts
  and lives in exactly one place (that function).

  The quota gate applies ONLY to a team with an ACTIVE subscription — it is the
  per-PLAN ceiling. A team with no active subscription is NOT "at a quota of 0";
  it is handled by the separate ENTITLEMENT gate (the 402 `no_active_subscription`
  in `go_live/1`), exactly as Coolify keeps the per-plan limit distinct from the
  subscription-active check. So this returns `false` for an unsubscribed team —
  the 402 is what stops it.
  """
  @spec barkpark_limit_reached?(Team.t() | binary()) :: boolean()
  def barkpark_limit_reached?(team) do
    case active_subscription(team) do
      %Subscription{} = sub ->
        Registry.count_barkparks(team) >= Map.get(limits(), sub.plan, 0)

      nil ->
        false
    end
  end

  @doc """
  The configured per-plan managed-instance ceilings, read at call time. Falls
  back to `@default_limits` when nothing is configured.

  PUBLIC because the ceiling is mirrored OUTSIDE this module: the Cloud console
  re-declares the same numerals in `app.js`'s `PLAN_CATALOG`, where they drive
  the tier cards' feature copy. `cch-w49-s3`'s cross-layer mirror guard
  (`test/barkpark_cloud/billing_client_mirror_test.exs`) calls this from the
  booted BEAM and compares it against the console's own exported constant, so
  the two sides cannot drift silently. Read-only; no caller mutates the map.
  """
  @spec limits() :: %{optional(String.t()) => non_neg_integer()}
  def limits do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:limits, @default_limits)
  end

  @doc """
  Reconcile `team`'s live instances against its current plan ceiling — Coolify's
  `ServerLimitCheckJob`, reversibly:

    * OVER limit → suspend the `(count - limit)` NEWEST live instances (reason
      `"quota_exceeded"`) and emit a `barkpark.suspended` event per box
      (newest-first, so the earliest-bought boxes survive — Coolify's
      `sortByDesc('created_at')`);
    * AT/UNDER  → re-enable every QUOTA-suspended instance (auto-recovery on
      re-upgrade) oldest-first, emitting `barkpark.restored`.

  Keys STRICTLY on the `"quota_exceeded"` reason: a box suspended by a BILLING
  lapse (`"billing_lapsed"` / `"billing_past_due"`) is NEVER restored here — the
  two enforcement axes are independent. Returns `%{suspended: n, restored: m}` —
  counts reflect only the rows that actually transitioned; a single row whose
  suspend/unsuspend changeset fails is logged and skipped rather than sinking
  the whole team's batch (see `suspend_one/2` / `unsuspend_one/1`).
  Idempotent; NEVER deletes data (suspend is a reversible flag).

  Delivered as a pure context function so it is callable SYNCHRONOUSLY off the
  plan-transition path with no new dependency (a slow suspend is a rare, small
  fleet). The candidate's Oban worker wrapper is deferred.
  """
  @spec reconcile_plan_limit(Team.t() | binary()) :: %{
          suspended: non_neg_integer(),
          restored: non_neg_integer()
        }
  def reconcile_plan_limit(team) do
    tid = team_id(team)
    limit = barkpark_limit(tid)

    # "Live" = not currently suspended by EITHER axis. A billing-lapsed box is
    # already suspended, so it isn't a candidate to suspend and doesn't inflate
    # the overflow — but it also can't be restored here (wrong reason).
    live = Registry.list_barkparks(tid) |> Enum.reject(& &1.suspended)
    overflow = length(live) - limit

    if overflow > 0 do
      suspended =
        live
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> Enum.take(overflow)
        |> Enum.map(&suspend_one(&1, tid))
        |> Enum.reject(&is_nil/1)

      %{suspended: length(suspended), restored: 0}
    else
      restored =
        tid
        |> Registry.list_quota_suspended_barkparks()
        |> Enum.map(&unsuspend_one(&1, tid))
        |> Enum.reject(&is_nil/1)

      %{suspended: 0, restored: length(restored)}
    end
  end

  # Suspend ONE barkpark for the quota reconcile. `{:ok, _}` broadcasts and
  # returns the updated row; `{:error, changeset}` — a hard-match here would
  # MatchError and sink the WHOLE team's batch on one bad row — is logged and
  # skipped (returns nil, filtered by the caller), mirroring the
  # log-don't-crash-continue intent of `Health.StalenessWorker.evaluate/1`.
  defp suspend_one(bp, tid) do
    case registry().suspend_barkpark(bp, @quota_suspended_reason) do
      {:ok, updated} ->
        Events.broadcast(tid, "barkpark.suspended", %{barkpark_id: updated.id})
        updated

      {:error, changeset} ->
        Logger.error(
          "Billing.reconcile_plan_limit: suspend failed for barkpark #{bp.id}: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  # Unsuspend ONE barkpark for the quota reconcile. Same isolation as
  # `suspend_one/2` — one row's changeset failure is logged and skipped, never
  # crashes the restore batch.
  defp unsuspend_one(bp, tid) do
    case registry().unsuspend_barkpark(bp) do
      {:ok, updated} ->
        Events.broadcast(tid, "barkpark.restored", %{barkpark_id: updated.id})
        updated

      {:error, changeset} ->
        Logger.error(
          "Billing.reconcile_plan_limit: unsuspend failed for barkpark #{bp.id}: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  @doc """
  Is the billing gateway fully configured to actually take money right now?

  A PROJECTION of `checkout_capability/0` (`== :available`) — the two cannot
  drift because there is only one computation. True only when at least one plan
  price is wired (`STRIPE_PRICE_*`) AND a webhook signing secret is set
  (`STRIPE_WEBHOOK_SECRET`); always true for the in-memory `StubGateway`, which
  needs no external config. The router uses this to surface an
  operator-actionable `billing_not_configured` instead of a misleading
  `plan_invalid` (BILL-2). Callers that need to know WHICH way it fails — a dead
  button vs. a chargeable-but-unactivatable session — want the enum, not this.
  """
  @spec configured?() :: boolean()
  def configured?, do: checkout_capability() == :available

  @doc """
  The plans a customer could actually be sent to checkout for RIGHT NOW — the
  checkout-eligible universe filtered by whether each plan's gateway price id
  resolves at this moment.

  DERIVED, never declared: the universe is the `Subscription` plan enumeration
  minus the plans that never open a checkout (`free` is the no-charge signup
  tier; `trial` is granted with no card), and membership is decided by CALLING
  `price_id/1`. So a half-wired deploy (only `supporter` priced) reports exactly
  `["supporter"]` instead of a constant that claims both paid tiers — the case a
  `configured?` boolean structurally cannot express, and the case where the
  console otherwise blames the customer's plan choice for the deploy's gap.
  """
  @spec priced_plans() :: [String.t()]
  def priced_plans do
    Enum.filter(checkout_plans(), &is_binary(price_id(&1)))
  end

  @doc """
  The checkout-eligible plan universe: every `Subscription` plan except the ones
  that never open a checkout session. Server-owned — nothing client-supplied
  reaches it — and derived from the schema's enumeration so a new tier is in
  scope the moment it is added there.
  """
  @spec checkout_plans() :: [String.t()]
  def checkout_plans, do: Subscription.plans() -- @never_checkout_plans

  @doc """
  Can this deploy actually take money right now, and if not, HOW does it fail?

  A three-value answer because the two failure modes are not the same event:

    * `:unconfigured` — no paid plan has a price id, so `checkout/2` can only
      ever refuse. Harmless: the button is dead, no card is touched.
    * `:unverifiable` — at least one plan IS priced but there is no webhook
      signing secret. This is the DANGEROUS one: a real hosted Checkout Session
      opens, the customer's card IS charged, and `verify_webhook/2` returns
      `{:error, :no_secret}` forever, so the activation event can never be
      trusted and the subscription can never go active. `checkout/2` refuses
      pre-flight (see its docs) precisely so this state cannot move money.
    * `:available` — priced and verifiable; checkout may proceed.

  For the in-memory `StubGateway` (dev/test) this is always `:available` — it
  needs no external config and moves no money.

  `configured?/0` is a PROJECTION of this function (`== :available`), so the
  boolean and the enum can never drift apart.
  """
  @spec checkout_capability() :: :available | :unconfigured | :unverifiable
  def checkout_capability do
    case gateway() do
      BarkparkCloud.Billing.StripeGateway ->
        cond do
          priced_plans() == [] -> :unconfigured
          not webhook_secret?() -> :unverifiable
          true -> :available
        end

      _ ->
        :available
    end
  end

  # Is a non-empty webhook signing secret wired? Read at call time, same seam
  # `StripeGateway.verify_webhook/2` reads — if this is false that function
  # returns {:error, :no_secret} for every event, forever.
  @spec webhook_secret?() :: boolean()
  defp webhook_secret? do
    secret =
      Application.get_env(:barkpark_cloud, BarkparkCloud.Billing.StripeGateway, [])
      |> Keyword.get(:webhook_secret)

    is_binary(secret) and secret != ""
  end

  @doc """
  Subscribe `team` to `plan`: create a customer with the gateway, open a
  subscription on the plan, then persist a `Subscription` row carrying the
  gateway's customer/subscription ids and an `active` status.

  Returns `{:ok, %Subscription{}}` or `{:error, reason}` — a gateway failure
  short-circuits before anything is persisted, and a changeset failure (e.g. an
  invalid plan, or a second active subscription for the team) returns the
  changeset.
  """
  @spec subscribe(Team.t() | binary(), Subscription.plan() | atom() | String.t()) ::
          {:ok, Subscription.t()} | {:error, term}
  def subscribe(team, plan) do
    plan = to_string(plan)
    gw = gateway()

    with {:ok, customer_id} <- gw.create_customer(%{team_id: team_id(team)}),
         {:ok, subscription_id} <- gw.create_subscription(customer_id, plan) do
      %Subscription{}
      |> Subscription.changeset(%{
        team_id: team_id(team),
        plan: plan,
        status: "active",
        gateway_customer_id: customer_id,
        gateway_subscription_id: subscription_id
      })
      |> Repo.insert()
    end
  end

  @doc """
  Charge `team` `amount_cents` (minor units) for going live — the pay-once
  go-live charge. Creates a customer for the team and charges it through the
  gateway. Returns `{:ok, charge_id}` or `{:error, reason}`. Does not persist a
  row (a go-live charge is a one-off event, not a subscription).
  """
  @spec charge_go_live(Team.t() | binary(), pos_integer()) ::
          {:ok, BarkparkCloud.Billing.Gateway.charge_id()} | {:error, term}
  def charge_go_live(team, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    gw = gateway()
    tid = team_id(team)

    with {:ok, customer_id} <- gw.create_customer(%{team_id: tid}) do
      gw.charge(customer_id, amount_cents, @currency, %{team_id: tid, reason: "go_live"})
    end
  end

  @doc """
  Verify an inbound billing webhook through the configured gateway. Thin
  pass-through to `Gateway.verify_webhook/2` — verification only, no event
  dispatch (YAGNI).
  """
  @spec verify_webhook(binary(), binary()) :: {:ok, term} | {:error, term}
  def verify_webhook(payload, signature) do
    gateway().verify_webhook(payload, signature)
  end

  # The webhook event types that activate a subscription. checkout.session
  # .completed is the primary signal (the customer finished the hosted
  # checkout); the subscription.created/updated pair is honoured too so a status
  # flip to active is not missed.
  @activating_event_types ~w(
    checkout.session.completed
    customer.subscription.created
    customer.subscription.updated
  )

  # The webhook event types that drive the lifecycle past `active`. Keyed on the
  # gateway customer id (NOT metadata — a deleted/failed event carries no team
  # metadata we control). `customer.subscription.updated` is in BOTH sets: an
  # update flipping status TO active activates (handled by the activating path);
  # an update flipping to canceled/unpaid lapses (handled here).
  @lifecycle_event_types ~w(
    invoice.payment_failed
    invoice.paid
    customer.subscription.deleted
    customer.subscription.updated
  )

  @doc "The webhook event types that mark a subscription active. For the router/tests."
  @spec activating_event_types() :: [String.t()]
  def activating_event_types, do: @activating_event_types

  @doc "The webhook event types that drive the lifecycle past `active`. For tests."
  @spec lifecycle_event_types() :: [String.t()]
  def lifecycle_event_types, do: @lifecycle_event_types

  @doc """
  Handle an inbound billing webhook end to end: verify the `raw_body` against
  its `signature` through the gateway, and — on a VALID event whose type
  activates a subscription — read `team_id`+`plan` from the (Stripe-SIGNED)
  event metadata and mark that team's subscription active.

  CRITICAL: `raw_body` MUST be the unparsed request bytes — the signature is
  computed over them. A forged or unsigned event fails verification and
  `{:error, :invalid_signature}` is returned, granting NOTHING.

  Idempotent: a repeated event for a team that already has an active
  subscription is a no-op success (`{:ok, :already_active}`) — it never inserts
  a second row (the one-active-per-team index is the backstop) and never errors.

  Returns:

    * `{:ok, %Subscription{}}`   — a new active subscription was landed, OR the
      FIRST `active → past_due` transition (the router emails the team once).
    * `{:ok, :already_active}`   — the team was already subscribed (idempotent).
    * `{:ok, :already_past_due}` — a repeat dunning event on an already-past_due
      sub (a webhook redelivery); state stays past_due, the router skips the
      duplicate email.
    * `{:ok, :ignored}`          — a valid event of a non-activating type.
    * `{:error, :invalid_signature}` — a bad/missing signature (grants nothing).
    * `{:error, term}`           — a malformed event or a persistence failure.
  """
  @spec handle_webhook(binary(), binary()) ::
          {:ok, Subscription.t() | :already_active | :already_past_due | :ignored}
          | {:error, term}
  def handle_webhook(raw_body, signature) when is_binary(raw_body) and is_binary(signature) do
    with {:ok, event} <- verify_webhook(raw_body, signature) do
      dispatch_event(event, raw_body)
    end
  end

  # The gateway returns its decoded event. The StripeGateway decodes the raw JSON
  # straight into the Stripe event map; the StubGateway returns a wrapper
  # (`%{"verified" => true, "payload" => raw}`) — in that case the real event is
  # the raw JSON body we already hold, so parse it here. Either way we end up
  # with the Stripe-shaped event map and dispatch on its type.
  defp dispatch_event(%{"verified" => true} = _stub_wrapper, raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = event} -> activate_from_event(event)
      _ -> {:error, :invalid_payload}
    end
  end

  defp dispatch_event(%{} = event, _raw_body), do: activate_from_event(event)

  # Dispatch a verified event. An ACTIVATING event in its active state reads the
  # SIGNED metadata and subscribes; a LIFECYCLE event drives the state machine
  # past `active` keyed on the gateway customer id. A `customer.subscription.updated`
  # is checked against the activating path FIRST (active-flip wins); if it's not
  # an active flip it falls through to the lifecycle path (which owns the
  # canceled/unpaid transitions).
  defp activate_from_event(%{"type" => type} = event) do
    object = get_in(event, ["data", "object"]) || %{}

    cond do
      # customer.subscription.updated is dual-purpose (it can be an active-flip
      # OR a canceled/recovery transition), so it gets its own resolver that
      # disambiguates on the customer's CURRENT live row.
      type == "customer.subscription.updated" ->
        handle_subscription_updated(event, object)

      type in @activating_event_types and active_status?(type, object) ->
        activate_from_metadata(object)

      type in @lifecycle_event_types ->
        handle_lifecycle(event)

      true ->
        {:ok, :ignored}
    end
  end

  defp activate_from_event(%{}), do: {:ok, :ignored}

  # Resolve a customer.subscription.updated against the customer's current live
  # row: a canceled/unpaid status lapses it; an active status RECOVERS a past_due
  # row, no-ops an already-active one, or (no live row + signed metadata) lands a
  # fresh activation (the active-flip-from-new case). Anything else is ignored.
  defp handle_subscription_updated(event, object) do
    cus = customer_id(event)

    case Map.get(object, "status") do
      status when status in ["canceled", "unpaid"] ->
        case subscription_by_customer(cus) do
          %Subscription{} = sub -> cancel_subscription(sub)
          _ -> {:ok, :ignored}
        end

      "active" ->
        case subscription_by_customer(cus) do
          %Subscription{status: "past_due"} = sub -> recover_subscription(sub)
          %Subscription{status: "active"} = sub -> sync_cancel_flag(sub, object)
          _ -> activate_from_metadata(object)
        end

      _ ->
        {:ok, :ignored}
    end
  end

  # An already-active row is not a no-op event: a Stripe Customer Portal
  # UN-CANCEL (or a re-cancel) arrives as exactly this — status unchanged at
  # "active", `cancel_at_period_end` flipped. Before cch-w57-s2 the whole payload
  # was discarded, so a team that un-cancelled in the portal kept an "Ending" pill
  # and no Cancel control in the console forever. Lift ONLY that one flag, and
  # only when the payload STATES it as a boolean and it DIFFERS from the row — an
  # absent field means "Stripe said nothing", never `false`.
  #
  # Deliberately NOT syncing `current_period_end` here (charter D672): that single
  # column carries the dunning grace anchor, the trial expiry AND Stripe's renewal
  # date, and both `entitled?/1` and `maybe_enforce/1` branch on exactly it — a
  # payload-sourced write there can extend grace, suspend boxes in-band, or (on an
  # absent field) write nil and leave an unpaid team entitled forever.
  defp sync_cancel_flag(%Subscription{} = sub, object) do
    case Map.get(object, "cancel_at_period_end") do
      flag when is_boolean(flag) and flag != sub.cancel_at_period_end ->
        update_status(sub, %{cancel_at_period_end: flag})

      _ ->
        {:ok, :ignored}
    end
  end

  # Read team_id+plan from the SIGNED metadata and persist the subscription
  # DIRECTLY from the session object's ids (BILL-3) — NEVER calling subscribe/2
  # on the webhook path. The Stripe checkout.session.completed object already
  # carries the `customer` + `subscription` ids it created; subscribe/2 would
  # call the gateway to create a SECOND customer+subscription (double-bill) and
  # send the PLAN NAME as the price. We record the ids Stripe handed us instead.
  defp activate_from_metadata(object) do
    metadata = Map.get(object, "metadata", %{})
    team_id = metadata["team_id"]
    plan = metadata["plan"]
    customer_id = Map.get(object, "customer")
    subscription_id = Map.get(object, "subscription")

    if is_binary(team_id) and is_binary(plan) do
      activate_from_session(team_id, plan, customer_id, subscription_id)
    else
      {:error, :missing_metadata}
    end
  end

  # Land an active paid subscription from a signed session, idempotently and
  # without ever colliding with the one-LIVE-per-team unique index:
  #
  #   * a live `trial` row → UPGRADE it in place to the paid plan, stamping the
  #     session's real gateway ids (the trial→paid conversion; a fresh INSERT
  #     would collide with the trial's live slot).
  #   * a live `past_due` row → RECOVER it (a fresh checkout during dunning is a
  #     successful payment; resumes suspended boxes) — not a second INSERT.
  #   * any other live `active` row (paid / forever) → idempotent no-op.
  #   * no live row → INSERT directly from the session's customer+subscription
  #     ids (BILL-3: no subscribe/2, so no double-create / double-bill).
  defp activate_from_session(team_id, plan, customer_id, subscription_id) do
    result = do_activate_from_session(team_id, plan, customer_id, subscription_id)
    # usage-limits-quotas: whenever a checkout LANDS a plan (a fresh paid row, or
    # an in-place trial→paid conversion), reconcile the team's fleet against the
    # now-current ceiling — restoring any quota-suspended box the upgrade re-permits
    # (and suspending overflow if the new plan is smaller). A no-op when neither
    # applies. `:already_active` carries no plan change, so it is skipped.
    with {:ok, %Subscription{}} <- result do
      _ = reconcile_plan_limit(team_id)
    end

    result
  end

  defp do_activate_from_session(team_id, plan, customer_id, subscription_id) do
    case live_subscription(team_id) do
      %Subscription{plan: "trial"} = sub ->
        updated =
          sub
          |> Subscription.changeset(%{
            plan: plan,
            status: "active",
            gateway_customer_id: customer_id,
            gateway_subscription_id: subscription_id,
            past_due: false,
            canceled_at: nil,
            current_period_end: nil
          })
          |> Repo.update()

        # dwb-13 money-path guard: the trial just CONVERTED to paid. Cancel any
        # deprovision job the expiry worker may have enqueued for this team's
        # boxes so a subscribed team is NEVER torn down (belt-and-braces — the
        # worker also filters strictly on `plan == "trial"`). Best-effort: a
        # failure here must not fail the (already-committed) conversion.
        with {:ok, %Subscription{}} <- updated do
          _ = Registry.cancel_pending_deprovision_jobs(team_id)
        end

        updated

      %Subscription{status: "past_due"} = sub ->
        recover_subscription(sub)

      %Subscription{status: "active"} ->
        {:ok, :already_active}

      nil ->
        inserted =
          %Subscription{}
          |> Subscription.changeset(%{
            team_id: team_id,
            plan: plan,
            status: "active",
            gateway_customer_id: customer_id,
            gateway_subscription_id: subscription_id
          })
          |> Repo.insert()

        # cch-w50-s3: a team reaching this branch after a CANCEL still has every
        # managed box suspended with `"billing_lapsed"` — a reason the quota
        # reconciler never restores (see reconcile_plan_limit/1). Lift the billing
        # suspension here so the console's "your instances come back when you
        # resubscribe" is actually executed by something.
        #
        # ORDER IS LOAD-BEARING: this runs INSIDE do_activate_from_session, i.e.
        # BEFORE activate_from_session's reconcile_plan_limit/1. Resume-then-
        # reconcile makes the fleet visible to the reconciler, which then re-stamps
        # any overflow as `"quota_exceeded"` against the NEW ceiling. Moving it
        # after the reconcile inverts that: the reconciler would see zero live
        # boxes, suspend nothing, and the blanket resume would then run a 5-box
        # fleet on a 3-box plan. Pinned by billing_lifecycle_test.exs
        # "resubscribing on a SMALLER plan restores only up to the new ceiling".
        #
        # cch-w55-s4: this is `resume_billing_suspended/1`, NOT the reason-blind
        # `resume_team_barkparks/1` it used to be. The blind resume also cleared
        # `quota_exceeded` rows; here that was self-correcting (the reconcile
        # below re-stamped them, at the cost of a reset `suspended_at` and an
        # UNPAIRED `barkpark.suspended` in the event feed, since the bulk
        # `update_all` broadcasts nothing). At the OTHER call site —
        # recover_subscription/1 — nothing followed it, so the over-grant was
        # permanent. Both call sites are narrowed together: the billing axis
        # lifts the billing reasons, on managed rows, and no others.
        with {:ok, %Subscription{}} <- inserted do
          {:ok, _count} = Registry.resume_billing_suspended(team_id)
        end

        inserted
    end
  end

  # checkout.session.completed needs no status check (completion IS the signal);
  # a customer.subscription.* event only activates when its status is "active".
  defp active_status?("checkout.session.completed", _object), do: true
  defp active_status?(_type, object), do: Map.get(object, "status") == "active"

  # ── Lifecycle dispatch (keyed on gateway_customer_id) ──

  # invoice.payment_failed → dunning. Coolify-anchor:
  # SubscriptionInvoiceFailedJob + the stripe_past_due flag.
  defp handle_lifecycle(%{"type" => "invoice.payment_failed"} = event) do
    case subscription_by_customer(customer_id(event)) do
      # The Invoice object carries no period end (that's on the Subscription), so
      # let mark_past_due anchor the grace window itself — deterministic, not
      # payload-shaped.
      %Subscription{} = sub -> mark_past_due(sub)
      _ -> {:ok, :ignored}
    end
  end

  # customer.subscription.deleted → end of life. Coolify-anchor:
  # Team::subscriptionEnded(). Idempotent: a replay finds no LIVE sub (the row is
  # already `canceled`, excluded from the live lookup) → {:ok, :ignored}.
  defp handle_lifecycle(%{"type" => "customer.subscription.deleted"} = event) do
    case subscription_by_customer(customer_id(event)) do
      %Subscription{} = sub -> cancel_subscription(sub)
      _ -> {:ok, :ignored}
    end
  end

  # invoice.paid → recovery (clears past_due, resumes suspended boxes).
  # (customer.subscription.updated is resolved upstream by
  # handle_subscription_updated/2, so it never reaches here.)
  defp handle_lifecycle(%{"type" => "invoice.paid"} = event), do: recover_or_ignore(event)

  defp handle_lifecycle(_), do: {:ok, :ignored}

  # Recover only a sub that is actually in dunning; an already-active (or absent)
  # sub is a no-op so a duplicate invoice.paid never double-resumes.
  defp recover_or_ignore(event) do
    case subscription_by_customer(customer_id(event)) do
      %Subscription{status: "past_due"} = sub -> recover_subscription(sub)
      _ -> {:ok, :ignored}
    end
  end

  # ── Status transitions (the public lifecycle API) ──

  @doc """
  Mark `sub` past-due (a payment failed). Sets `status: "past_due"` +
  `past_due: true`, and anchors the grace window: `attrs` MAY carry an explicit
  `current_period_end`, but when it doesn't (the real `invoice.payment_failed`
  Invoice object has no period end — only the Subscription object does) we anchor
  grace at `now + #{@grace_days}d` so a past_due team is NOT entitled forever. A
  past_due sub is STILL entitled within grace (Coolify keeps a past_due team
  running and emails admins).

  Grace elapse does NOT suspend anything on the webhook path. Because this
  function re-anchors `current_period_end` `#{@grace_days}` days FORWARD on every
  call that carries no explicit one (`Map.put_new_lazy/3`, below), `maybe_enforce/1`'s
  `:gt -> :ok` arm always fires and its `Registry.suspend_team_barkparks/2` call is
  unreachable in production — only a caller passing an explicit PAST
  `current_period_end` (the tests do) reaches it. What elapsed grace actually costs
  the team is ISOLATION: `entitled?/1` goes false and the go-live gate refuses to
  launch a NEW instance. Nothing stops, nothing is deleted.
  """
  ## dunning-email-dedup: a first `active → past_due` transition returns the
  ## `%Subscription{}` (the router seam emails the team ONCE); a repeat call on a
  ## sub that was ALREADY `past_due` — a Stripe webhook REDELIVERY or a second
  ## dunning event — returns `{:ok, :already_past_due}` so the router skips the
  ## duplicate email. This mirrors `recover_or_ignore/1`, which only recovers a
  ## sub that IS `past_due`. The transition is detected BEFORE the write, but the
  ## write STILL runs on both paths: `past_due` stays set and `maybe_enforce/1`
  ## re-runs. Note what the re-applied anchor does — it slides FORWARD, another
  ## `@grace_days` out on every attr-less repeat, so a redelivery EXTENDS
  ## grace rather than letting it elapse (billing_lifecycle_test.exs drives this).
  ## ONLY the email is de-duplicated.
  @spec mark_past_due(Subscription.t(), map()) ::
          {:ok, Subscription.t() | :already_past_due} | {:error, term}
  def mark_past_due(%Subscription{} = sub, attrs \\ %{}) do
    already_past_due? = sub.status == "past_due"
    attrs = Map.put_new_lazy(attrs, :current_period_end, &default_grace_anchor/0)

    with {:ok, sub} <- update_status(sub, Map.merge(%{status: "past_due", past_due: true}, attrs)) do
      _ = maybe_enforce(sub)
      if already_past_due?, do: {:ok, :already_past_due}, else: {:ok, sub}
    end
  end

  # A fixed grace anchor `@grace_days` in the future — deterministic and
  # independent of the webhook payload shape (the Invoice carries no period end).
  defp default_grace_anchor do
    DateTime.utc_now() |> DateTime.add(@grace_days, :day) |> DateTime.truncate(:microsecond)
  end

  @doc """
  Cancel `sub` — terminal. Sets `status: "canceled"` + `canceled_at`, and
  SUSPENDS every managed Barkpark the team owns (the teeth — Coolify-anchor:
  Team::subscriptionEnded()). The row is retained (data retained, access
  revoked); re-subscribing later inserts a fresh `active` row.
  """
  @spec cancel_subscription(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term}
  def cancel_subscription(%Subscription{} = sub) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    with {:ok, sub} <-
           update_status(sub, %{status: "canceled", canceled_at: now, past_due: false}) do
      {:ok, _count} = Registry.suspend_team_barkparks(sub.team_id, "billing_lapsed")
      {:ok, sub}
    end
  end

  @doc """
  Recover `sub` from dunning back to `active` (a failed invoice was paid). Clears
  `past_due` and lifts the team's BILLING suspensions —
  `Registry.resume_billing_suspended/1`, reason- and mode-scoped.

  cch-w55-s4: this used to call the reason-blind `resume_team_barkparks/1` with
  NOTHING behind it (no reconcile), so paying a failed invoice also cleared
  `"quota_exceeded"` flags a downgrade had set — free capacity, with nothing
  scheduled to take it back — and revived `self_hosted` rows the suspend side
  refuses to touch. A paid invoice settles the billing axis and only that.
  """
  @spec recover_subscription(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term}
  def recover_subscription(%Subscription{} = sub) do
    with {:ok, sub} <-
           update_status(sub, %{status: "active", past_due: false, canceled_at: nil}) do
      {:ok, _count} = Registry.resume_billing_suspended(sub.team_id)
      {:ok, sub}
    end
  end

  # past_due is entitled while inside the grace window; past it, the team's managed
  # boxes are suspended with the softer "billing_past_due" reason. In PRODUCTION
  # that suspend is unreachable: the only caller is `mark_past_due/2`, which
  # re-anchors the period end `@grace_days` FORWARD whenever the caller supplies
  # none, so the `:gt -> :ok` arm always wins. Only an explicit PAST
  # `current_period_end` gets here. Nothing sweeps in behind it either — charter
  # D657 decided against a nightly reconciler: a grace that elapses with no further
  # webhook is enforced synchronously at request time by `entitled?/1`.
  defp maybe_enforce(%Subscription{status: "past_due", current_period_end: pe, team_id: tid}) do
    if is_nil(pe) or DateTime.compare(pe, DateTime.utc_now()) == :gt do
      :ok
    else
      {:ok, _count} = Registry.suspend_team_barkparks(tid, "billing_past_due")
      :ok
    end
  end

  defp maybe_enforce(_sub), do: :ok

  defp update_status(%Subscription{} = sub, attrs) do
    sub |> Subscription.changeset(attrs) |> Repo.update()
  end

  # ── Self-serve management ──

  @doc """
  Open a Stripe Customer Portal session for `team`'s live subscription so the
  customer self-manages (update card, view invoices, cancel) in a browser.
  Returns `{:ok, portal_url}` or `{:error, :no_subscription}` when the team has
  none. `opts` may carry a `:return_url`.
  """
  @spec billing_portal_url(Team.t() | binary(), keyword()) ::
          {:ok, String.t()} | {:error, :no_subscription | term}
  def billing_portal_url(team, opts \\ []) do
    case live_subscription(team) do
      %Subscription{gateway_customer_id: cus} when is_binary(cus) ->
        gateway().create_billing_portal_session(cus, opts)

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Customer-initiated cancellation of `team`'s live subscription. `at_period_end?`
  true (the default) schedules cancel-at-period-end through the gateway and marks
  the row `cancel_at_period_end: true` — the team STAYS entitled until Stripe
  later posts `customer.subscription.deleted` (which ends it via the lifecycle
  path). `false` cancels immediately at the gateway AND locally
  (`cancel_subscription/1` → suspend). Returns `{:ok, %Subscription{}}` or
  `{:error, :no_subscription | term}`.
  """
  @spec request_cancel(Team.t() | binary(), boolean()) ::
          {:ok, Subscription.t()} | {:error, :no_subscription | term}
  def request_cancel(team, at_period_end? \\ true) do
    case live_subscription(team) do
      %Subscription{gateway_subscription_id: sid} = sub when is_binary(sid) ->
        with {:ok, _gw} <- gateway().cancel_subscription(sid, at_period_end: at_period_end?) do
          if at_period_end? do
            update_status(sub, %{cancel_at_period_end: true})
          else
            cancel_subscription(sub)
          end
        end

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Idempotently mark `team_id`'s subscription on `plan` active. Dedupes on the
  team's LIVE row (active OR past_due), mirroring `handle_subscription_updated/2`:

    * an `active` live row → no-op (`{:ok, :already_active}`).
    * a `past_due` live row → RECOVER it (a fresh Checkout during dunning is a
      successful payment) — NOT a second INSERT, which would collide with the
      one-LIVE-per-team unique index and 400 the webhook (Stripe then retries for
      ~3 days and the recovery payment never reflects).
    * no live row → subscribe (the full gateway customer→subscription→persist flow).

  Used by `handle_webhook/2`; the team id and plan come from a SIGNED event,
  never a client.
  """
  @spec activate_subscription(binary(), String.t()) ::
          {:ok, Subscription.t() | :already_active} | {:error, term}
  def activate_subscription(team_id, plan) when is_binary(team_id) and is_binary(plan) do
    case live_subscription(team_id) do
      %Subscription{status: "active"} ->
        {:ok, :already_active}

      %Subscription{status: "past_due"} = sub ->
        recover_subscription(sub)

      nil ->
        subscribe(team_id, plan)
    end
  end

  @doc """
  Grant a Team a FOREVER comp licence — an admin override that bypasses billing.

  Writes (or converts an existing live sub into) an `active` `forever`
  subscription row carrying NO gateway ids, so the Stripe lifecycle webhooks
  (keyed on customer id) can never lapse it and `entitled?/1` stays true
  indefinitely. Idempotent: a team already on `forever` returns
  `{:ok, :already_forever}`.

  NOT reachable from any client path — granted only by
  `mix barkpark_cloud.grant_forever` or an operator IEx session.

  Caveat: if the team had a REAL paid Stripe subscription, converting it here
  detaches our row only — the operator must cancel the Stripe-side subscription
  separately so the customer is no longer charged.
  """
  @spec grant_forever(Team.t() | binary()) ::
          {:ok, Subscription.t() | :already_forever} | {:error, term}
  def grant_forever(team) do
    tid = team_id(team)

    case live_subscription(tid) do
      %Subscription{plan: "forever"} ->
        {:ok, :already_forever}

      %Subscription{} = sub ->
        # An existing live sub (free or paid) is converted to the comp tier —
        # admin override wins. Gateway ids are cleared so no Stripe event lapses it.
        sub
        |> Subscription.changeset(%{
          plan: "forever",
          status: "active",
          gateway_customer_id: nil,
          gateway_subscription_id: nil,
          past_due: false,
          cancel_at_period_end: false,
          canceled_at: nil,
          current_period_end: nil
        })
        |> Repo.update()

      nil ->
        %Subscription{}
        |> Subscription.changeset(%{team_id: tid, plan: "forever", status: "active"})
        |> Repo.insert()
    end
  end

  @doc """
  Grant a Team a self-serve FREE TRIAL — the no-gateway entitlement a brand-new
  team gets at signup so it can go live immediately, with no operator/SSH and no
  card.

  Mirrors `grant_forever/1` but writes a `trial` (not `forever`) `active` row
  carrying NO gateway ids and a `current_period_end` `trial_days/0` days out, AND
  stamps the DURABLE team ledger (`teams.trial_started_at` / `trial_ends_at`) at
  the same moment. Because it has no customer id, the Stripe lifecycle webhooks
  can never lapse it; instead `entitled?/1` enforces the trial's expiry against
  `current_period_end` (an expired trial is NOT entitled). The paid checkout
  webhook later UPGRADES this same live row in place (`activate_from_session/4`),
  so a trial→paid conversion never collides with the one-live-per-team index.

  Idempotent / never-downgrades: a team that ALREADY has a live subscription
  (trial, paid, or forever) keeps it untouched — this only lands a trial for a
  team with no live sub. Called inside the signup transaction (it rolls back
  with the team if anything later fails). The LAUNCH-time fallback for a team
  that reaches go-live un-entitled with no trial-row is `start_trial/1`, which
  adds the one-ever + race guards.
  """
  @spec grant_trial(Team.t() | binary()) :: {:ok, Subscription.t()} | {:error, term}
  def grant_trial(team) do
    tid = team_id(team)

    case live_subscription(tid) do
      # Never downgrade an existing live sub to a trial — keep what they have.
      %Subscription{} = sub ->
        {:ok, sub}

      nil ->
        # Stamp the durable ledger (idempotent: only if never trialed) and align
        # the sub's period end to the ledger's window so the two never disagree.
        ends = stamp_trial_window(tid)

        %Subscription{}
        |> Subscription.changeset(%{
          team_id: tid,
          plan: "trial",
          status: "active",
          current_period_end: ends
        })
        |> Repo.insert()
    end
  end

  @doc """
  Start a team's ONE free trial at LAUNCH — the auto-start fallback the go-live
  entitlement step (dwb-6) calls when a team hits go-live NOT entitled. This is
  the "fewest clicks" experience-contract semantic: a team's first launch with no
  active subscription auto-starts its trial instead of a 402, so nobody has to
  click "start trial" separately.

  ONE TRIAL PER TEAM EVER, race-safe, enforced on the DURABLE team ledger — not
  the (tear-down-able) subscription row. Granted ONLY to a team with NO live
  subscription at all and an unused ledger:

    * team already ENTITLED (paid / forever / a still-valid trial) → `{:ok,
      :already_entitled}`; a subscribed team NEVER consumes a trial.
    * a live-but-NOT-entitled sub — a lapsed paid subscription past its grace
      window, or an already-expired trial — → `{:error, :ineligible}`. Such a
      team has an existing billing relationship (fix billing / subscribe), not a
      fresh free trial. It 402s.
    * NO live sub + ledger UNUSED (`trial_started_at IS NULL`) → atomically claim
      the window (`UPDATE … WHERE trial_started_at IS NULL`, so two concurrent
      first-launches stamp exactly ONCE) and insert the `trial` row → `{:ok,
      %Subscription{}}`.
    * NO live sub + ledger ALREADY USED (a prior trial, now torn down) → `{:error,
      :trial_used}`. A torn-down trial can never be re-granted; it 402s.
  """
  @spec start_trial(Team.t() | binary()) ::
          {:ok, Subscription.t() | :already_entitled}
          | {:error, :trial_used | :ineligible | term}
  def start_trial(team) do
    tid = team_id(team)

    cond do
      # A subscribed / still-in-trial team never consumes (another) trial.
      entitled?(tid) ->
        {:ok, :already_entitled}

      # A live-but-lapsed sub (past_due past grace, or an expired trial) is an
      # existing billing relationship — NOT eligible for a fresh free trial.
      not is_nil(live_subscription(tid)) ->
        {:error, :ineligible}

      true ->
        case claim_trial_window(tid) do
          # Won the atomic claim + no live sub → land the team's first-ever trial.
          {:ok, ends} -> insert_trial_subscription(tid, ends)
          # The ledger was already stamped (a prior, torn-down trial) → no second.
          :already_used -> {:error, :trial_used}
        end
    end
  end

  # Stamp the ledger window if the team has never trialed, and return the
  # effective `trial_ends_at` to anchor the subscription's `current_period_end`.
  # For a brand-new signup team the claim always wins; the `:already_used`
  # fallback (a pre-existing ledger, e.g. legacy data) reads the stored end.
  defp stamp_trial_window(tid) do
    case claim_trial_window(tid) do
      {:ok, ends} -> ends
      :already_used -> (Repo.get(Team, tid) || %Team{}).trial_ends_at || default_trial_end()
    end
  end

  # The one-ever, race-safe ledger claim: a single conditional UPDATE that only
  # matches a row whose `trial_started_at` is still NULL. Postgres serializes it,
  # so exactly one of N concurrent callers gets `count == 1` (the winner); every
  # other gets `:already_used`. Returns the freshly-stamped `trial_ends_at`.
  @spec claim_trial_window(binary()) :: {:ok, DateTime.t()} | :already_used
  defp claim_trial_window(tid) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    ends = DateTime.add(now, trial_days(), :day)

    {count, _} =
      from(t in Team, where: t.id == ^tid and is_nil(t.trial_started_at))
      |> Repo.update_all(set: [trial_started_at: now, trial_ends_at: ends, updated_at: now])

    if count == 1, do: {:ok, ends}, else: :already_used
  end

  # Insert the team's first `trial` subscription aligned to the ledger `ends`.
  # Only reached with NO live sub (start_trial guards that), so a fresh INSERT
  # never collides with the one-live-per-team unique index; a lost concurrent
  # race surfaces as that changeset error, never a second row.
  defp insert_trial_subscription(tid, ends) do
    %Subscription{}
    |> Subscription.changeset(%{
      team_id: tid,
      plan: "trial",
      status: "active",
      current_period_end: ends
    })
    |> Repo.insert()
  end

  @doc """
  The configured free-trial length in days — `TRIAL_DAYS` in prod, else the
  #{@default_trial_days}-day default. Read at call time (not a module attr) so
  runtime.exs's env win, exactly like `prices` / `limits`.
  """
  @spec trial_days() :: pos_integer()
  def trial_days do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:trial_days, @default_trial_days)
  end

  # A trial end `trial_days/0` in the future (the fallback anchor).
  defp default_trial_end do
    DateTime.utc_now() |> DateTime.add(trial_days(), :day) |> DateTime.truncate(:microsecond)
  end

  # cch-w50 — HOW FAR AHEAD THE HOURLY SCAN LOOKS. A trial only becomes the
  # worker's business at its FIRST advance notice (T-3); before that there is
  # nothing it could do with the row. The horizon must therefore be >= the
  # worker's largest notice threshold — a shorter one would silently drop the
  # T-3 notice, which is why `trial_expiry_worker_test.exs` drives a trial at
  # exactly the T-3 boundary through this query rather than trusting the number.
  @trial_scan_horizon_seconds 3 * 86_400

  @doc "How far into the future `active_trials/1` reaches, in seconds."
  @spec trial_scan_horizon_seconds() :: pos_integer()
  def trial_scan_horizon_seconds, do: @trial_scan_horizon_seconds

  @doc """
  The trial subscriptions the `TrialExpiryWorker` has work for right now — plan
  `trial`, status `active`, with a real window that closes inside
  `trial_scan_horizon_seconds/0`. A CONVERTED team's live row is a paid plan, so
  it is naturally excluded (the worker never touches a subscribed team's boxes).

  cch-w50 — THE PERIOD FILTER, AND THE HALF IT DELIBERATELY DOES NOT DO. This
  query used to be `plan == "trial" and status == "active"` and nothing else, so
  the hourly run re-read every trial row that has ever existed. Two bounds close
  that, and they are closed by DIFFERENT mechanisms on purpose:

    * THE FUTURE SIDE — here. A trial 11 days from its first notice is not
      actionable, and the exclusion is TIME-REVERSIBLE: the same row re-enters
      the set the hour it crosses the horizon, so nothing can be stranded by it.
    * THE PAST SIDE — NOT here. A lapsed row leaves this set by reaching a
      terminal `status` (`expire_trial/2`, called by the worker once the
      teardown has actually happened), never by a lookback cutoff. A cutoff
      would be FAIL-OPEN: a worker outage longer than the window would strand
      every row that lapsed during it, permanently un-torn-down and
      un-finalised. Losing the rescan is worth nothing next to that.

  A NULL `current_period_end` is excluded too — `handle_trial/4` already skips
  such a row as malformed, so this only moves an existing no-op into SQL.
  """
  @spec active_trials() :: [Subscription.t()]
  def active_trials, do: active_trials(DateTime.utc_now())

  @doc """
  `active_trials/0` against an explicit `now`, so the worker's scan is a pure
  function of the instant it was handed (`TrialExpiryWorker.run/1`) instead of
  re-reading the clock one layer down.
  """
  @spec active_trials(DateTime.t()) :: [Subscription.t()]
  def active_trials(%DateTime{} = now) do
    horizon = DateTime.add(now, @trial_scan_horizon_seconds, :second)

    Subscription
    |> where([s], s.plan == "trial" and s.status == "active")
    |> where([s], not is_nil(s.current_period_end) and s.current_period_end <= ^horizon)
    |> Repo.all()
  end

  @doc """
  Finalise a LAPSED trial — THE TERMINAL WRITE THE EXPIRY WORKER NEVER MADE.

  `TrialExpiryWorker` used to enqueue the deprovision jobs and stop there, so an
  expired trial row kept `plan: "trial", status: "active"` forever. Measured on
  the live control plane 2026-08-07: 15 of 18 trial rows sat past their
  `current_period_end` — the oldest three weeks — all still `active`, all with
  zero boxes left. The console reads `status` (`/v1/subscription` →
  `live_subscription/1`), so those teams kept being served the running-trial card.

  ## Why `canceled` and not `expired`

  `Subscription`'s status enumeration is `active | canceled | past_due` and
  `changeset/2` validates against it — `"expired"` is not a value this schema can
  hold, and writing it round the changeset would poison every `status IN (…)`
  read in this module. `canceled` is the enumeration's existing terminal value,
  it is what `cancel_subscription/1` writes, and the one-live-per-team partial
  unique index EXCLUDES it, so a finalised trial never blocks the team's next
  subscription row.

  ## Blast radius (every predicate that reads this row)

    * `entitled?/1` — UNCHANGED, in both directions. Its `plan: "trial"` clause
      already answered `false` for a window in the past, and the finalised row is
      no longer live, so the fallthrough answers `false` too. No team gains or
      loses entitlement at the moment of this write. (The ghost-carve-out leg
      `Registry.provisioning_fqdn_claim/1` defers to `entitled?/1`, so it is
      unchanged with it.)
    * `live_subscription/1` / `active_subscription/1` — now nil for the team.
      That is the point: `/v1/subscription` answers `{subscription: nil}` and the
      console renders the honest no-plan upsell instead of a trial card.
    * `trial_days_remaining/1` — nil rather than 0 for a finalised team (the
      `%Subscription{}` arm is unchanged; only the team/id arm moves, because its
      `live_subscription/1` lookup now misses).
    * `active_trials/1` — the row leaves the hourly scan. This is the PAST-side
      bound the query above deliberately does not implement itself.
    * `do_activate_from_session/4` — a later checkout takes the `nil` INSERT arm
      instead of the in-place trial upgrade. Both land an `active` paid row; the
      INSERT arm additionally runs `Registry.resume_billing_suspended/1`, which is
      strictly MORE correct for a team whose boxes were suspended. The
      convert-just-after-expiry race the trial arm guards is NOT widened, because
      the worker only calls this once the teardown has completed — while a box
      still exists the row stays `trial`/`active` and the cancelling arm still
      runs (`trial_expiry_worker_test.exs` "a trial→paid conversion cancels any
      pending trial-deprovision job" is the pin).
    * `start_trial/1` — a finalised team moves from `{:error, :ineligible}` to
      `{:error, :trial_used}`. NO second trial is granted: the one-ever guard is
      the DURABLE team ledger (`teams.trial_started_at`), not this row — which is
      exactly why that guard was put on the ledger ("not the (tear-down-able)
      subscription row"). The refusal is the same refusal with a truer reason.

  Idempotent by its own head: only a `trial`/`active` row with a closed window is
  written, so a second call — or a second worker pass — is `:noop`.
  """
  @spec expire_trial(Subscription.t(), DateTime.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()} | :noop
  def expire_trial(
        %Subscription{plan: "trial", status: "active", current_period_end: %DateTime{} = pe} = sub,
        %DateTime{} = now
      ) do
    if DateTime.compare(pe, now) != :gt do
      sub
      |> Subscription.changeset(%{
        status: "canceled",
        canceled_at: DateTime.truncate(now, :microsecond)
      })
      |> Repo.update()
    else
      :noop
    end
  end

  def expire_trial(%Subscription{}, %DateTime{}), do: :noop

  @doc """
  Whole days remaining in a trial (0 once expired), or nil when the subject is
  not on a live trial. Powers the dashboard's days-remaining badge. Accepts
  either a `%Subscription{}` the caller already loaded (the router's
  `subscription_json`) or a team/id (a convenience that resolves its live sub).
  Computed from the trial sub's `current_period_end` — the entitlement anchor —
  rounded UP so "1 day left" shows until the final hour. Single source of truth
  for the remaining-days math.
  """
  @spec trial_days_remaining(Subscription.t() | Team.t() | binary()) :: non_neg_integer() | nil
  def trial_days_remaining(%Subscription{} = sub), do: sub_days_remaining(sub)

  def trial_days_remaining(team) do
    case live_subscription(team) do
      %Subscription{} = sub -> sub_days_remaining(sub)
      _ -> nil
    end
  end

  defp sub_days_remaining(%Subscription{plan: "trial", current_period_end: %DateTime{} = pe}) do
    secs = DateTime.diff(pe, DateTime.utc_now(), :second)
    if secs <= 0, do: 0, else: ceil(secs / 86_400)
  end

  defp sub_days_remaining(_), do: nil

  @doc "A Team's active subscription, or nil. Scoped — never crosses teams."
  @spec active_subscription(Team.t() | binary()) :: Subscription.t() | nil
  def active_subscription(team) do
    tid = team_id(team)

    Subscription
    |> where([s], s.team_id == ^tid and s.status == "active")
    |> Repo.one()
  end

  @doc """
  A Team's LIVE subscription — `active` OR `past_due`, or nil. The
  one-live-per-team partial unique index guarantees at most one. This is the row
  the lifecycle webhooks and the self-serve surface operate on.
  """
  @spec live_subscription(Team.t() | binary()) :: Subscription.t() | nil
  def live_subscription(team) do
    tid = team_id(team)

    Subscription
    |> where([s], s.team_id == ^tid and s.status in ["active", "past_due"])
    |> Repo.one()
  end

  @doc """
  Is `team` entitled to managed resources right now? True for an `active`
  subscription, for a `forever` comp, for a non-expired `trial`
  (`current_period_end` in the future), and for a `past_due` one still inside its
  grace window (`current_period_end` in the future, or unset). False otherwise —
  no live sub, an EXPIRED trial, or past_due past grace. The launch gate reads
  this instead of the old binary
  active-subscription check, so a paying customer in a transient dunning window
  is not locked out (Coolify-anchor: isSubscriptionActive() stays true through
  stripe_past_due).
  """
  @spec entitled?(Team.t() | binary()) :: boolean()
  def entitled?(team) do
    case live_subscription(team) do
      # An admin `forever` comp is always entitled, by definition.
      %Subscription{plan: "forever"} ->
        true

      # A self-serve `trial` is entitled ONLY while it hasn't expired — its
      # `current_period_end` must be in the future. An expired trial (or one with
      # no period end) is NOT entitled, so the user must subscribe. Checked BEFORE
      # the generic `active` clause below, since a trial row is itself `active`.
      %Subscription{plan: "trial", current_period_end: pe} ->
        not is_nil(pe) and DateTime.compare(pe, DateTime.utc_now()) == :gt

      %Subscription{status: "active"} ->
        true

      %Subscription{status: "past_due", current_period_end: pe} ->
        is_nil(pe) or DateTime.compare(pe, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end

  ## Helpers

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  # The gateway customer id off a Stripe event object.
  defp customer_id(event), do: get_in(event, ["data", "object", "customer"])

  # The LIVE subscription for a gateway customer id (active OR past_due). nil for
  # a non-binary id (an event with no customer) or a customer with only a
  # terminal/absent row — both route the lifecycle clause to {:ok, :ignored}.
  defp subscription_by_customer(cus) when is_binary(cus) do
    Subscription
    |> where([s], s.gateway_customer_id == ^cus and s.status in ["active", "past_due"])
    |> Repo.one()
  end

  defp subscription_by_customer(_), do: nil
end
