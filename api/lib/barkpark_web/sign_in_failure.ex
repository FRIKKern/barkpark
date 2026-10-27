defmodule BarkparkWeb.SignInFailure do
  @moduledoc """
  The answer an OIDC or social sign-in callback gives when it fails. A browser
  gets a short HTML page with a link that starts the sign-in again. An API
  client gets the JSON error it got before.
  """
  import Plug.Conn

  alias BarkparkWeb.ErrorResponse

  @doc """
  Answer a failed callback. `start_path` is where the page's link starts the
  sign-in again. `hint` overrides the JSON error's hint.
  """
  @spec respond(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def respond(conn, %{status: status, code: code, message: message} = f) do
    if browser?(conn) do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, page(f[:page_message] || message, f[:start_path]))
    else
      ErrorResponse.emit_custom(conn, status, code, message, f[:details] || %{}, f[:hint])
    end
  end

  @doc "A printable reason for an error term, for logs and JSON details."
  @spec reason_text(term()) :: String.t()
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_text({:http_status, status}), do: "http_status #{status}"
  def reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 200)

  @doc "Does the request come from a browser? Its redirect chain accepts text/html."
  @spec browser?(Plug.Conn.t()) :: boolean()
  def browser?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp page(message, start_path) do
    link =
      if is_binary(start_path),
        do: ~s(<p><a href="#{esc(start_path)}">Sign in again</a></p>),
        else: ""

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sign-in failed</title>
    <style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.5}</style>
    </head><body>
    <h1>Sign-in failed</h1>
    <p>#{esc(message)}</p>
    #{link}
    </body></html>
    """
  end

  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
