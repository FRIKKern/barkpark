defmodule BarkparkWeb.ErrorJSON do
  @moduledoc """
  Renders errors on JSON requests (wired in `config/config.exs` `render_errors`).

  Phoenix's RenderErrors layer reaches here as the LAST line of defence — when a
  request RAISES, exits, or hits an unmatched route after `action_fallback` no
  longer applies. Without a working module here the error renderer itself
  crashes ("the module does not exist") and the client gets a dropped connection
  instead of a response.

  It emits the SAME canonical v1 envelope as `BarkparkWeb.FallbackController`,
  built by `Barkpark.Content.Errors` (the one owner of the error vocabulary), so
  a crash-path 500 is byte-identical to a controller-emitted one and every
  SDK/CLI consumer can still key on `error.code`.

  Shape (`Barkpark.Content.Errors` → `FallbackController` wrapping):

      %{error: %{code: ..., message: ..., hint: ..., request_id: ...}}

  * `500.json` (and any other unhandled fault) → `internal_error`, message is the
    generic builder text — NO exception detail is ever leaked.
  * `404.json` → `not_found`.
  * catch-all clause handles any `<status>.json` template name.
  """

  alias Barkpark.Content.Errors

  # Phoenix hands "<status>.json" (e.g. "404.json", "500.json"). 404 maps to the
  # canonical `not_found`; every other status (500, and the rare raised
  # Plug.Exception RenderErrors surfaces) collapses to the generic
  # `internal_error` — the HTTP status stays whatever the exception set, but the
  # body never leaks internals. This single clause is the template_name catch-all.
  def render(template, assigns) do
    conn = Map.get(assigns, :conn)

    env =
      template
      |> reason_for_template()
      |> Errors.to_envelope(conn)

    %{error: Map.delete(env, :status)}
  end

  defp reason_for_template("404" <> _), do: {:error, :not_found}
  defp reason_for_template(_), do: {:error, :unknown}
end
