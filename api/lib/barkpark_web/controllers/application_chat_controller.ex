defmodule BarkparkWeb.ApplicationChatController do
  @moduledoc "Personal input and separately authenticated executor results; no provider dispatch."
  use BarkparkWeb, :controller
  alias Barkpark.StudioChat.ApplicationTurns

  def create(conn, %{"application_id" => app} = params) do
    result =
      ApplicationTurns.create(
        conn.assigns.chat_scope,
        conn.assigns.current_user_session.id,
        app,
        Map.drop(params, ["workspace_slug", "application_id"])
      )

    case result do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> json(%{id: session.id, revision: 0, runtime_available: false})

      error ->
        reply(conn, error)
    end
  end

  def show(conn, %{"id" => id}),
    do:
      reply(
        conn,
        ApplicationTurns.read(conn.assigns.chat_scope, conn.assigns.current_user_session.id, id)
      )

  def accept(conn, %{"id" => id} = params),
    do:
      reply(
        conn,
        ApplicationTurns.accept(
          conn.assigns.chat_scope,
          conn.assigns.current_user_session.id,
          id,
          Map.drop(params, ["workspace_slug", "id"])
        )
      )

  def cancel(conn, %{"id" => id, "turn_id" => turn}),
    do:
      reply(
        conn,
        ApplicationTurns.cancel(
          conn.assigns.chat_scope,
          conn.assigns.current_user_session.id,
          id,
          turn
        )
      )

  def fetch(conn, %{"turn_id" => turn}),
    do: reply(conn, ApplicationTurns.fetch(conn.assigns.chat_host, turn))

  def commit(conn, %{"turn_id" => turn} = params),
    do:
      reply(
        conn,
        ApplicationTurns.commit(conn.assigns.chat_host, turn, Map.delete(params, "turn_id"))
      )

  defp reply(conn, {:ok, value}), do: json(conn, value)

  defp reply(conn, {:error, reason}) do
    status =
      case reason do
        :not_found -> 404
        :session_lost -> 401
        :forbidden -> 403
        :invalid_request -> 400
        :application_unavailable -> 503
        _ -> 409
      end

    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      status,
      "application_chat_#{reason}",
      "Application conversation request refused"
    )
  end
end
