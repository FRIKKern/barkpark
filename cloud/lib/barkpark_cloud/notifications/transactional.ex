defmodule BarkparkCloud.Notifications.Transactional do
  @moduledoc """
  Identity / transactional email — the beta blocker.

  One builder per Coolify `TransactionalEmails/*` class. These emails are decoupled
  EXACTLY like Coolify's `TransactionalEmailChannel.php`: they NEVER consult a
  team's `EmailSettings` transport. They always ride the platform
  `BarkparkCloud.Mailer`, because an invite / password-reset / verification mail
  must send even when the team has configured no SMTP of its own — otherwise a
  team could lock itself out of onboarding.

  Each function builds a `%Swoosh.Email{}` and delivers it over the platform
  transport. The URLs / tokens are CALLER-SUPPLIED (the owning feature mints the
  invite token, the reset token, the verification token), so this module only
  renders + sends — it compiles and tests stand-alone with a fake token string.
  """
  import Swoosh.Email

  alias BarkparkCloud.Mailer

  @doc """
  Build (but do not send) the team-invite email. Separated from delivery so
  tests and the dispatcher can inspect the struct.

  `invite` is a map carrying at least `:to` (the invitee email) and `:url` (the
  accept-invite link); `:team_name` is optional display text.
  """
  @spec invite_email(map()) :: Swoosh.Email.t()
  def invite_email(%{to: to, url: url} = invite) do
    team_name = Map.get(invite, :team_name, "a team")

    base_email(to, "You've been invited to #{team_name} on Barkpark Cloud", """
    You've been invited to join #{team_name} on Barkpark Cloud.

    Accept the invitation:
    #{url}

    If you weren't expecting this, you can ignore this email.
    """)
  end

  @doc "Build the password-reset email. `url` is the caller-minted reset link."
  @spec password_reset_email(String.t(), String.t()) :: Swoosh.Email.t()
  def password_reset_email(to, url) when is_binary(to) and is_binary(url) do
    base_email(to, "Reset your Barkpark Cloud password", """
    We received a request to reset your Barkpark Cloud password.

    Reset it here:
    #{url}

    If you didn't ask for this, no action is needed — your password is unchanged.
    """)
  end

  @doc "Build the email-verification email. `url` is the caller-minted verify link."
  @spec email_verification_email(String.t(), String.t()) :: Swoosh.Email.t()
  def email_verification_email(to, url) when is_binary(to) and is_binary(url) do
    base_email(to, "Verify your Barkpark Cloud email", """
    Confirm this email address for your Barkpark Cloud account:
    #{url}
    """)
  end

  @doc "Build the test email the settings page's \"Send test\" button fires."
  @spec test_email(String.t()) :: Swoosh.Email.t()
  def test_email(to) when is_binary(to) do
    base_email(to, "Barkpark Cloud test email", """
    This is a test email from Barkpark Cloud.

    If you received it, your notification email is working.
    """)
  end

  ## Delivery wrappers — build + deliver over the PLATFORM transport.

  @spec deliver_invite(map()) :: {:ok, term()} | {:error, term()}
  def deliver_invite(invite), do: invite |> invite_email() |> Mailer.deliver()

  @spec deliver_password_reset(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_password_reset(to, url), do: password_reset_email(to, url) |> Mailer.deliver()

  @spec deliver_email_verification(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_email_verification(to, url),
    do: email_verification_email(to, url) |> Mailer.deliver()

  @spec deliver_test(String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_test(to), do: to |> test_email() |> Mailer.deliver()

  # Build a plain-text email from the platform From. HTML bodies are a later
  # polish (YAGNI) — the transactional path's job is to reliably DELIVER, not to
  # be pretty.
  defp base_email(to, subject, text) do
    new()
    |> to(to)
    |> from(Mailer.from())
    |> subject(subject)
    |> text_body(text)
  end
end
