defmodule Barkpark.Plugins.Bulldocs.Web.SyncFault do
  @moduledoc """
  The answer of a BPML push (`POST .../sync`) whose batch failed for a reason
  the sync route has no arm of its own for. A push row the server could not
  store (`Papers.PushRevision`, `{:push_revision_failed, action}`) is the
  server's fault, so it answers 500 `internal_error` in the repo's
  server-error shape (`Content.Errors`); the transaction rolled the write back
  with it. Anything else answers 422 `invalid_op`, as before.
  """

  alias BarkparkWeb.ErrorResponse

  @doc "The answer for `reason`, the batch's `{:error, reason}`."
  @spec answer(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def answer(conn, {:push_revision_failed, _action}),
    do:
      ErrorResponse.emit(
        conn,
        {:error, "the push could not record its revisions; nothing was written"}
      )

  def answer(conn, _reason) do
    ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
      code: "invalid_op",
      message: "the derived batch could not be applied"
    })
  end
end
