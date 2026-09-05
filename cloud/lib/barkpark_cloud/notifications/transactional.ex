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

  @doc """
  Build the verified-email-change email. `code` is the caller-minted 6-digit
  confirmation code, sent to the NEW address being proven (never the current
  login email).
  """
  @spec email_change_code_email(String.t(), String.t()) :: Swoosh.Email.t()
  def email_change_code_email(to, code) when is_binary(to) and is_binary(code) do
    base_email(to, "Confirm your new Barkpark Cloud email", """
    Enter this code in Barkpark Cloud to confirm changing your account email to
    this address:

    #{code}

    The code expires shortly. If you didn't request this change, ignore this
    email — your account email stays the same.
    """)
  end

  @doc """
  cch-w30-bl — build the PAT expiry warning, addressed to the token's OWNER.

  IT IS TRANSACTIONAL, NOT AN ALERT, and that is a routing decision rather than
  a filing one. A token's lifecycle is a fact about ONE user; the alert path
  (`Notifications.dispatch_event/3`) fans to `team_member_emails/1` with no role
  predicate, so an alert-shaped token warning would publish one member's
  credential inventory, its user-chosen NAME and its rotation deadline to every
  other member of the team it was minted under. Riding this module instead makes
  the audience a single address by construction.

  THE BODY NAMES THE TOKEN AND ITS DEADLINE. `event_email.ex` used to render
  `token_expiring` as a bare `detail(payload)`, so a producer that shipped no
  body sent an honest but EMPTY email (`text_body == ""`). The `name` and the
  `expires_at` are the whole content of the notice: without them the mail says
  "something of yours expires soon" to a user who may hold a dozen tokens.

  The name is a USER-CHOSEN string echoed back to the user who chose it — the
  one recipient for whom it is not a disclosure.
  """
  @spec token_expiring_email(String.t(), String.t(), DateTime.t()) :: Swoosh.Email.t()
  def token_expiring_email(to, token_name, %DateTime{} = expires_at) when is_binary(to) do
    name = if is_binary(token_name) and token_name != "", do: token_name, else: "(unnamed)"
    when_ = format_expiry(expires_at)

    base_email(to, "Your Barkpark Cloud API token \"#{name}\" expires soon", """
    Your personal access token "#{name}" expires on #{when_}.

    After that it stops authenticating and any script still presenting it will
    start getting 401s. If you still need it, mint a replacement in Barkpark
    Cloud under Settings -> API tokens and swap it in; if you don't, you can
    ignore this — the token expires on its own.

    You are getting this because you own that token. Nobody else on your team
    was told.
    """)
  end

  # The deadline as a plain UTC date + time. Deliberately not localised: this
  # module has no recipient timezone to localise TO, and a wrong local time on a
  # credential deadline is worse than an explicit UTC one.
  defp format_expiry(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d at %H:%M UTC")
  end

  @doc """
  Build the test email the settings page's "Send test" button fires.

  cch-w40-bl. The body used to read "If you received it, your notification email
  is working" — a claim this send CANNOT make. Delivery here always rides the
  platform `Mailer` (see the moduledoc); it never touches a team's own relay. A
  team that selected `transport: "smtp"` and pointed it at a dead host therefore
  passed this test 100% of the time, and then every real alert silently fell back
  to the platform transport anyway.

  The honest fix is DISCLOSURE, not routing: the body names the carrier it
  actually exercised, and `:selected_transport` (the team's
  `EmailSettings.transport`, passed by `Notifications.deliver_test/2`) lets it add
  — in the same breath — that the transport the team SELECTED is not the one this
  test proved. Routing the probe over an unverified relay is a separate, larger
  risk: it can hang the request path.

  `:selected_transport` is disclosure only. Omit it and the mail is exactly the
  platform-transport sentence, with no claim about any team relay.
  """
  @spec test_email(String.t(), keyword()) :: Swoosh.Email.t()
  def test_email(to, opts \\ []) when is_binary(to) do
    body = """
    This is a test email from Barkpark Cloud.

    It was sent over the Barkpark platform mail transport. If you received it,
    that transport is working.
    """

    base_email(
      to,
      "Barkpark Cloud test email",
      body <> transport_caveat(Keyword.get(opts, :selected_transport))
    )
  end

  # "instance" IS the platform transport, so a team on it had exactly the thing
  # it selected exercised and there is nothing left to say — the disclosure can
  # LOSE. Any other selection (today only "smtp", per
  # `EmailSettings.transports/0`) was NOT exercised, and silence there is the
  # original lie. An absent/unknown value adds nothing: unknown is not a
  # mismatch.
  defp transport_caveat("smtp") do
    """

    This test did NOT use your relay.

    Your team is set to send alerts over its own SMTP relay. Receiving this mail
    proves the platform transport only — it does not prove your SMTP settings.
    """
  end

  defp transport_caveat(_), do: ""

  ## Delivery wrappers — build + deliver over the PLATFORM transport.

  @spec deliver_invite(map()) :: {:ok, term()} | {:error, term()}
  def deliver_invite(invite), do: invite |> invite_email() |> Mailer.deliver()

  @spec deliver_password_reset(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_password_reset(to, url), do: password_reset_email(to, url) |> Mailer.deliver()

  @spec deliver_email_verification(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_email_verification(to, url),
    do: email_verification_email(to, url) |> Mailer.deliver()

  @spec deliver_email_change_code(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_email_change_code(to, code),
    do: email_change_code_email(to, code) |> Mailer.deliver()

  @spec deliver_token_expiring(String.t(), String.t(), DateTime.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_token_expiring(to, token_name, %DateTime{} = expires_at),
    do: token_expiring_email(to, token_name, expires_at) |> Mailer.deliver()

  # cch-w40-bl: `opts` is passed to `test_email/2` for COPY only. Arity 1 still
  # exists and still means exactly what it always meant — build, then
  # `Mailer.deliver/1` with NO override, i.e. the platform transport. Nothing
  # here reads a team's relay config and nothing here can be made to.
  @spec deliver_test(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def deliver_test(to, opts \\ []), do: to |> test_email(opts) |> Mailer.deliver()

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
