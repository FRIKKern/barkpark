defmodule BarkparkWeb.Plugs.RequireTicketKey do
  @moduledoc """
  The auth gate for the low-trust TICKET-KEY tier (Barkpark Tickets, charter
  Decision 1 + 7). The counterpart of `RequireToken`, but the ONLY plug that
  resolves a `kind == "ticket"` key — via `Barkpark.Plugins.Tickets.Keys.verify/1`,
  never `Auth.verify_token/1` (which fail-closed rejects ticket keys).

  Gates the `:ticket_key` route bucket (the submitter `/v1/tickets` surface).
  On a valid key it assigns `:ticket_key` (the resolved `%ApiToken{}` row) and
  passes through. Otherwise it halts:

    * missing / revoked / expired / wrong-kind key → 401, an envelope
      byte-identical to a missing token (no oracle distinguishes the cases);
    * paused key → 403 with body message "key paused — contact the operator",
      the one deliberately-distinguishable failure (a live identity an operator
      has muted, not destroyed).

  The 401 envelope mirrors `RequireToken` exactly (`Content.Errors.to_envelope`)
  so a rejected ticket key looks like every other unauthorized API call.
  """

  import Plug.Conn

  alias Barkpark.Plugins.Tickets.Keys

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_key] <- get_req_header(conn, "authorization"),
         {:ok, key} <- Keys.verify(raw_key) do
      assign(conn, :ticket_key, key)
    else
      {:error, :paused} ->
        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{
          error: %{code: "forbidden", message: "key paused — contact the operator"}
        })
        |> halt()

      _ ->
        env = Barkpark.Content.Errors.to_envelope({:error, :unauthorized}, conn)

        conn
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()
    end
  end
end
