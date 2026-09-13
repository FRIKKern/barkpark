defmodule BarkparkWeb.Plugs.RequireMediaProcessingCallbackToken do
  @moduledoc """
  Authenticates external processing callbacks on `/v1/media/:dataset/processing/:id/callback`.

  Expects `Authorization: Bearer <token>` matching
  `config :barkpark, :media_processing_callback_token`.

  ## One shared secret, by ruling (arpss-media-callback-signed-tokens)

  This is ONE instance-wide secret with no HMAC, no workspace or file claim and
  no per-file binding, and the callback handler resolves the target file by id
  without a scope. A LEAKED secret therefore has an instance-wide blast radius:
  its holder can drive the processing callback for ANY workspace's mediaAsset
  (metadata and processing state — never a read of other tenants' data, and
  never a normal API credential: the pipeline accepts only this bearer, so a
  workspace-bound API token is refused here).

  RULED by lead-security-3r, 2026-09-03: ACCEPT the shared-secret model. The
  processor is operator-run infrastructure inside the instance's own trust
  domain (it receives the enqueue webhook signed with MEDIA_WEBHOOK_SECRET and
  presents MEDIA_PROCESSING_CALLBACK_TOKEN back), so a leak of this secret is
  an infrastructure compromise, not a tenant boundary the API can hold on its
  own. Per-file signed callback tokens (minted at enqueue, echoed by the
  processor, verified here) would shrink that radius to one file, but they are
  a cross-service protocol change on the processor side — file it as a
  processor-protocol row if that surface is ever exposed beyond operator-run
  infrastructure. Until then: rotate the secret on any suspicion, keep it out
  of logs, and keep this plug FAIL-CLOSED when the config is unset (the
  `is_binary(expected) and expected != ""` arm below).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:barkpark, :media_processing_callback_token)

    with true <- is_binary(expected) and expected != "",
         ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      _ -> reject(conn)
    end
  end

  # One shared emitter → the 401 carries request_id (+ hint) for log correlation.
  #
  # The hint is ROUTE-DERIVED (task-57081836b628df35). This pipeline accepts
  # ONE instance-wide secret and refuses a workspace api token outright (see
  # the moduledoc), so the old code-keyed default — "send a valid token …
  # tokens are dataset-scoped" — named the one credential this route is
  # guaranteed to refuse.
  defp reject(conn) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      :unauthorized,
      "unauthorized",
      "invalid media processing callback token",
      %{},
      "Send the instance's media processing callback token in the Authorization header; this route accepts no other credential."
    )
  end
end
