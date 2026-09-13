defmodule BarkparkWeb.Plugs.RequireChatHost do
  @moduledoc "Authenticates a registered host without exposing its stored credential hash."

  import Plug.Conn
  alias Barkpark.ChatHosts
  alias BarkparkWeb.ErrorResponse

  def init(opts), do: opts

  def call(conn, _opts) do
    with [authorization] <- get_req_header(conn, "authorization"),
         {:ok, credential} <- parse_authorization(authorization),
         {:ok, host} <- ChatHosts.authenticate(credential) do
      assign(conn, :chat_host, host)
    else
      _ -> unauthorized(conn)
    end
  end

  defp parse_authorization("Host " <> credential) when byte_size(credential) > 0,
    do: {:ok, credential}

  defp parse_authorization(_), do: {:error, :invalid_authorization}

  # One shared emitter -> the 401 carries request_id (+ the code-keyed hint) for
  # log correlation. It hand-rolled the envelope through `Jason.encode!` +
  # `send_resp`, which is the same fork the controllers had with one extra twist:
  # it also bypassed Phoenix's JSON encoder, so nothing downstream could add a
  # field even in principle. `ErrorResponse.emit_custom/5` halts, which this
  # pre-router plug REQUIRES, so the `halt/1` is not lost.
  defp unauthorized(conn) do
    ErrorResponse.emit_custom(
      conn,
      401,
      "unauthorized",
      "invalid host credential"
    )
  end
end
