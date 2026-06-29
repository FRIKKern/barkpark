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

  For ALERT email whose team chose `transport: "smtp"`/`"api"`, the context
  passes a per-call config override to `deliver/2` (Swoosh accepts a keyword list
  that wins over the module config), so ONE mailer module serves both the
  platform and the per-team paths — no second Mailer module. `transport:
  "instance"` passes no override and rides the platform adapter above.
  """
  use Swoosh.Mailer, otp_app: :barkpark_cloud

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
