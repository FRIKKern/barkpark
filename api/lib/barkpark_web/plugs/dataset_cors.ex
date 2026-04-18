defmodule BarkparkWeb.Plugs.DatasetCors do
  @moduledoc """
  Per-dataset CORS allow-list enforcement.

  Runs inside the `:api` and `:api_preview` pipelines AFTER Corsica (which
  handles the reflection/header logic at the endpoint layer). This plug
  enforces the policy: the request's `Origin` header must appear in the
  dataset's allow-list, OR the allow-list must be empty (default-allow) OR
  contain `"*"` (public), OR the request must have no `Origin` (server-to-
  server). Mismatches return an explicit 403 JSON envelope so SDK clients
  can diagnose, rather than relying on CORS silent-reject.
  """

  import Plug.Conn

  alias Barkpark.Content
  alias Barkpark.Content.Errors

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    with dataset when is_binary(dataset) <- conn.path_params["dataset"],
         [origin | _] <- get_req_header(conn, "origin"),
         allowed when allowed != [] <- Content.allowed_origins_for_dataset(dataset),
         false <- "*" in allowed,
         false <- origin in allowed do
      deny(conn)
    else
      _ -> conn
    end
  end

  defp deny(conn) do
    env = Errors.to_envelope({:error, :forbidden_origin}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
