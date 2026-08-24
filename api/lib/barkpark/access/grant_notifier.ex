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

  @doc """
  Send the grant-access link to `email`. `url` is the fully-formed
  `<base>/grant/<token>` claim link.

  NAMED FAILURE MODE: synchronous external I/O in a request path. In prod
  `Mailer.deliver` opens an SMTP conversation via gen_smtp; a slow or unreachable
  relay would stall the minting LiveView (the caller `render_hook`s this) up to
  gen_smtp's own timeout. Delivery is offloaded to the shared
  `Barkpark.TaskSupervisor` so the mint path returns immediately.

  Fail-soft: the caller keeps the grant (already minted) and surfaces the link in
  the sheet regardless — a down relay is logged (type only, never the recipient
  PII) INSIDE the task. This returns `{:ok, mail}` as soon as the message is
  built and handed to the supervisor; the delivery outcome is not observable
  synchronously (and the caller never reads it).
  """
  @spec deliver_grant(String.t(), String.t()) :: {:ok, Swoosh.Email.t()}
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
      |> from(Mailer.from())
      |> subject("You've been granted access on Barkpark")
      |> text_body(body)

    # Offload the SMTP round-trip off the request/LiveView process; the diagnostic
    # log (reason only, never the recipient PII) rides INSIDE the task. `start_child`
    # is deliberate — the caller is a long-lived LiveView and never retrieves the
    # result, so fire-and-forget keeps a reply/DOWN out of its mailbox.
    # See `Barkpark.Mailer.deliver_checked/1` — a raw deliver under the default
    # `Swoosh.Adapters.Local` returns `{:ok, _}` for a message that never left
    # the box, so the grantee's ONLY copy of the claim link vanished with no log.
    Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
      case Mailer.deliver_checked(mail) do
        :ok ->
          :ok

        {:error, {:not_deliverable, adapter, reason}} ->
          Logger.warning(
            "airdrop grant email NOT DELIVERED (no mail relay configured): " <>
              "adapter=#{inspect(adapter)} reason=#{inspect(reason)} — " <>
              "set SMTP_HOST to enable delivery (deploy/smtp.env.example)"
          )

        {:error, reason} ->
          Logger.error("airdrop grant email delivery failed: reason=#{inspect(reason)}")
      end
    end)

    {:ok, mail}
  end
end
