defmodule BarkparkWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Barkpark.Content.Errors

  @doc """
  Routes controller error tuples through the v1 structured error envelope.
  See docs/api-v1.md § Error codes.

  NEVER SILENT ON 5xx (task-96d8ab2b582818a4): the catch-all `Errors.build/1`
  clause maps any unrecognized `{:error, term}` to a 500 `internal_error`, and
  until now that rendered with ZERO log output — the exact shape of the round-3
  live import failure ("Sent 500" in the journal, no error line, a request_id
  that resolves to nothing). Any 5xx rendered from a returned error term is a
  server-side defect by definition, so it is logged here — with the term, the
  route, and the request_id already on Logger.metadata — BEFORE the response
  goes out.
  """
  # `Barkpark.Media.delete_file/2` wraps a refused `mediaAsset` document delete as
  # `{:error, {:asset_doc_delete_failed, reason}}` (task-1116dcb208496fc7). The
  # wrapper exists so the media layer can say WHICH half refused; the STATUS is
  # still the inner reason's own — `{:rev_mismatch, _}` is a 412, `{:halted, _}` a
  # 409 — so this adds no new code to the §9 vocabulary (`Errors.known_codes/0`)
  # and no client has to learn a media-only shape.
  #
  # It is unwrapped HERE rather than in `Errors.build/1` because the wrapper is a
  # media-controller concern and `Barkpark.Content.Errors` is not this lane's to
  # edit. The one reason with no inner shape — `:rollback`, a nested transaction
  # that DBConnection aborted without telling us why — falls through to
  # `build/1`'s catch-all 500, which the `Logger.error` below already prints in
  # full. That is the guarantee this clause buys: a 500 with a NAMED term in the
  # log, never the `CaseClauseError` on a bare `{:error, :rollback}` that took
  # every prod delete down in #15827.
  #
  def call(conn, {:error, {:asset_doc_delete_failed, reason}}) when reason != :rollback do
    call(conn, {:error, reason})
  end

  def call(conn, error) do
    env = Errors.to_envelope(error, conn)

    if is_integer(env.status) and env.status >= 500 do
      Logger.error(
        "FallbackController: rendering #{env.status} #{env.code} for an unhandled " <>
          "controller error term on #{conn.method} #{conn.request_path} — " <>
          "term=#{inspect(error, limit: 25, printable_limit: 500)}"
      )
    end

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end
end
