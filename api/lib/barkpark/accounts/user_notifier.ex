defmodule Barkpark.Accounts.UserNotifier do
  @moduledoc """
  Builds + sends the core-auth transactional emails (verify-email, reset). The
  caller passes a fully-formed URL carrying the single-use token plaintext; this
  module only renders + delivers. Kept text-only and dependency-light.
  """
  import Swoosh.Email
  require Logger
  alias Barkpark.Mailer

  @doc "Send the email-verification link."
  def deliver_confirmation(email, url) do
    deliver(email, "Confirm your Barkpark email", """
    Welcome to Barkpark.

    Confirm your email address by visiting the link below:

    #{url}

    If you didn't create this account, ignore this message.
    """)
  end

  @doc "Send the password-reset link."
  def deliver_reset(email, url) do
    deliver(email, "Reset your Barkpark password", """
    A password reset was requested for your Barkpark account.

    Reset it by visiting the link below:

    #{url}

    If you didn't request this, ignore this message — your password is unchanged.
    """)
  end

  @doc "Send the passwordless magic-link sign-in link."
  def deliver_magic_link(email, url) do
    deliver(email, "Your Barkpark sign-in link", """
    Sign in to Barkpark by visiting the link below:

    #{url}

    This link is single-use and expires shortly. If you didn't request it,
    ignore this message — no one can sign in without it.
    """)
  end

  @doc """
  Notify an existing user that someone tried to register their email again
  (MEDIUM-7 anti-enumeration: the API returns a generic success, the real owner
  is told out-of-band instead of leaking existence to the caller).
  """
  def deliver_already_registered(email) do
    deliver(email, "You already have a Barkpark account", """
    Someone just tried to create a Barkpark account with this email address.

    You already have an account, so we didn't create a new one. If this was you,
    you can simply sign in. If it wasn't, no action is needed — your account is
    unchanged. Consider resetting your password if you're concerned.
    """)
  end

  defp deliver(to, subject, body) do
    email =
      new()
      |> to(to)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    # NAMED FAILURE MODE: synchronous external I/O in a request path. In prod
    # `Mailer.deliver` opens an SMTP conversation via gen_smtp; a slow or
    # unreachable relay would stall the CALLING request (login / registration /
    # reset) up to gen_smtp's own timeout, because the round-trip rode the
    # request's scheduler slot. We offload delivery to the shared
    # `Barkpark.TaskSupervisor` so the request returns immediately and the SMTP
    # round-trip never blocks it.
    #
    # Fail-soft is UNCHANGED and in fact strengthened: callers (auth_controller
    # request-reset / register / magic-link) intentionally ignore this result and
    # still return 200 for anti-enumeration — a down relay must not leak account
    # existence. Off-loading means the request can no longer observe the outcome
    # at all. The diagnostic log (email *type* / subject + reason, NEVER the
    # recipient address — PII) moves INSIDE the task so a dropped auth email still
    # leaves a trail instead of vanishing silently. `start_child` is deliberate:
    # the result is never retrieved and one caller is a long-lived LiveView, so
    # fire-and-forget avoids leaking a reply/DOWN into its mailbox.
    # `Mailer.deliver_checked/1`, not `Mailer.deliver/1`: under the compile-time
    # default adapter (`Swoosh.Adapters.Local`) a raw deliver returns `{:ok, _}`
    # for a message that was written to an in-memory mailbox and discarded, so
    # this `case` used to take the success branch and log NOTHING. A relay that
    # is configured but DOWN was loud; an instance with NO relay at all — the
    # state every box is in until someone sets SMTP_HOST — was silent, which is
    # the failure that lasts forever rather than minutes.
    Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
      case Mailer.deliver_checked(email) do
        :ok ->
          :ok

        {:error, {:not_deliverable, adapter, reason}} ->
          Logger.warning(
            "transactional email NOT DELIVERED (no mail relay configured): " <>
              "subject=#{inspect(subject)} adapter=#{inspect(adapter)} reason=#{inspect(reason)} — " <>
              "set SMTP_HOST to enable delivery (deploy/smtp.env.example)"
          )

        {:error, reason} ->
          Logger.error(
            "transactional email delivery failed: subject=#{inspect(subject)} reason=#{inspect(reason)}"
          )
      end
    end)

    {:ok, email}
  end
end
