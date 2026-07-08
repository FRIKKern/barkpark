defmodule Barkpark.Access.GrantNotifier do
  @moduledoc """
  Builds + sends the airdrop-grant delivery email — the grantee receives the
  out-of-band `/grant/<token>` claim link. Kept OUT of the pure `Barkpark.Access`
  context (mint stays side-effect-free); the LiveView mint path calls this after
  `{:ok, _}` so delivery is the load-bearing hand-off (a live toast is the
  online-only enhancement).

  The claim URL is the ONLY place the raw token is surfaced besides the minting
  sheet itself — this module renders + delivers it, it never derives or stores
  the token. Adapter is env-selected via `Barkpark.Mailer` (test → in-process
  capture, dev → local mailbox, prod → SMTP).
  """
  import Swoosh.Email
  require Logger
  alias Barkpark.Mailer

  @from {"Barkpark", "no-reply@barkpark.cloud"}

  @doc """
  Send the grant-access link to `email`. `url` is the fully-formed
  `<base>/grant/<token>` claim link. Fail-soft: a down relay is logged (type
  only, never the recipient PII) and returned as `{:error, reason}` — the caller
  keeps the grant (already minted) and surfaces the link in the sheet regardless.
  """
  @spec deliver_grant(String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_grant(email, url) when is_binary(email) and is_binary(url) do
    body = """
    You've been granted access on Barkpark.

    Open the link below to claim it — you'll be asked to sign in, and the grant
    binds to your account:

    #{url}

    The link is time-boxed and account-bound. If you didn't expect this, you can
    ignore it — nothing is shared until you claim it.
    """

    mail =
      new()
      |> to(email)
      |> from(@from)
      |> subject("You've been granted access on Barkpark")
      |> text_body(body)

    case Mailer.deliver(mail) do
      {:ok, _meta} ->
        {:ok, mail}

      {:error, reason} ->
        Logger.error("airdrop grant email delivery failed: reason=#{inspect(reason)}")
        {:error, reason}
    end
  end
end
