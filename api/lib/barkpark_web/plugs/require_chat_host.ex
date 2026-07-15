defmodule BarkparkWeb.Plugs.RequireChatHost do
  @moduledoc "Authenticates a registered host without exposing its stored credential hash."

  import Plug.Conn
  alias Barkpark.ChatHosts

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

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{error: %{code: "unauthorized", message: "invalid host credential"}})
    )
    |> halt()
  end
end
