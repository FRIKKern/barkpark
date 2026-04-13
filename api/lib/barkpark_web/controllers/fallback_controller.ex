defmodule BarkparkWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  alias Barkpark.Content.Errors

  @doc """
  Routes controller error tuples through the v1 structured error envelope.
  See docs/api-v1.md § Error codes.
  """
  def call(conn, error) do
    env = Errors.to_envelope(error)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end
end
