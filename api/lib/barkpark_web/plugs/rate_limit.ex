defmodule BarkparkWeb.Plugs.RateLimit do
  import Plug.Conn

  alias Barkpark.{Content.Errors, RateLimiter}

  def init(opts), do: opts

  def call(conn, opts) do
    key = conn_key(conn)

    case RateLimiter.check(key, opts) do
      :ok ->
        conn

      :rate_limited ->
        env = Errors.to_envelope({:error, :rate_limited})

        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()
    end
  end

  defp conn_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:token, token}
      _ -> {:ip, conn.remote_ip |> :inet.ntoa() |> to_string()}
    end
  end
end
