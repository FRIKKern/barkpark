defmodule BarkparkWeb.Plugs.ErrorEnvelopeNegotiation do
  @moduledoc """
  Reads the `Accept-Version` request header and selects the error envelope
  format. Sets `conn.assigns.error_envelope_version` to either `:v1`
  (default) or `:v2` (when the header value is `"2"`).

  Sunset of v1 is deferred — see `docs/api/error-envelope-migration.md`
  for the migration timeline.
  """

  import Plug.Conn

  @assign_key :error_envelope_version

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, @assign_key, negotiate(conn))
  end

  defp negotiate(conn) do
    case get_req_header(conn, "accept-version") do
      [value | _] when is_binary(value) ->
        if String.trim(value) == "2", do: :v2, else: :v1

      _ ->
        :v1
    end
  end
end
