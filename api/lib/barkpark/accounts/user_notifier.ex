defmodule Barkpark.Accounts.UserNotifier do
  @moduledoc """
  Builds + sends the core-auth transactional emails (verify-email, reset). The
  caller passes a fully-formed URL carrying the single-use token plaintext; this
  module only renders + delivers. Kept text-only and dependency-light.
  """
  import Swoosh.Email
  require Logger
  alias Barkpark.Mailer

  @from {"Barkpark", "no-reply@barkpark.cloud"}

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
      |> from(@from)
      |> subject(subject)
      |> text_body(body)

    # Fail-soft: callers (auth_controller request-reset/register) intentionally
    # ignore this result and still return 200 for anti-enumeration. We do NOT
    # change that — a down relay must not leak account existence. We only add
    # OBSERVABILITY so a dropped auth email leaves a diagnostic trail instead of
    # vanishing silently. Log the email *type* (subject) + reason only; never the
    # recipient address (PII).
    case Mailer.deliver(email) do
      {:ok, _meta} ->
        {:ok, email}

      {:error, reason} ->
        Logger.error(
          "transactional email delivery failed: subject=#{inspect(subject)} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
