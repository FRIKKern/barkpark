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

  @default_from_address "no-reply@barkpark.cloud"
  @default_from_name "Barkpark"

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
end
