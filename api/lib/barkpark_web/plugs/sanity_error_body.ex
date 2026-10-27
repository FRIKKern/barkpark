defmodule BarkparkWeb.Plugs.SanityErrorBody do
  @moduledoc """
  On the Sanity-shaped read paths (`/v<apiVersion>/data/query|doc|listen/…`), an
  error body also carries what `@sanity/client` reads, so `ClientError.message`
  names the cause instead of "GET-request to … resulted in HTTP 404"
  (task-0db87287cc6fc325).

  Added, never replacing: `error.description` (the client reads it from an
  object `error`) and Sanity's top-level `statusCode` and `message`. Sanity's
  top-level `error` is a string; here `error` stays Barkpark's object, which
  every other consumer reads. The body is rewritten in `before_send`, so the
  auth plugs, the router and the controllers keep emitting as they do.

  Any other path, a non-JSON body, or an `error` without a string `message`
  goes out untouched.
  """
  @behaviour Plug

  import Plug.Conn

  @path ~r"/v(1|\d{4}-\d{2}-\d{2})/data/(query|doc|listen)/"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if path =~ @path, do: register_before_send(conn, &add_sanity_fields/1), else: conn
  end

  defp add_sanity_fields(%Plug.Conn{status: status, resp_body: body} = conn)
       when is_integer(status) and status >= 400 and not is_nil(body) do
    with true <- json?(conn),
         {:ok, %{"error" => %{"message" => message} = error} = decoded} when is_binary(message) <-
           Jason.decode(IO.iodata_to_binary(body)) do
      decoded =
        decoded
        |> Map.put("error", Map.put_new(error, "description", message))
        |> Map.put_new("statusCode", status)
        |> Map.put_new("message", message)

      %{conn | resp_body: Jason.encode_to_iodata!(decoded)}
    else
      _ -> conn
    end
  end

  defp add_sanity_fields(conn), do: conn

  defp json?(conn) do
    Enum.any?(get_resp_header(conn, "content-type"), &String.starts_with?(&1, "application/json"))
  end
end
