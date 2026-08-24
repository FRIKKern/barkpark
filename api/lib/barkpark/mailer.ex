defmodule Barkpark.Mailer do
  @moduledoc """
  Transactional mailer for core auth (email verification + password reset).

  Adapter is config-selected per environment (`config :barkpark, #{inspect(__MODULE__)}`):
  dev → `Swoosh.Adapters.Local` (the `/dev/mailbox`), test → `Swoosh.Adapters.Test`
  (in-process capture), prod → SMTP via `gen_smtp` (wired in runtime.exs). The
  Swoosh API client is disabled (config.exs) so no HTTP client dep is pulled.

  ## The From identity

  `from/0` is the ONE place the outbound `From` is decided — every notifier
  (`Barkpark.Accounts.UserNotifier`, `Barkpark.Access.GrantNotifier`) reads it
  instead of carrying its own literal.

  NAMED FAILURE MODE this replaces (gh-9531): the From used to be a compile-time
  `@from` module attribute in each notifier. A module attribute is frozen when
  the release is BUILT, so `config/runtime.exs` — which is evaluated at boot —
  could never move it. A self-hoster who set `SMTP_HOST` to their own relay
  still sent `From: no-reply@barkpark.cloud`; most relays reject a message whose
  From is not the authenticated sender (and where they do not, the receiver's
  SPF/DKIM/DMARC alignment fails), so password resets, magic links and grant
  invitations were accepted with an HTTP 200 and then silently dropped — the
  send is fire-and-forget through `Barkpark.TaskSupervisor`, so the caller never
  saw the rejection. The address could only be changed by editing source and
  rebuilding.
  """
  use Swoosh.Mailer, otp_app: :barkpark

  require Logger

  @default_from_address "no-reply@barkpark.cloud"
  @default_from_name "Barkpark"

  # Adapters that ACCEPT a message and return `{:ok, _}` without it ever leaving
  # the box. `Swoosh.Adapters.Local.deliver/2` pushes into an in-memory mailbox
  # and returns `{:ok, %{id: id}}`; `Swoosh.Adapters.Test` hands the email to the
  # `$callers` chain and likewise returns `{:ok, _}`. Neither reports a failure
  # the caller could observe — which is precisely why they need naming here.
  @non_delivering %{
    Swoosh.Adapters.Local => :local_mailbox,
    Swoosh.Adapters.Test => :test_capture
  }

  # The CLOSED vocabulary of `deliverability/0` reasons. Exported by
  # `deliverability_reasons/0` so a consumer can pin its own mapping against
  # this list in a test rather than hand-copying the literal — a copy goes stale
  # silently the first time a fifth state is added here.
  @reasons [:ok, :local_mailbox, :test_capture, :unconfigured]

  # Compile-time tripwire. Adding an adapter to @non_delivering with a reason
  # that is not in @reasons would ship a vocabulary the seam's consumers cannot
  # see, which is the same class of silent divergence this module exists to
  # close. Fail the BUILD instead.
  unexported = (Map.values(@non_delivering) ++ [:ok, :unconfigured]) -- @reasons

  if unexported != [] do
    raise "Barkpark.Mailer: deliverability reasons missing from @reasons: #{inspect(unexported)}"
  end

  @doc """
  The `{name, address}` From for every transactional email, read at CALL time so
  a `config/runtime.exs` override (`MAIL_FROM_ADDRESS` / `MAIL_FROM_NAME`) wins
  over the compile-time default. Mirrors `BarkparkCloud.Mailer.from/0`, which
  established this seam on the control plane.

  Unconfigured, this returns the historical default pair — existing deployments
  are unaffected.

  FAILS CLOSED: a configured-but-malformed address raises. Falling back to the
  default on bad input would re-create the very defect this function exists to
  fix — the operator would believe they had set their sender while the box kept
  emitting the barkpark.cloud address. `Barkpark.Application.start/2` calls this
  once at boot so a bad value refuses the node instead of surfacing as a mystery
  non-delivery on someone's first password reset.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    cfg = Application.get_env(:barkpark, :mail, [])

    name = Keyword.get(cfg, :from_name) || @default_from_name
    address = Keyword.get(cfg, :from_address) || @default_from_address

    {validate_name!(name), validate_address!(address)}
  end

  @doc """
  The compile-time fallback pair, for tests and for callers that need to state
  what "unconfigured" means without reproducing the literals.
  """
  @spec default_from() :: {String.t(), String.t()}
  def default_from, do: {@default_from_name, @default_from_address}

  # A From header is assembled by Swoosh into a single header LINE. A CR, LF or
  # NUL smuggled through config would terminate that line and let everything
  # after it be read as further headers (Bcc:, Content-Type:) — SMTP header
  # injection. The address is additionally held to one "@" with both halves
  # present, and to no `<>,;` (which would let one value expand into several
  # mailboxes). A dot in the domain is deliberately NOT required: `root@localhost`
  # is a legitimate sender for an internal relay.
  defp validate_address!(address) when is_binary(address) do
    cond do
      String.trim(address) == "" ->
        bad_address!(address, "must not be blank")

      Regex.match?(~r/[\s<>,;[:cntrl:]]/, address) ->
        bad_address!(address, "must not contain whitespace, control characters, or any of <>,;")

      length(String.split(address, "@")) != 2 ->
        bad_address!(address, ~S(must contain exactly one "@"))

      Enum.any?(String.split(address, "@"), &(&1 == "")) ->
        bad_address!(address, "must have a non-empty local part and domain")

      true ->
        address
    end
  end

  defp validate_address!(other), do: bad_address!(other, "must be a string")

  defp bad_address!(value, why) do
    raise ArgumentError, """
    invalid transactional mail From address: #{inspect(value)} — #{why}.

    Set MAIL_FROM_ADDRESS to an address your SMTP relay is authorised to send
    as, or leave it unset to keep the #{@default_from_address} default.
    """
  end

  # The display name rides the same header line, so it takes the same injection
  # guard. An EMPTY name is honoured, not defaulted: an operator who sets
  # MAIL_FROM_NAME="" is asking for a bare-address From.
  defp validate_name!(name) when is_binary(name) do
    if Regex.match?(~r/[[:cntrl:]]/, name) do
      raise ArgumentError,
            "invalid transactional mail From name: #{inspect(name)} — " <>
              "must not contain control characters (MAIL_FROM_NAME)"
    end

    name
  end

  defp validate_name!(other) do
    raise ArgumentError,
          "invalid transactional mail From name: #{inspect(other)} — " <>
            "must be a string (MAIL_FROM_NAME)"
  end

  @doc """
  What this node's mail configuration can actually do, as
  `%{adapter:, deliverable?:, reason:}`.

  `deliverable?` is the strict truth: `false` for any adapter in
  `@non_delivering` and for an unconfigured mailer. `reason` is one of
  `:ok | :local_mailbox | :test_capture | :unconfigured`.

  This is the ONE place the question "can this box send mail off-box?" is
  answered — the boot banner, the send path and the `/status.json` `mail`
  component all read it, so they can never disagree.
  """
  @spec deliverability() :: %{adapter: module() | nil, deliverable?: boolean(), reason: atom()}
  def deliverability do
    case Application.get_env(:barkpark, __MODULE__, [])[:adapter] do
      nil ->
        %{adapter: nil, deliverable?: false, reason: :unconfigured}

      mod ->
        case Map.fetch(@non_delivering, mod) do
          {:ok, reason} -> %{adapter: mod, deliverable?: false, reason: reason}
          :error -> %{adapter: mod, deliverable?: true, reason: :ok}
        end
    end
  end

  @doc """
  Whether this configuration accepts transactional mail and drops it where a
  REAL person was expecting it — the operational predicate behind the boot
  banner, the per-send warning and the `mail` health component.

  Deliberately NARROWER than `not deliverability().deliverable?`:
  `Swoosh.Adapters.Test` is excluded. That adapter only exists under
  `MIX_ENV=test`, where the "recipient" is the assertion itself and nothing was
  withheld from anyone. Counting it would emit a warning on every email in the
  suite and on the health probe of every test run — noise that teaches people to
  ignore the one line that matters. `Swoosh.Adapters.Local` is NOT excluded: it
  is the compile-time default in `config/config.exs`, so it is what a real
  instance runs until someone sets `SMTP_HOST`, and it is the configuration this
  function exists to expose.
  """
  @spec drops_mail?() :: boolean()
  def drops_mail? do
    discards?(deliverability().reason)
  end

  # The ONE spelling of "this reason means a real person's mail is dropped".
  # `drops_mail?/0` and `deliver_checked/1` both route through it: when each
  # carried its own copy, the send path could start disagreeing with the boot
  # banner and the health probe without a single test noticing.
  defp discards?(reason), do: reason in [:local_mailbox, :unconfigured]

  @doc """
  Deliver `email` and report the outcome HONESTLY.

  `Swoosh.Mailer.deliver/1` returns `{:ok, _}` under `Swoosh.Adapters.Local`,
  so every caller that pattern-matched `{:ok, _}` treated "written to an
  in-memory mailbox and discarded" as a successful send. That is the silent
  withhold this function closes: when `drops_mail?/0` is true the return is
  `{:error, {:not_deliverable, adapter, reason}}` even though the adapter said
  `:ok`.

  The message is STILL handed to the configured adapter first. The dev mailbox
  at `/dev/mailbox` is how a developer reads this mail, and refusing to write it
  would replace one silent drop with another. What changes is the CLAIM, not the
  wire: nothing downstream may call this a delivery.
  """
  @spec deliver_checked(Swoosh.Email.t()) :: :ok | {:error, term()}
  def deliver_checked(%Swoosh.Email{} = email) do
    # Read the verdict ONCE: `deliverability/0` reads live application env, so
    # consulting it again after the deliver could answer a different question
    # than the one whose result we are about to label.
    case deliverability() do
      %{adapter: nil, reason: reason} ->
        # Nothing to hand the message to. `Swoosh.Mailer.deliver/1` RAISES on a
        # nil adapter, so attempting it here would turn a reportable
        # misconfiguration into a crash inside the offload task.
        {:error, {:not_deliverable, nil, reason}}

      %{adapter: adapter, reason: reason} ->
        result = deliver(email)

        cond do
          discards?(reason) ->
            {:error, {:not_deliverable, adapter, reason}}

          match?({:ok, _}, result) ->
            :ok

          true ->
            result
        end
    end
  end

  @doc """
  Log the undeliverable-mail banner once at boot when this node cannot send.

  WARNS, it does not raise. An instance with no relay is a legitimate
  configuration — every `mix phx.server` on a laptop is one — so refusing the
  node would make the honest signal unshippable. The counterpart is that the
  condition is never merely implicit: it is stated at boot, restated on every
  send that hits it, and queryable at `/status.json` as a degraded `mail`
  component. Contrast `from/0`, which DOES raise: a malformed
  `MAIL_FROM_ADDRESS` is always a typo, never a deployment style.

  Returns the deliverability map so a caller can assert on it.
  """
  @spec warn_if_undeliverable() :: map()
  def warn_if_undeliverable do
    status = deliverability()

    if drops_mail?() do
      Logger.warning("""
      MAIL IS NOT DELIVERABLE — this node accepts transactional email and discards it.

        adapter: #{inspect(status.adapter)} (#{status.reason})

      Magic-link sign-in, password reset, email verification and access-grant
      invitations will be ACCEPTED and never sent. The HTTP responses stay 200 by
      design (anti-enumeration), so nothing else will tell you this.

      Set SMTP_HOST (plus SMTP_PORT / SMTP_USERNAME / SMTP_PASSWORD as your relay
      requires) to enable delivery — see deploy/smtp.env.example. Ignore this if
      the box is not meant to send mail.
      """)
    end

    status
  end

  @doc """
  The closed vocabulary of `deliverability/0` reasons:
  `[:ok, :local_mailbox, :test_capture, :unconfigured]`.

  Exported so a consumer that maps these onto its own vocabulary can assert
  against THIS list in a test instead of hand-copying the literal. A copied
  literal keeps passing after a fifth reason is added here, which is exactly how
  two sides of a seam start disagreeing without anything going red.
  """
  @spec deliverability_reasons() :: [atom(), ...]
  def deliverability_reasons, do: @reasons
end
