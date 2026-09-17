defmodule BarkparkCloud.Mailer do
  @moduledoc """
  The PLATFORM mailer — Barkpark Cloud's own outbound email.

  Transactional identity email (invites, password resets, verification) ALWAYS
  rides this, never a per-team transport, so the product can onboard a user even
  when their team has no SMTP configured. The adapter is config-selected — the
  SAME config-adapter seam `Billing.Gateway` and `Registry.Vault` use:

    * dev  → `Swoosh.Adapters.Local` (an in-memory mailbox; no network)
    * test → `Swoosh.Adapters.Test` (`assert_email_sent`)
    * prod → `Swoosh.Adapters.SMTP` (gen_smtp), wired from env in runtime.exs

  No secrets in code — the prod SMTP relay creds come from `SMTP_*` env vars.

  ## Per-team transport

  For ALERT email whose team chose `transport: "smtp"`, the context passes a
  per-call config override to `deliver/2` (Swoosh accepts a keyword list that
  wins over the module config), so ONE mailer module serves both the platform
  and the per-team paths — no second Mailer module. `transport: "instance"`
  passes no override and rides the platform adapter above.

  There is no third transport. `"api"` was offered by the schema and the console
  with no adapter behind it and was deleted in cch-w52-s1; the two-way guard is
  `test/barkpark_cloud/notifications/transport_manifest_test.exs`.
  """
  use Swoosh.Mailer, otp_app: :barkpark_cloud

  require Logger

  # Adapters that ACCEPT a message and never put it on a wire. `Test` is here so
  # `deliverability/0` can NAME it, not so it can be alarmed on — `discards?/1`
  # below deliberately excludes it (see `drops_mail?/0`).
  @non_delivering %{
    Swoosh.Adapters.Local => :local_mailbox,
    Swoosh.Adapters.Test => :test_capture
  }

  @doc """
  What this control plane's mail configuration can actually do, as
  `%{adapter:, deliverable?:, reason:}`. `reason` is one of
  `:ok | :local_mailbox | :test_capture | :unconfigured | :relay_unset`.

  THE `:relay_unset` ARM IS THE ONE THAT MATTERS HERE, and it is why this is not
  a copy of `Barkpark.Mailer.deliverability/0`. On an instance the mail-dead
  shape is the LOCAL ADAPTER, because `api/config/config.exs` defaults to it and
  `SMTP_HOST` opts in. On the control plane there is no such branch:
  `cloud/config/runtime.exs` sets `Swoosh.Adapters.SMTP` UNCONDITIONALLY in prod
  and passes `System.get_env("SMTP_HOST")` straight through as `:relay`. A plane
  booted with `SMTP_HOST` unset therefore holds a DELIVERING adapter with a nil
  relay — a state an adapter-only check reads as healthy while every send dies
  in gen_smtp option validation (`:no_relay`, already classified by
  `Notifications.DeliveryReason`).

  The one place the question "can this plane send mail off-box?" is answered, so
  the boot banner and any future health component cannot drift apart.
  """
  @spec deliverability() :: %{adapter: module() | nil, deliverable?: boolean(), reason: atom()}
  def deliverability do
    cfg = Application.get_env(:barkpark_cloud, __MODULE__, [])

    case cfg[:adapter] do
      nil ->
        %{adapter: nil, deliverable?: false, reason: :unconfigured}

      Swoosh.Adapters.SMTP = mod ->
        if blank?(cfg[:relay]) do
          %{adapter: mod, deliverable?: false, reason: :relay_unset}
        else
          %{adapter: mod, deliverable?: true, reason: :ok}
        end

      mod ->
        case Map.fetch(@non_delivering, mod) do
          {:ok, reason} -> %{adapter: mod, deliverable?: false, reason: reason}
          :error -> %{adapter: mod, deliverable?: true, reason: :ok}
        end
    end
  end

  # A relay is "set" only if it is a non-blank string. `nil` is what
  # `System.get_env("SMTP_HOST")` answers when the var is absent; `""` is what it
  # answers when the var is present and empty, which a shell produces far more
  # often than anyone expects (`SMTP_HOST=$UNSET_VAR`). Both are mail-dead.
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false

  @doc """
  Whether this configuration accepts transactional mail and drops it where a
  REAL person was expecting it.

  NARROWER than `not deliverability().deliverable?`: `Swoosh.Adapters.Test` is
  excluded. That adapter only exists under `MIX_ENV=test`, where the recipient
  IS the assertion and nothing was withheld from anyone — counting it would fire
  the banner on every test run and teach people to ignore the one line that
  matters.
  """
  @spec drops_mail?() :: boolean()
  def drops_mail?, do: discards?(deliverability().reason)

  # The ONE spelling of "this reason means a real person's mail is dropped".
  defp discards?(reason), do: reason in [:local_mailbox, :unconfigured, :relay_unset]

  @doc """
  Log the undeliverable-mail banner at boot when this plane cannot send.

  WARNS, it does not raise. A control plane with no relay is a legitimate
  configuration — every `mix phx.server` on a laptop is one — so refusing the
  node would make the honest signal unshippable.

  The banner exists because the receipts this plane already writes CANNOT reach
  the operator in this state. Every transactional send records a Delivery row
  (`Notifications.record_delivery/6`) and a failed one carries the right
  sentence, but password-reset / email-verification / email-change rows are
  USER-scoped (`team_id` nil) by deliberate privacy design, so they surface in
  NO team's delivery log. A plane booted without `SMTP_HOST` therefore drops
  every identity email into rows nobody is looking at. The boot line is the
  first moment anyone can be told.

  Returns the deliverability map so a caller can assert on it.
  """
  @spec warn_if_undeliverable() :: map()
  def warn_if_undeliverable do
    status = deliverability()

    if drops_mail?() do
      Logger.warning("""
      MAIL IS NOT DELIVERABLE — this control plane accepts transactional email and discards it.

        adapter: #{inspect(status.adapter)} (#{status.reason})

      Team invitations, password reset, email verification and email-change
      confirmation codes will FAIL to send. The user-scoped delivery rows that
      record those failures belong to no team, so nothing else will show you
      this.

      Set SMTP_HOST (plus SMTP_PORT / SMTP_USERNAME / SMTP_PASSWORD as your relay
      requires). Ignore this if the plane is not meant to send mail.
      """)
    end

    status
  end

  @doc """
  The platform default `{name, address}` From, read at call time so a
  runtime.exs override (MAIL_FROM_ADDRESS / MAIL_FROM_NAME) wins over the
  compile-time default.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    cfg = Application.get_env(:barkpark_cloud, BarkparkCloud.Notifications, [])
    {cfg[:from_name] || "Barkpark Cloud", cfg[:from_address] || "noreply@barkpark.cloud"}
  end
end
